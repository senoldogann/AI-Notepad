import { base64UrlEncode, sha256, sha256Hex, utf8 } from "./crypto";
import { log } from "./log";

/**
 * Son geçiş yüklemesinin tekrar güvenliği (idempotency): istemci her ses parçası için rastgele bir yükleme anahtarı
 * üretir (`x-upload-key`, 32 bayt base64url) ve aynı parçanın yeniden denemelerinde aynısını gönderir. Tamamlanan
 * yazıya dökmenin sonucu, anahtarın özetiyle (`key_hash`) ve anahtardan türetilen anahtarla AES-GCM şifreli olarak kısa
 * süre (`transcriptionCacheTtlMs`) saklanır: yanıt yolda kaybolursa aynı anahtarla gelen istek sesi yeniden işlemeden ve
 * yeniden faturalanmadan aynı sonucu alır. Sunucu anahtarı saklamadığından saklı metni okuyamaz; süre dolunca temizlik
 * siler, hesap silinince hemen silinir.
 */

/** Saklı sonucun ömrü: istemcinin en uzun yeniden deneme penceresinden (20 dk bekleme) uzundur. */
export const transcriptionCacheTtlMs: number = 2 * 60 * 60_000;

/** Yükleme anahtarı biçimi: 32 bayt base64url (dolgusuz). */
const uploadKeyPattern: RegExp = /^[A-Za-z0-9_-]{43}$/;

/** Başlıktaki yükleme anahtarı; yoksa null, biçimi bozuksa null (istek anahtarsız sayılır, uyarı loglanır). */
export function uploadKeyFrom(header: string | null): string | null {
  if (header === null) {
    return null;
  }
  if (!uploadKeyPattern.test(header)) {
    log("warn", "upload_key_invalid", {});
    return null;
  }
  return header;
}

/** Anahtardan AES-GCM anahtarı (anahtarın kendisi saklanmaz). */
async function encryptionKey(uploadKey: string): Promise<CryptoKey> {
  const raw: Uint8Array = await sha256(utf8(`ainotepad-transcription-cache-v1:${uploadKey}`));
  return crypto.subtle.importKey("raw", raw, "AES-GCM", false, ["encrypt", "decrypt"]);
}

/** Saklı sonuç; yoksa, süresi geçtiyse ya da başka kullanıcının/toplantınınsa null. */
export async function cachedTranscription(db: D1Database, userId: string, meetingId: string, uploadKey: string, now: Date): Promise<object | null> {
  const row: { ciphertext: ArrayBuffer; iv: ArrayBuffer } | null = await db
    .prepare("SELECT ciphertext, iv FROM transcription_results WHERE key_hash = ? AND user_id = ? AND meeting_id = ? AND expires_at > ?")
    .bind(await sha256Hex(uploadKey), userId, meetingId, now.getTime())
    .first<{ ciphertext: ArrayBuffer; iv: ArrayBuffer }>();
  if (row === null) {
    return null;
  }
  const plain: ArrayBuffer = await crypto.subtle.decrypt({ name: "AES-GCM", iv: new Uint8Array(row.iv) }, await encryptionKey(uploadKey), new Uint8Array(row.ciphertext));
  const parsed: unknown = JSON.parse(new TextDecoder().decode(plain));
  if (typeof parsed !== "object" || parsed === null) {
    throw new Error("Saklı yazıya dökme sonucu nesne değil.");
  }
  return parsed;
}

/** Tamamlanan sonucu şifreli saklar (aynı anahtar ikinci kez yazılmaz). */
export async function storeTranscription(db: D1Database, userId: string, meetingId: string, uploadKey: string, result: unknown, now: Date): Promise<void> {
  const iv: Uint8Array = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext: ArrayBuffer = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, await encryptionKey(uploadKey), utf8(JSON.stringify(result)));
  await db
    .prepare(
      `INSERT OR IGNORE INTO transcription_results (key_hash, user_id, meeting_id, ciphertext, iv, created_at, expires_at)
       VALUES (?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(await sha256Hex(uploadKey), userId, meetingId, new Uint8Array(ciphertext), iv, now.getTime(), now.getTime() + transcriptionCacheTtlMs)
    .run();
  log("info", "transcription_cached", { meetingId, keyId: base64UrlEncode((await sha256(utf8(uploadKey))).slice(0, 6)) });
}
