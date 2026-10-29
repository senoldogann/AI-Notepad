import { handleRequest } from "./app";
import { appleAppAttestationRootPem } from "./attest/appleRoot";
import { cleanupExpiredRows, scheduledCleanupLimits } from "./cleanup";
import { parseConfig } from "./config";
import { dailyElevenLabsCapacityCheck } from "./elevenLabsCapacity";
import type { Env } from "./env";
import type { Platform } from "./platform";

/** Üretim platformu: gerçek fetch, saat, Apple App Attestation kökü ve Worker örneği ömrünce JWKS önbelleği. */
const platform: Platform = {
  fetch: (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => fetch(input, init),
  now: (): Date => new Date(),
  appAttestRootPem: appleAppAttestationRootPem,
  retryBaseDelayMs: 300,
  jwksCache: new Map(),
};

export default {
  async fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
    return handleRequest(request, env, {
      platform,
      waitUntil: (promise: Promise<void>): void => ctx.waitUntil(promise),
      // Cloudflare her istekte bu başlığı koyar; yerel geliştirmede yoktur.
      clientIp: request.headers.get("cf-connecting-ip") ?? "local",
    });
  },
  /** Günlük Cron Trigger: ElevenLabs kapasite denetimi (eşik üstündeyse alarm) ve süresi dolmuş satırların temizliği. */
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    const now: Date = new Date(controller.scheduledTime);
    await dailyElevenLabsCapacityCheck(env.DB, parseConfig(env), now);
    await cleanupExpiredRows(env.DB, now, scheduledCleanupLimits);
  },
} satisfies ExportedHandler<Env>;
