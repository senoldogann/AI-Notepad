import { type JSONWebKeySet, type ProtectedHeaderParameters, createLocalJWKSet, decodeProtectedHeader, errors as joseErrors, jwtVerify } from "jose";
import { z } from "zod";
import { constantTimeEqualText, sha256Hex } from "../crypto";
import { ApiError } from "../errors";
import type { CachedJwks, Platform } from "../platform";
import { fetchUpstream } from "../upstream";

/** JWKS isteğinin deneme başına zaman aşımı. */
const jwksTimeoutMs: number = 10_000;
/** Önbellekteki anahtarların ömrü; jetonun `kid`'i önbellekte yoksa daha erken yeniden alınır (anahtar dönüşü). */
export const jwksCacheTtlMs: number = 6 * 3_600_000;

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

/** Sağlayıcının açık anahtarlarını (JWKS) alır; geçici hatalar yeniden denenir. */
async function fetchJwks(platform: Platform, issuer: IdentityTokenIssuer): Promise<JSONWebKeySet> {
  const response: Response = await fetchUpstream(platform, issuer.jwksService, issuer.jwksUrl, (): RequestInit => ({ method: "GET" }), 3, jwksTimeoutMs);
  const parsed = jwksSchema.safeParse(await response.json());
  if (!parsed.success) {
    throw new ApiError("upstream_unavailable", `${issuer.displayName} anahtarları okunamadı.`);
  }
  return {
    keys: parsed.data.keys.map((key: z.output<typeof jwkSchema>) => ({
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
  const keys: JSONWebKeySet = await fetchJwks(platform, issuer);
  platform.jwksCache.set(issuer.jwksUrl, { keys, fetchedAt: nowMs });
  return keys;
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
  const jwks: JSONWebKeySet = await issuerKeys(platform, issuer, tokenKeyId(identityToken, issuer));
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
