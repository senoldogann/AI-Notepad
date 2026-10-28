import { UpstreamError, isRetryableStatus } from "./errors";
import type { Platform } from "./platform";
import { withRetries } from "./retry";

/** Bağlantı hatası ya da geçici durum kodu yeniden denenir. Saf fonksiyondur. */
export function isRetryableUpstreamError(error: unknown): boolean {
  if (error instanceof UpstreamError) {
    return error.retryable;
  }
  // fetch ağ hatasında TypeError fırlatır.
  return error instanceof TypeError;
}

/**
 * Dış servise istek atar; 2xx dışı yanıtta gövde okunmadan (gizli değer ya da içerik taşıyabilir) `UpstreamError`
 * fırlatır. Geçici hatalar `attempts` kez uyarıyla yeniden denenir. `init` her denemede yeniden çağrılır (gövde
 * akışları bir kez okunabilir).
 */
export async function fetchUpstream(
  platform: Platform,
  service: string,
  url: string,
  init: () => RequestInit,
  attempts: number,
): Promise<Response> {
  return withRetries(
    { service, attempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError },
    async (): Promise<Response> => {
      const response: Response = await platform.fetch(url, init());
      if (!response.ok) {
        await response.body?.cancel();
        throw new UpstreamError(service, response.status, isRetryableStatus(response.status), "yanıt başarısız");
      }
      return response;
    },
  );
}
