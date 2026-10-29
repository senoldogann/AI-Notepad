import { z } from "zod";
import { ApiError } from "../errors";
import { log } from "../log";
import type { Platform } from "../platform";
import { fetchUpstream } from "../upstream";

export const turnstileVerifyUrl: string = "https://challenges.cloudflare.com/turnstile/v0/siteverify";

/** Turnstile doğrulamasının deneme başına zaman aşımı. */
const turnstileTimeoutMs: number = 10_000;

const siteverifySchema = z.object({
  success: z.boolean(),
  "error-codes": z.array(z.string()).optional(),
});

/** Turnstile yanıtını Cloudflare'de doğrular; başarısızsa `turnstile_failed`. */
export async function verifyTurnstile(platform: Platform, secretKey: string, token: string, clientIp: string): Promise<void> {
  const response: Response = await fetchUpstream(
    platform,
    "turnstile",
    turnstileVerifyUrl,
    (): RequestInit => ({
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ secret: secretKey, response: token, remoteip: clientIp }),
    }),
    3,
    turnstileTimeoutMs,
  );
  const parsed = siteverifySchema.safeParse(await response.json());
  if (!parsed.success) {
    throw new ApiError("upstream_unavailable", "Turnstile doğrulaması okunamadı.");
  }
  if (!parsed.data.success) {
    log("warn", "turnstile_rejected", { codes: (parsed.data["error-codes"] ?? []).join(",") });
    throw new ApiError("turnstile_failed", "İnsan doğrulaması başarısız; sayfayı yenileyip yeniden dene.");
  }
}
