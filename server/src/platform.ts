/**
 * Dış dünyaya açılan uçlar: dışarı giden istekler, saat, App Attest kök sertifikası ve yeniden deneme beklemesi.
 * Üretimde `index.ts` gerçek değerleri verir; testler yalnızca bu sınırı değiştirir.
 */
export interface Platform {
  readonly fetch: typeof fetch;
  readonly now: () => Date;
  readonly appAttestRootPem: string;
  readonly retryBaseDelayMs: number;
}

/** İstek bağlamı: istek boyunca değişmeyen her şey. */
export interface RequestContext {
  readonly platform: Platform;
  readonly waitUntil: (promise: Promise<void>) => void;
  readonly clientIp: string;
}
