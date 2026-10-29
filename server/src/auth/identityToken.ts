import { type JSONWebKeySet, type ProtectedHeaderParameters, createLocalJWKSet, decodeProtectedHeader, errors as joseErrors, jwtVerify } from "jose";
import { z } from "zod";
import { constantTimeEqualText, sha256Hex } from "../crypto";
import { ApiError, UpstreamError } from "../errors";
import { errorName, log } from "../log";
import type { CachedJwks, Platform } from "../platform";
import { fetchUpstream, isRetryableUpstreamError } from "../upstream";

/** JWKS isteğinin deneme başına zaman aşımı. */
const jwksTimeoutMs: number = 10_000;
/** Önbellekteki anahtarların ömrü; jetonun `kid`'i önbellekte yoksa daha erken yeniden alınır (anahtar dönüşü). */
export const jwksCacheTtlMs: number = 6 * 3_600_000;
/**
 * Sağlayıcıya ulaşılamazken kayıtlı anahtarların hâlâ kullanılabildiği en uzun yaş: sağlayıcılar anahtarlarını
 * haftalarca önceden yayınlar ve eskisini bir süre daha geçerli tutar; jetonun `kid`'i kayıtta yoksa kullanılmaz.
 */
export const jwksStaleMaxMs: number = 7 * 24 * 3_600_000;
/** Kayıtlı anahtar varken sağlayıcıya yapılan tazeleme denemesinin zaman aşımı (giriş beklemesin). */
const jwksRefreshTimeoutMs: number = 4_000;

/** Kimlik jetonu veren sağlayıcı (OpenID Connect): JWKS adresi, kabul edilen `iss` ve `aud` değerleri. */
export interface IdentityTokenIssuer {
  /** Kullanıcıya dönen mesajlardaki ad ("Apple", "Google"). */
  readonly displayName: string;
  /** Yeniden deneme loglarındaki servis adı. */
  readonly jwksService: string;
  readonly jwksUrl: string;
  readonly issuers: readonly string[];
  readonly audiences: readonly string[];
}

/** Doğrulanmış kimlik jetonunun kullanılan alanı: kalıcı kullanıcı kimliği (`sub`). */
export interface VerifiedIdentityToken {
  readonly subject: string;
}

const jwkSchema = z.object({
  kty: z.literal("RSA"),
  kid: z.string().min(1),
  use: z.string().optional(),
  alg: z.string().optional(),
  n: z.string().min(1),
  e: z.string().min(1),
});
const jwksSchema = z.object({ keys: z.array(jwkSchema).min(1) });

const claimsSchema = z.object({
  sub: z.string().min(1),
  exp: z.number(),
  nonce: z.string().min(1),
});

/** Sağlayıcının açık anahtarlarını (JWKS) alır; geçici hatalar `attempts` kez yeniden denenir. */
async function fetchJwks(platform: Platform, issuer: IdentityTokenIssuer, attempts: number, timeoutMs: number): Promise<JSONWebKeySet> {
  const response: Response = await fetchUpstream(platform, issuer.jwksService, issuer.jwksUrl, (): RequestInit => ({ method: "GET" }), attempts, timeoutMs);
  const parsed = jwksSchema.safeParse(await response.json());
  if (!parsed.success) {
    throw new ApiError("upstream_unavailable", `${issuer.displayName} anahtarları okunamadı.`);
  }
  return jwksFromParsed(parsed.data);
}

/** Doğrulanmış JWKS gövdesinden yalnızca gereken alanlarla anahtar kümesi. Saf fonksiyondur. */
function jwksFromParsed(data: z.output<typeof jwksSchema>): JSONWebKeySet {
  return {
    keys: data.keys.map((key: z.output<typeof jwkSchema>) => ({
      kty: key.kty,
      kid: key.kid,
      n: key.n,
      e: key.e,
      ...(key.alg === undefined ? {} : { alg: key.alg }),
      ...(key.use === undefined ? {} : { use: key.use }),
    })),
  };
}

/** Jetonun başlığındaki `kid`; başlık çözülemezse `invalid_token`. */
export function tokenKeyId(identityToken: string, issuer: IdentityTokenIssuer): string | null {
  let header: ProtectedHeaderParameters;
  try {
    header = decodeProtectedHeader(identityToken);
  } catch (error: unknown) {
    if (error instanceof TypeError || error instanceof joseErrors.JOSEError) {
      throw new ApiError("invalid_token", `${issuer.displayName} kimlik jetonu geçersiz.`);
    }
    throw error;
  }
  return typeof header.kid === "string" ? header.kid : null;
}

/**
 * Sağlayıcının anahtarları: önbellekte taze (`jwksCacheTtlMs`) ve jetonun `kid`'ini içeren kayıt varsa o; yoksa
 * (ilk istek, süresi dolmuş ya da bilinmeyen `kid`: anahtar dönüşü) yeniden alınır ve önbelleğe yazılır.
 */
export async function issuerKeys(platform: Platform, issuer: IdentityTokenIssuer, keyId: string | null): Promise<JSONWebKeySet> {
  const nowMs: number = platform.now().getTime();
  const cached: CachedJwks | undefined = platform.jwksCache.get(issuer.jwksUrl);
  if (cached !== undefined && nowMs - cached.fetchedAt < jwksCacheTtlMs && cached.keys.keys.some((key): boolean => key.kid === keyId)) {
    return cached.keys;
  }
  const keys: JSONWebKeySet = await fetchJwks(platform, issuer, 3, jwksTimeoutMs);
  platform.jwksCache.set(issuer.jwksUrl, { keys, fetchedAt: nowMs });
  return keys;
}

/** Kayıt jetonun `kid`'ini içeriyor ve yaşı `maxAgeMs`'ten küçükse o kayıt; değilse null. Saf fonksiyondur. */
function usableJwks(cached: CachedJwks | undefined, keyId: string | null, nowMs: number, maxAgeMs: number): CachedJwks | null {
  if (cached === undefined || nowMs - cached.fetchedAt >= maxAgeMs || !cached.keys.keys.some((key): boolean => key.kid === keyId)) {
    return null;
  }
  return cached;
}

/** D1'deki kayıtlı anahtarlar; yoksa ya da bozuksa undefined (bozuk kayıt uyarıyla yok sayılır, yeniden alınır). */
async function storedJwks(db: D1Database, jwksUrl: string): Promise<CachedJwks | undefined> {
  const row: { keys_json: string; fetched_at: number } | null = await db
    .prepare("SELECT keys_json, fetched_at FROM identity_jwks WHERE jwks_url = ?")
    .bind(jwksUrl)
    .first<{ keys_json: string; fetched_at: number }>();
  if (row === null) {
    return undefined;
  }
  const parsed = jwksSchema.safeParse(JSON.parse(row.keys_json));
  if (!parsed.success) {
    log("warn", "jwks_store_invalid", { jwksUrl });
    return undefined;
  }
  return { keys: jwksFromParsed(parsed.data), fetchedAt: row.fetched_at };
}

/** Sağlayıcıdan alınan anahtarları D1'e ve belleğe yazar. */
async function saveJwks(db: D1Database, platform: Platform, jwksUrl: string, keys: JSONWebKeySet, nowMs: number): Promise<void> {
  await db
    .prepare(
      `INSERT INTO identity_jwks (jwks_url, keys_json, fetched_at) VALUES (?1, ?2, ?3)
       ON CONFLICT (jwks_url) DO UPDATE SET keys_json = ?2, fetched_at = ?3`,
    )
    .bind(jwksUrl, JSON.stringify(keys), nowMs)
    .run();
  platform.jwksCache.set(jwksUrl, { keys, fetchedAt: nowMs });
}

/**
 * Giriş için sağlayıcının anahtarları: bellekte ya da D1'de taze (`jwksCacheTtlMs`) ve jetonun `kid`'ini içeren kayıt
 * varsa o (Worker örnekleri kısa ömürlü; D1 tüm örneklerde ortak). Yoksa sağlayıcıdan alınıp kaydedilir. Kayıt
 * eskimiş ama `jwksStaleMaxMs`'ten genç ve `kid`'i içeriyorsa sağlayıcı yalnızca bir kez, kısa zaman aşımıyla denenir;
 * yanıt vermezse (zaman aşımı, ağ hatası, 5xx) kayıtlı anahtarlar uyarıyla kullanılır: sağlayıcının yavaşlığı girişi
 * düşürmez. `kid` hiçbir kayıtta yoksa (anahtar dönüşü) sağlayıcı tam yeniden denemeyle alınır; alınamazsa hata.
 */
export async function persistedIssuerKeys(db: D1Database, platform: Platform, issuer: IdentityTokenIssuer, keyId: string | null): Promise<JSONWebKeySet> {
  const nowMs: number = platform.now().getTime();
  const inMemory: CachedJwks | null = usableJwks(platform.jwksCache.get(issuer.jwksUrl), keyId, nowMs, jwksCacheTtlMs);
  if (inMemory !== null) {
    return inMemory.keys;
  }
  const record: CachedJwks | undefined = await storedJwks(db, issuer.jwksUrl);
  const fresh: CachedJwks | null = usableJwks(record, keyId, nowMs, jwksCacheTtlMs);
  if (fresh !== null) {
    platform.jwksCache.set(issuer.jwksUrl, fresh);
    return fresh.keys;
  }
  const stored: CachedJwks | null = usableJwks(record, keyId, nowMs, jwksStaleMaxMs);
  if (stored === null) {
    const keys: JSONWebKeySet = await fetchJwks(platform, issuer, 3, jwksTimeoutMs);
    await saveJwks(db, platform, issuer.jwksUrl, keys, nowMs);
    return keys;
  }
  try {
    const keys: JSONWebKeySet = await fetchJwks(platform, issuer, 1, jwksRefreshTimeoutMs);
    await saveJwks(db, platform, issuer.jwksUrl, keys, nowMs);
    return keys;
  } catch (error: unknown) {
    if (!(error instanceof UpstreamError || isRetryableUpstreamError(error))) {
      throw error;
    }
    log("warn", "jwks_stale_used", { service: issuer.jwksService, ageMs: nowMs - stored.fetchedAt, error: errorName(error) });
    return stored.keys;
  }
}

/** Günlük bakım: sağlayıcının anahtarlarını önceden alır ve kaydeder (girişler sağlayıcıyı beklemesin). */
export async function refreshPersistedIssuerKeys(db: D1Database, platform: Platform, issuer: IdentityTokenIssuer): Promise<void> {
  const keys: JSONWebKeySet = await fetchJwks(platform, issuer, 3, jwksTimeoutMs);
  await saveJwks(db, platform, issuer.jwksUrl, keys, platform.now().getTime());
  log("info", "jwks_refreshed", { service: issuer.jwksService, keys: keys.keys.length });
}

/**
 * Kimlik jetonunu doğrular: sağlayıcının JWKS imzası (yalnızca RS256), `iss`, `aud` (izinli istemci kimlikleri), süre
 * (`exp`; `sub`, `iat`, `nonce` zorunlu) ve nonce. İstemci ham nonce'u gönderir; sağlayıcıya SHA-256 onaltılık özeti
 * verilmiş olmalıdır (jetondaki `nonce`, sabit zamanlı karşılaştırılır). Aynı nonce jetonun ömrü boyunca bir daha kabul
 * edilmez (`used_nonces`, tüm sağlayıcılar için ortak).
 */
export async function verifyIdentityToken(
  db: D1Database,
  platform: Platform,
  issuer: IdentityTokenIssuer,
  identityToken: string,
  rawNonce: string,
): Promise<VerifiedIdentityToken> {
  const jwks: JSONWebKeySet = await persistedIssuerKeys(db, platform, issuer, tokenKeyId(identityToken, issuer));
  let payload: Readonly<Record<string, unknown>>;
  try {
    const verified = await jwtVerify(identityToken, createLocalJWKSet(jwks), {
      algorithms: ["RS256"],
      issuer: [...issuer.issuers],
      audience: [...issuer.audiences],
      currentDate: platform.now(),
      requiredClaims: ["sub", "exp", "iat", "nonce"],
    });
    payload = verified.payload;
  } catch (error: unknown) {
    if (error instanceof joseErrors.JOSEError) {
      throw new ApiError("invalid_token", `${issuer.displayName} kimlik jetonu geçersiz.`);
    }
    throw error;
  }
  const claims = claimsSchema.safeParse(payload);
  if (!claims.success) {
    throw new ApiError("invalid_token", `${issuer.displayName} kimlik jetonu beklenen alanları içermiyor.`);
  }
  const expectedNonce: string = await sha256Hex(rawNonce);
  if (!(await constantTimeEqualText(claims.data.nonce, expectedNonce))) {
    throw new ApiError("invalid_token", `${issuer.displayName} kimlik jetonundaki nonce eşleşmiyor.`);
  }
  // Nonce tek kullanımlıktır: jeton süresi bitene dek saklanır.
  const inserted: D1Result = await db
    .prepare("INSERT OR IGNORE INTO used_nonces (nonce_hash, expires_at) VALUES (?, ?)")
    .bind(expectedNonce, claims.data.exp * 1000)
    .run();
  if (inserted.meta.changes !== 1) {
    throw new ApiError("invalid_token", `Bu ${issuer.displayName} kimlik jetonu zaten kullanıldı.`);
  }
  return { subject: claims.data.sub };
}
