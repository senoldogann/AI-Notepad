import type { Config } from "../config";
import type { Platform } from "../platform";
import { type IdentityTokenIssuer, type VerifiedIdentityToken, verifyIdentityToken } from "./identityToken";

export const appleIssuer: string = "https://appleid.apple.com";
export const appleJwksUrl: string = "https://appleid.apple.com/auth/keys";

/** Doğrulanmış Apple kimliği: yalnızca kalıcı `sub` (e-posta saklanmaz, sunucu kullanmaz). */
export interface AppleIdentity {
  readonly subject: string;
}

/** Apple kimlik jetonlarını veren sağlayıcı: JWKS adresi, `iss` ve izinli istemci kimlikleri. Saf fonksiyondur. */
export function appleTokenIssuer(config: Config): IdentityTokenIssuer {
  return {
    displayName: "Apple",
    jwksService: "apple_jwks",
    jwksUrl: appleJwksUrl,
    issuers: [appleIssuer],
    audiences: config.appleClientIds,
  };
}

/**
 * Apple kimlik jetonunu doğrular (`verifyIdentityToken`): Apple JWKS imzası (RS256), `iss`, `aud` (izinli istemci
 * kimlikleri), süre ve tek kullanımlık nonce.
 */
export async function verifyAppleIdentityToken(
  db: D1Database,
  platform: Platform,
  config: Config,
  identityToken: string,
  rawNonce: string,
): Promise<AppleIdentity> {
  const issuer: IdentityTokenIssuer = appleTokenIssuer(config);
  const token: VerifiedIdentityToken = await verifyIdentityToken(db, platform, issuer, identityToken, rawNonce);
  return { subject: token.subject };
}
