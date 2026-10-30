import type { JSONWebKeySet } from "jose";

/** Önbellekteki kimlik sağlayıcısı anahtarları ve alındıkları an (ms). */
export interface CachedJwks {
  readonly keys: JSONWebKeySet;
  readonly fetchedAt: number;
}

/**
 * Dış dünyaya açılan uçlar: dışarı giden istekler, saat, App Attest kök sertifikası, yeniden deneme beklemesi ve sayacı,
 * kimlik sağlayıcısı anahtarlarının (Apple, Google JWKS) önbelleği (JWKS adresi → anahtarlar; Worker örneği başına
 * bellekte). Üretimde `index.ts` gerçek değerleri verir; testler yalnızca bu sınırı değiştirir.
 */
export interface Platform {
  readonly fetch: typeof fetch;
  readonly now: () => Date;
  readonly appAttestRootPem: string;
  readonly retryBaseDelayMs: number;
  readonly jwksCache: Map<string, CachedJwks>;
  /**
   * Üst servis çağrısının yeniden denemesini günlük sayaca yazar (`ops_events` türü `retry`, ayrıntı: servis; bkz.
   * `recordOpsEvents`). Sayaç yazımı hatası yutup uyarı loglar: yeniden deneme sayaç yüzünden düşmez.
   */
  readonly recordRetry: (service: string) => Promise<void>;
}

/** İstek bağlamı: istek boyunca değişmeyen her şey. */
export interface RequestContext {
  readonly platform: Platform;
  readonly waitUntil: (promise: Promise<void>) => void;
  readonly clientIp: string;
}
