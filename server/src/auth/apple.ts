import type { Config } from "../config";
import type { Platform } from "../platform";
import { type IdentityTokenIssuer, type VerifiedIdentityToken, verifyIdentityToken } from "./identityToken";

export const appleIssuer: string = "https://appleid.apple.com";
export const appleJwksUrl: string = "https://appleid.apple.com/auth/keys";

/** Doğrulanmış Apple kimliği. */
export interface AppleIdentity {
  readonly subject: string;
  readonly email: string | null;
}

/**
 * Apple kimlik jetonunu doğrular (`verifyIdentityToken`): Apple JWKS imzası (RS256), `iss`, `aud` (izinli istemci
 * kimlikleri), süre ve tek kullanımlık nonce. E-posta yalnızca Apple doğrulanmış dediyse (küçük harfle) döner.
 */
export async function verifyAppleIdentityToken(
  db: D1Database,
  platform: Platform,
  config: Config,
  identityToken: string,
  rawNonce: string,
): Promise<AppleIdentity> {
  const issuer: IdentityTokenIssuer = {
    displayName: "Apple",
    jwksService: "apple_jwks",
    jwksUrl: appleJwksUrl,
    issuers: [appleIssuer],
    audiences: config.appleClientIds,
  };
  const token: VerifiedIdentityToken = await verifyIdentityToken(db, platform, issuer, identityToken, rawNonce);
  return {
    subject: token.subject,
    email: token.emailVerified && token.email !== null ? token.email.toLowerCase() : null,
  };
}
