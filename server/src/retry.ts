import { errorName, log } from "./log";

/** Yeniden deneme ayarı. */
export interface RetryOptions {
  readonly service: string;
  readonly attempts: number;
  readonly baseDelayMs: number;
  readonly isRetryable: (error: unknown) => boolean;
  /** Her yeniden denemede çağrılır (yönetim panelinin günlük `retry` sayacı; bkz. `Platform.recordRetry`). */
  readonly recordRetry: (service: string) => Promise<void>;
}

/**
 * İşlemi en çok `attempts` kez dener; her başarısız denemede uyarı loglar ve yeniden denemeyi sayar (`recordRetry`),
 * geçici olmayan hatada ya da son denemede hatayı olduğu gibi fırlatır. Bekleme üsteldir: `baseDelayMs * 2^(deneme-1)`.
 */
export async function withRetries<T>(options: RetryOptions, operation: () => Promise<T>): Promise<T> {
  for (let attempt: number = 1; ; attempt += 1) {
    try {
      return await operation();
    } catch (error: unknown) {
      const retryable: boolean = options.isRetryable(error);
      if (!retryable || attempt >= options.attempts) {
        throw error;
      }
      log("warn", "upstream_retry", { service: options.service, attempt, error: errorName(error) });
      await options.recordRetry(options.service);
      const delay: number = options.baseDelayMs * 2 ** (attempt - 1);
      if (delay > 0) {
        await new Promise<void>((resolve: () => void): void => {
          setTimeout(resolve, delay);
        });
      }
    }
  }
}
