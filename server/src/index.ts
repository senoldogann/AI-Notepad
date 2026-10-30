import { handleRequest } from "./app";
import { appleAppAttestationRootPem } from "./attest/appleRoot";
import { warnIfAccessCheckDisabled } from "./auth/access";
import { appleTokenIssuer } from "./auth/apple";
import { googleTokenIssuer } from "./auth/google";
import { refreshPersistedIssuerKeys } from "./auth/identityToken";
import { warnIfStripeTestMode } from "./billing";
import { cleanupExpiredRows, scheduledCleanupLimits } from "./cleanup";
import { type Config, parseConfig } from "./config";
import { recordDailyMetrics } from "./dailyMetrics";
import { settleDeepgramMeetings } from "./deepgram";
import { dailyElevenLabsCapacityCheck } from "./elevenLabsCapacity";
import type { Env } from "./env";
import { errorName, log } from "./log";
import { retryRecorder } from "./opsEvents";
import type { CachedJwks, Platform } from "./platform";
import { grantDueReferralRewards } from "./referralRewards";

/** Worker örneği ömrünce paylaşılan kimlik sağlayıcısı anahtarları önbelleği. */
const jwksCache: Map<string, CachedJwks> = new Map();

/**
 * Üretim platformu: gerçek fetch, saat, Apple App Attestation kökü, paylaşılan JWKS önbelleği ve ortamın D1'ine yazan
 * yeniden deneme sayacı (`retryRecorder`).
 */
function productionPlatform(db: D1Database): Platform {
  const now = (): Date => new Date();
  return {
    fetch: (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => fetch(input, init),
    now,
    appAttestRootPem: appleAppAttestationRootPem,
    retryBaseDelayMs: 300,
    jwksCache,
    recordRetry: retryRecorder(db, now),
  };
}

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return handleRequest(request, env, {
      platform: productionPlatform(env.DB),
      waitUntil: (promise: Promise<void>): void => ctx.waitUntil(promise),
      // Cloudflare her istekte bu başlığı koyar; yerel geliştirmede yoktur.
      clientIp: request.headers.get("cf-connecting-ip") ?? "local",
    });
  },
  /**
   * Günlük Cron Trigger: ElevenLabs kapasite denetimi (eşik üstündeyse alarm), bitirilmeden kalan toplantıların Deepgram
   * tahmininin indirilmesi, biten günün anlık görüntüsü (`recordDailyMetrics`), süresi dolmuş satırların temizliği,
   * günü gelmiş davet ödülleri ve Apple/Google anahtarlarının tazelenmesi.
   */
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    const now: Date = new Date(controller.scheduledTime);
    const platform: Platform = productionPlatform(env.DB);
    const config: Config = parseConfig(env);
    warnIfStripeTestMode(config, "scheduled");
    warnIfAccessCheckDisabled(config.access);
    // Adımlar birbirinden bağımsız: biri başarısız olsa da diğerleri çalışır; her hata `alert` yazılır, sonunda hepsi
    // birlikte fırlatılır (Cron çalışması başarısız görünsün).
    const steps: ReadonlyArray<{ name: string; run: () => Promise<unknown> }> = [
      { name: "elevenlabs_capacity", run: () => dailyElevenLabsCapacityCheck(env.DB, config, now) },
      { name: "deepgram_settle", run: () => settleDeepgramMeetings(env.DB, now) },
      // Deepgram tahmini indirildikten sonra: biten günün toplamları ve gün sonundaki durum (bkz. `dailyMetrics.ts`).
      { name: "daily_metrics", run: () => recordDailyMetrics(env.DB, config, now) },
      { name: "cleanup", run: () => cleanupExpiredRows(env.DB, now, scheduledCleanupLimits) },
      // Bekleme süresi dolmuş davet ödülleri (davet edenin Stripe müşteri bakiyesi; bkz. `referralRewards.ts`).
      { name: "referral_rewards", run: () => grantDueReferralRewards(env.DB, platform, config, now) },
      // Apple ve Google anahtarları önceden alınır: girişler sağlayıcıyı beklemesin (bkz. `persistedIssuerKeys`).
      { name: "apple_jwks", run: () => refreshPersistedIssuerKeys(env.DB, platform, appleTokenIssuer(config)) },
      { name: "google_jwks", run: () => refreshPersistedIssuerKeys(env.DB, platform, googleTokenIssuer(config)) },
    ];
    const failures: unknown[] = [];
    for (const step of steps) {
      try {
        await step.run();
      } catch (error: unknown) {
        log("alert", "scheduled_step_failed", { step: step.name, error: errorName(error) });
        failures.push(error);
      }
    }
    if (failures.length > 0) {
      throw new AggregateError(failures, `Zamanlanmış görevde ${failures.length} adım başarısız.`);
    }
  },
} satisfies ExportedHandler<Env>;
