/** Rastgele, URL'de güvenli bir jeton (base64url, `byteCount` bayt entropi). */
export function randomToken(byteCount: number): string {
  const bytes: Uint8Array = new Uint8Array(byteCount);
  crypto.getRandomValues(bytes);
  return base64UrlEncode(bytes);
}

/** Rastgele kimlik (UUID v4). */
export function randomId(): string {
  return crypto.randomUUID();
}

/** SHA-256 özeti. */
export async function sha256(data: Uint8Array): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

/** Metnin SHA-256 özeti, onaltılık. Jetonlar veritabanında bu biçimde saklanır. */
export async function sha256Hex(text: string): Promise<string> {
  return hexEncode(await sha256(utf8(text)));
}

/**
 * Sabit zamanlı karşılaştırma: iki değer önce özetlenir (uzunluk sızmaz), sonra Workers'ın `timingSafeEqual`'ı ile
 * karşılaştırılır.
 */
export async function constantTimeEqual(left: Uint8Array, right: Uint8Array): Promise<boolean> {
  const [leftHash, rightHash]: [Uint8Array, Uint8Array] = await Promise.all([sha256(left), sha256(right)]);
  return crypto.subtle.timingSafeEqual(leftHash, rightHash);
}

/** Metinler için sabit zamanlı karşılaştırma. */
export async function constantTimeEqualText(left: string, right: string): Promise<boolean> {
  return constantTimeEqual(utf8(left), utf8(right));
}

/** UTF-8 baytları. Saf fonksiyondur. */
export function utf8(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

/** Bozuk UTF-8 kabul edilmeden çözme (hata fırlatır). Saf fonksiyondur. */
export function decodeUtf8Strict(bytes: Uint8Array): string {
  return new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes);
}

/** Onaltılık kodlama. Saf fonksiyondur. */
export function hexEncode(bytes: Uint8Array): string {
  return Array.from(bytes, (byte: number): string => byte.toString(16).padStart(2, "0")).join("");
}

/** Standart base64 kodlama. Saf fonksiyondur. */
export function base64Encode(bytes: Uint8Array): string {
  let binary: string = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

/** base64url kodlama (dolgusuz). Saf fonksiyondur. */
export function base64UrlEncode(bytes: Uint8Array): string {
  return base64Encode(bytes).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

/** Bozuk base64 girdisi. */
export class Base64Error extends Error {
  override readonly name: string = "Base64Error";
}

/** Standart ya da URL güvenli base64 çözme; bozuk girdide `Base64Error`. Saf fonksiyondur. */
export function base64Decode(text: string): Uint8Array {
  const normalized: string = text.replaceAll("-", "+").replaceAll("_", "/");
  const padded: string = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    throw new Base64Error("base64 çözülemedi");
  }
  return Uint8Array.from(binary, (char: string): number => char.charCodeAt(0));
}

/** Bayt dizilerini uç uca ekler. Saf fonksiyondur. */
export function concatBytes(parts: readonly Uint8Array[]): Uint8Array {
  const total: number = parts.reduce((sum: number, part: Uint8Array): number => sum + part.byteLength, 0);
  const result: Uint8Array = new Uint8Array(total);
  let offset: number = 0;
  for (const part of parts) {
    result.set(part, offset);
    offset += part.byteLength;
  }
  return result;
}

/** İki bayt dizisi aynı mı (gizli olmayan değerler için). Saf fonksiyondur. */
export function bytesEqual(left: Uint8Array, right: Uint8Array): boolean {
  return left.byteLength === right.byteLength && left.every((byte: number, index: number): boolean => byte === right[index]);
}
