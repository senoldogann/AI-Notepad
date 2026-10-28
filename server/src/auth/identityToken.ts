import { type JSONWebKeySet, createLocalJWKSet, errors as joseErrors, jwtVerify } from "jose";
import { z } from "zod";
import { constantTimeEqualText, sha256Hex } from "../crypto";
import { ApiError } from "../errors";
import type { Platform } from "../platform";
import { fetchUpstream } from "../upstream";

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

/** Doğrulanmış kimlik jetonunun kullanılan alanları. */
export interface VerifiedIdentityToken {
  readonly subject: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
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
  email: z.string().optional(),
  email_verified: z.union([z.boolean(), z.literal("true"), z.literal("false")]).optional(),
});

/** Sağlayıcının açık anahtarlarını (JWKS) alır; geçici hatalar yeniden denenir. */
async function fetchJwks(platform: Platform, issuer: IdentityTokenIssuer): Promise<JSONWebKeySet> {
  const response: Response = await fetchUpstream(platform, issuer.jwksService, issuer.jwksUrl, (): RequestInit => ({ method: "GET" }), 3);
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
  const jwks: JSONWebKeySet = await fetchJwks(platform, issuer);
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
  return {
    subject: claims.data.sub,
    email: claims.data.email ?? null,
    emailVerified: claims.data.email_verified === true || claims.data.email_verified === "true",
  };
}
