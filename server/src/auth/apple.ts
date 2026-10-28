import { type JSONWebKeySet, createLocalJWKSet, errors as joseErrors, jwtVerify } from "jose";
import { z } from "zod";
import type { Config } from "../config";
import { constantTimeEqualText, sha256Hex } from "../crypto";
import { ApiError } from "../errors";
import type { Platform } from "../platform";
import { fetchUpstream } from "../upstream";

export const appleIssuer: string = "https://appleid.apple.com";
export const appleJwksUrl: string = "https://appleid.apple.com/auth/keys";

/** Doğrulanmış Apple kimliği. */
export interface AppleIdentity {
  readonly subject: string;
  readonly email: string | null;
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

/** Apple'ın açık anahtarlarını (JWKS) alır; geçici hatalar yeniden denenir. */
async function fetchAppleJwks(platform: Platform): Promise<JSONWebKeySet> {
  const response: Response = await fetchUpstream(platform, "apple_jwks", appleJwksUrl, (): RequestInit => ({ method: "GET" }), 3);
  const parsed = jwksSchema.safeParse(await response.json());
  if (!parsed.success) {
    throw new ApiError("upstream_unavailable", "Apple anahtarları okunamadı.");
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
 * Apple kimlik jetonunu doğrular: Apple JWKS imzası (RS256), `iss`, `aud` (izinli istemci kimlikleri), süre ve nonce.
 * İstemci ham nonce'u gönderir; Apple'a SHA-256 onaltılık özeti verilmiş olmalıdır (jetondaki `nonce`). Aynı nonce
 * jetonun ömrü boyunca bir daha kabul edilmez.
 */
export async function verifyAppleIdentityToken(
  db: D1Database,
  platform: Platform,
  config: Config,
  identityToken: string,
  rawNonce: string,
): Promise<AppleIdentity> {
  const jwks: JSONWebKeySet = await fetchAppleJwks(platform);
  const now: Date = platform.now();
  let payload: Readonly<Record<string, unknown>>;
  try {
    const verified = await jwtVerify(identityToken, createLocalJWKSet(jwks), {
      algorithms: ["RS256"],
      issuer: appleIssuer,
      audience: [...config.appleClientIds],
      currentDate: now,
      requiredClaims: ["sub", "exp", "iat", "nonce"],
    });
    payload = verified.payload;
  } catch (error: unknown) {
    if (error instanceof joseErrors.JOSEError) {
      throw new ApiError("invalid_token", "Apple kimlik jetonu geçersiz.");
    }
    throw error;
  }
  const claims = z
    .object({
      sub: z.string().min(1),
      exp: z.number(),
      nonce: z.string().min(1),
      email: z.string().optional(),
      email_verified: z.union([z.boolean(), z.literal("true"), z.literal("false")]).optional(),
    })
    .safeParse(payload);
  if (!claims.success) {
    throw new ApiError("invalid_token", "Apple kimlik jetonu beklenen alanları içermiyor.");
  }
  const expectedNonce: string = await sha256Hex(rawNonce);
  if (!(await constantTimeEqualText(claims.data.nonce, expectedNonce))) {
    throw new ApiError("invalid_token", "Apple kimlik jetonundaki nonce eşleşmiyor.");
  }
  // Nonce tek kullanımlıktır: jeton süresi bitene dek saklanır.
  const inserted: D1Result = await db
    .prepare("INSERT OR IGNORE INTO used_nonces (nonce_hash, expires_at) VALUES (?, ?)")
    .bind(expectedNonce, claims.data.exp * 1000)
    .run();
  if (inserted.meta.changes !== 1) {
    throw new ApiError("invalid_token", "Bu Apple kimlik jetonu zaten kullanıldı.");
  }
  const verifiedEmail: boolean = claims.data.email_verified === true || claims.data.email_verified === "true";
  return {
    subject: claims.data.sub,
    email: verifiedEmail && claims.data.email !== undefined ? claims.data.email.toLowerCase() : null,
  };
}
