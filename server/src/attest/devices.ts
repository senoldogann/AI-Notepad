import { z } from "zod";
import type { Config } from "../config";
import { Base64Error, base64Decode, base64Encode, decodeUtf8Strict, randomToken, sha256Hex, utf8 } from "../crypto";
import { ApiError } from "../errors";
import { log } from "../log";
import type { Platform } from "../platform";
import { type AttestVerifyOptions, AttestationError, type AttestedKey, type VerifiedAssertion, verifyAssertion, verifyAttestation } from "./appAttest";

/** Meydan okuma ömrü: 5 dakika. */
export const challengeTtlMs: number = 5 * 60_000;

/** Meydan okumanın amacı: anahtar onayı (attest) ya da istek onayı (assert). */
export type ChallengePurpose = "attest" | "assert";

/** Hassas istekte gönderilen App Attest onayı. */
export interface DeviceAssertionInput {
  readonly keyId: string;
  readonly assertion: string;
  readonly clientData: string;
}

/** Onay girdisi şeması (base64 alanlar). */
export const deviceAssertionSchema = z.strictObject({
  keyId: z.string().min(1).max(128),
  assertion: z.string().min(1).max(8192),
  clientData: z.string().min(1).max(2048),
});

/** İstemci verisi: onaylanan eylem ve sunucunun verdiği meydan okuma. */
const clientDataSchema = z.strictObject({ action: z.string().min(1).max(64), challenge: z.string().min(16).max(128) });

function verifyOptions(platform: Platform, config: Config): AttestVerifyOptions {
  return {
    appIds: config.attest.appIds,
    environment: config.attest.environment,
    allowedCategories: config.attest.allowedCategories,
    rootPem: platform.appAttestRootPem,
    now: platform.now(),
  };
}

function decodeField(value: string, field: string): Uint8Array {
  try {
    return base64Decode(value);
  } catch (error: unknown) {
    if (error instanceof Base64Error) {
      throw new ApiError("invalid_body", `${field} base64 değil.`);
    }
    throw error;
  }
}

/** Kullanıcıya tek kullanımlık meydan okuma verir; yalnızca karması saklanır. */
export async function createChallenge(db: D1Database, userId: string, purpose: ChallengePurpose, now: Date): Promise<string> {
  const challenge: string = randomToken(32);
  await db
    .prepare("INSERT INTO device_challenges (challenge_hash, user_id, purpose, created_at, expires_at) VALUES (?, ?, ?, ?, ?)")
    .bind(await sha256Hex(challenge), userId, purpose, now.getTime(), now.getTime() + challengeTtlMs)
    .run();
  return challenge;
}

/** Meydan okumayı tek seferlik tüketir; kullanıcı, amaç ve süre eşleşmezse `challenge_invalid`. */
async function consumeChallenge(db: D1Database, userId: string, purpose: ChallengePurpose, challenge: string, now: Date): Promise<void> {
  const row: { challenge_hash: string } | null = await db
    .prepare(
      `UPDATE device_challenges SET used_at = ?
       WHERE challenge_hash = ? AND user_id = ? AND purpose = ? AND used_at IS NULL AND expires_at > ?
       RETURNING challenge_hash`,
    )
    .bind(now.getTime(), await sha256Hex(challenge), userId, purpose, now.getTime())
    .first<{ challenge_hash: string }>();
  if (row === null) {
    throw new ApiError("challenge_invalid", "Meydan okuma geçersiz, süresi dolmuş ya da kullanılmış.");
  }
}

/**
 * App Attest anahtarını doğrular ve cihaz olarak kaydeder. `clientDataHash` = SHA256(meydan okumanın UTF-8 baytları).
 * Aynı anahtar ikinci kez kaydedilemez (sayaç 0 onayı tek seferliktir).
 */
export async function registerDevice(
  db: D1Database,
  platform: Platform,
  config: Config,
  userId: string,
  input: { readonly keyId: string; readonly attestation: string; readonly challenge: string },
): Promise<string> {
  const now: Date = platform.now();
  await consumeChallenge(db, userId, "attest", input.challenge, now);
  const keyId: Uint8Array = decodeField(input.keyId, "keyId");
  const deviceId: string = base64Encode(keyId);
  let attested: AttestedKey;
  try {
    attested = await verifyAttestation(decodeField(input.attestation, "attestation"), keyId, utf8(input.challenge), verifyOptions(platform, config));
  } catch (error: unknown) {
    if (error instanceof AttestationError) {
      log("warn", "attestation_rejected", { userId, reason: error.message });
      throw new ApiError("attestation_invalid", "Cihaz doğrulaması başarısız.");
    }
    throw error;
  }
  const inserted: D1Result = await db
    .prepare(
      `INSERT OR IGNORE INTO devices (id, public_key_spki, sign_count, environment, validation_category, bundle_version,
         receipt, attested_by_user_id, created_at, last_used_at)
       VALUES (?, ?, 0, ?, ?, ?, ?, ?, ?, ?)`,
    )
    .bind(
      deviceId,
      base64Encode(attested.publicKeySpki),
      config.attest.environment,
      attested.validationCategory,
      attested.bundleVersion,
      base64Encode(attested.receipt),
      userId,
      now.getTime(),
      now.getTime(),
    )
    .run();
  if (inserted.meta.changes !== 1) {
    throw new ApiError("attestation_invalid", "Bu cihaz anahtarı zaten kayıtlı.");
  }
  log("info", "device_attested", { userId, category: attested.validationCategory });
  return deviceId;
}

interface DeviceRow {
  readonly public_key_spki: string;
  readonly sign_count: number;
  readonly environment: string;
}

/**
 * Hassas istekteki App Attest onayını doğrular: istemci verisi `{action, challenge}` beklenen eylemi ve kullanıcının
 * tek kullanımlık meydan okumasını taşır, imza ve sayaç geçerlidir. Sayaç koşullu güncellenir (eşzamanlı yeniden
 * oynatma da reddedilir). Cihaz kimliğini döndürür.
 */
export async function verifyDeviceAssertion(
  db: D1Database,
  platform: Platform,
  config: Config,
  userId: string,
  action: string,
  input: DeviceAssertionInput,
): Promise<string> {
  const now: Date = platform.now();
  const clientDataBytes: Uint8Array = decodeField(input.clientData, "clientData");
  let clientDataRaw: unknown;
  try {
    clientDataRaw = JSON.parse(decodeUtf8Strict(clientDataBytes));
  } catch {
    throw new ApiError("assertion_invalid", "Cihaz onayı geçersiz.");
  }
  const clientData = clientDataSchema.safeParse(clientDataRaw);
  if (!clientData.success || clientData.data.action !== action) {
    throw new ApiError("assertion_invalid", "Cihaz onayı bu işlem için değil.");
  }
  await consumeChallenge(db, userId, "assert", clientData.data.challenge, now);
  const deviceId: string = base64Encode(decodeField(input.keyId, "keyId"));
  const device: DeviceRow | null = await db
    .prepare("SELECT public_key_spki, sign_count, environment FROM devices WHERE id = ?")
    .bind(deviceId)
    .first<DeviceRow>();
  if (device === null || device.environment !== config.attest.environment) {
    throw new ApiError("assertion_invalid", "Cihaz kayıtlı değil; cihazı yeniden doğrula.");
  }
  let verified: VerifiedAssertion;
  try {
    verified = await verifyAssertion(
      decodeField(input.assertion, "assertion"),
      clientDataBytes,
      base64Decode(device.public_key_spki),
      device.sign_count,
      verifyOptions(platform, config),
    );
  } catch (error: unknown) {
    if (error instanceof AttestationError) {
      log("warn", "assertion_rejected", { userId, reason: error.message });
      throw new ApiError("assertion_invalid", "Cihaz onayı geçersiz.");
    }
    throw error;
  }
  const updated: D1Result = await db
    .prepare("UPDATE devices SET sign_count = ?, last_used_at = ? WHERE id = ? AND sign_count < ?")
    .bind(verified.counter, now.getTime(), deviceId, verified.counter)
    .run();
  if (updated.meta.changes !== 1) {
    throw new ApiError("assertion_invalid", "Cihaz onayı yeniden kullanıldı.");
  }
  return deviceId;
}
