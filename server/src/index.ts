import { handleRequest } from "./app";
import { appleAppAttestationRootPem } from "./attest/appleRoot";
import { cleanupExpiredRows, scheduledCleanupLimits } from "./cleanup";
import type { Env } from "./env";
import type { Platform } from "./platform";

/** Üretim platformu: gerçek fetch, saat ve Apple App Attestation kökü. */
const platform: Platform = {
  fetch: (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => fetch(input, init),
  now: (): Date => new Date(),
  appAttestRootPem: appleAppAttestationRootPem,
  retryBaseDelayMs: 300,
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
  /** Günlük Cron Trigger: süresi dolmuş satırların temizliği. */
  async scheduled(controller: ScheduledController, env: Env): Promise<void> {
    await cleanupExpiredRows(env.DB, new Date(controller.scheduledTime), scheduledCleanupLimits);
  },
} satisfies ExportedHandler<Env>;
