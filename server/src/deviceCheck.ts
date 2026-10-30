import { type CryptoKey as JoseKey, SignJWT, importPKCS8 } from "jose";
import { z } from "zod";
import { ConfigError, type DeviceCheckConfig, type DeviceCheckEnvironment } from "./config";
import { randomId } from "./crypto";
import { ApiError, UpstreamError, isRetryableStatus } from "./errors";
import { errorName, log } from "./log";
import type { Platform } from "./platform";
import { withRetries } from "./retry";
import { isRetryableUpstreamError } from "./upstream";

/**
 * Apple DeviceCheck: Apple her cihaz (Mac) için uygulama geliştiricisine iki bit saklar; sunucu cihaz kimliği görmez,
 * yalnızca uygulamanın `DCDevice.generateToken()` ile ürettiği kısa ömürlü jetonla bitleri okur ve yazar.
 * Anlamlar: `bit0` = "bu Mac bir hesaba ücretsiz deneme verdi"; `bit1` kullanılmaz (güncellerken okunan değer korunur).
 */

/** Yeniden deneme dahil en çok deneme (5xx, 429, ağ hatası, zaman aşımı). */
const deviceCheckAttempts: number = 3;

/** Deneme başına zaman aşımı. */
const deviceCheckTimeoutMs: number = 10_000;

/** DeviceCheck API kökleri. */
const deviceCheckBaseUrls: Readonly<Record<DeviceCheckEnvironment, string>> = {
  production: "https://api.devicecheck.apple.com/v1/",
  development: "https://api.development.devicecheck.apple.com/v1/",
};

/** Bit sorgusunun yanıtı bit bulunamayınca JSON değil bu düz metindir (bitler hiç yazılmamış: ikisi de false). */
const bitStateNotFound: string = "Failed to find bit state";

/** Cihazın iki biti. */
export interface DeviceBits {
  readonly bit0: boolean;
  readonly bit1: boolean;
}

/** Yapılandırılmış DeviceCheck (politika `required`). */
export type ActiveDeviceCheck = Extract<DeviceCheckConfig, { readonly policy: "required" }>;

const queryResponseSchema = z.object({ bit0: z.boolean(), bit1: z.boolean() });

/** DeviceCheck uç adresi. Saf fonksiyondur. */
export function deviceCheckUrl(environment: DeviceCheckEnvironment, endpoint: "query_two_bits" | "update_two_bits"): string {
  return `${deviceCheckBaseUrls[environment]}${endpoint}`;
}

/** Bit sorgusu yanıt gövdesini bitlere çevirir; beklenmeyen gövdede `UpstreamError` (yeniden denenmez). Saf fonksiyondur. */
export function parseQueryBits(body: string): DeviceBits {
  if (body.trim() === bitStateNotFound) {
    return { bit0: false, bit1: false };
  }
  let json: unknown;
  try {
    json = JSON.parse(body);
  } catch (error: unknown) {
    if (error instanceof SyntaxError) {
      throw new UpstreamError("devicecheck", 200, false, "bit sorgusu yanıtı JSON değil");
    }
    throw error;
  }
  const parsed = queryResponseSchema.safeParse(json);
  if (!parsed.success) {
    throw new UpstreamError("devicecheck", 200, false, "bit sorgusu yanıtı beklenen biçimde değil");
  }
  return { bit0: parsed.data.bit0, bit1: parsed.data.bit1 };
}

/** ES256 imzalı yetki jetonu: başlık `{alg, kid}`, iddialar `{iss: ekip, iat}`. Anahtar okunamazsa `ConfigError`. */
async function authorizationJwt(deviceCheck: ActiveDeviceCheck, now: Date): Promise<string> {
  let key: JoseKey;
  try {
    key = await importPKCS8(deviceCheck.privateKeyPem, "ES256");
  } catch (error: unknown) {
    log("error", "devicecheck_key_invalid", { error: errorName(error) });
    throw new ConfigError(["DEVICECHECK_PRIVATE_KEY"]);
  }
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: deviceCheck.keyId })
    .setIssuer(deviceCheck.teamId)
    .setIssuedAt(Math.floor(now.getTime() / 1000))
    .sign(key);
}

/**
 * DeviceCheck ucuna POST atar ve yanıt gövdesini döndürür. 400 (geçersiz cihaz jetonu) `device_check_invalid`
 * (yeniden denenmez); 5xx, 429 ve ağ hataları uyarıyla yeniden denenir, sonra `UpstreamError`. Apple'ın hata gövdesi
 * kısa bir neden metnidir (jeton yankılamaz): hata ayıklama için ilk 200 karakteri loglanır. Jeton ve anahtar loglanmaz.
 */
async function postDeviceCheck(
  platform: Platform,
  deviceCheck: ActiveDeviceCheck,
  endpoint: "query_two_bits" | "update_two_bits",
  payload: Readonly<Record<string, string | number | boolean>>,
  now: Date,
): Promise<string> {
  const jwt: string = await authorizationJwt(deviceCheck, now);
  const url: string = deviceCheckUrl(deviceCheck.environment, endpoint);
  return withRetries(
    { service: "devicecheck", attempts: deviceCheckAttempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError, recordRetry: platform.recordRetry },
    async (): Promise<string> => {
      const response: Response = await platform.fetch(url, {
        method: "POST",
        headers: { authorization: `Bearer ${jwt}`, "content-type": "application/json" },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(deviceCheckTimeoutMs),
      });
      const body: string = await response.text();
      if (response.ok) {
        return body;
      }
      const reason: string = body.slice(0, 200);
      log("warn", "devicecheck_failed", { endpoint, status: response.status, reason });
      if (response.status === 400) {
        throw new ApiError("device_check_invalid", "Bu Mac Apple DeviceCheck ile doğrulanamadı; uygulamayı yeniden açıp tekrar dene.");
      }
      throw new UpstreamError("devicecheck", response.status, isRetryableStatus(response.status), reason);
    },
  );
}

/** Cihazın iki bitini okur (hiç yazılmamışsa ikisi de false). `token`: istemcinin DeviceCheck jetonu (base64). */
export async function queryDeviceBits(platform: Platform, deviceCheck: ActiveDeviceCheck, token: string, now: Date): Promise<DeviceBits> {
  const body: string = await postDeviceCheck(
    platform,
    deviceCheck,
    "query_two_bits",
    { device_token: token, transaction_id: randomId(), timestamp: now.getTime() },
    now,
  );
  return parseQueryBits(body);
}

/** Cihazın iki bitini yazar (Apple ikisini birlikte yazar: değişmeyecek bit okunan değeriyle verilir). */
export async function updateDeviceBits(platform: Platform, deviceCheck: ActiveDeviceCheck, token: string, bits: DeviceBits, now: Date): Promise<void> {
  await postDeviceCheck(
    platform,
    deviceCheck,
    "update_two_bits",
    { device_token: token, transaction_id: randomId(), timestamp: now.getTime(), bit0: bits.bit0, bit1: bits.bit1 },
    now,
  );
}
