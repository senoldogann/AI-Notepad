import { UpstreamError, isRetryableStatus } from "./errors";
import type { Platform } from "./platform";
import { withRetries } from "./retry";

/** `AbortSignal.timeout` süresi doldu mu (fetch bu durumda `TimeoutError` adlı DOMException fırlatır). Saf fonksiyondur. */
export function isTimeoutError(error: unknown): boolean {
  return error instanceof DOMException && error.name === "TimeoutError";
}

/** Bağlantı hatası, zaman aşımı ya da geçici durum kodu yeniden denenir. Saf fonksiyondur. */
export function isRetryableUpstreamError(error: unknown): boolean {
  if (error instanceof UpstreamError) {
    return error.retryable;
  }
  // fetch ağ hatasında TypeError fırlatır.
  return error instanceof TypeError || isTimeoutError(error);
}

/**
 * Dış servise istek atar; 2xx dışı yanıtta gövde okunmadan (gizli değer ya da içerik taşıyabilir) `UpstreamError`
 * fırlatır. Her deneme `timeoutMs` sonra kesilir (yanıt başlığına dek; gövde okuması da aynı sinyale bağlıdır). Geçici
 * hatalar ve zaman aşımı `attempts` kez uyarıyla yeniden denenir. `init` her denemede yeniden çağrılır (gövde
 * akışları bir kez okunabilir).
 */
export async function fetchUpstream(
  platform: Platform,
  service: string,
  url: string,
  init: () => RequestInit,
  attempts: number,
  timeoutMs: number,
): Promise<Response> {
  return withRetries(
    { service, attempts, baseDelayMs: platform.retryBaseDelayMs, isRetryable: isRetryableUpstreamError, recordRetry: platform.recordRetry },
    async (): Promise<Response> => {
      const response: Response = await platform.fetch(url, { ...init(), signal: AbortSignal.timeout(timeoutMs) });
      if (!response.ok) {
        await response.body?.cancel();
        throw new UpstreamError(service, response.status, isRetryableStatus(response.status), "yanıt başarısız");
      }
      return response;
    },
  );
}
