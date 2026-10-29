import type { Config } from "../config";
import type { Platform } from "../platform";
import { type IdentityTokenIssuer, type VerifiedIdentityToken, verifyIdentityToken } from "./identityToken";

/** Google kimlik jetonlarının iki geçerli `iss` biçimi (Google belgesi: "Verify the Google ID token"). */
export const googleIssuers: readonly string[] = ["https://accounts.google.com", "accounts.google.com"];
export const googleJwksUrl: string = "https://www.googleapis.com/oauth2/v3/certs";

/** Doğrulanmış Google kimliği: yalnızca kalıcı `sub`. */
export interface GoogleIdentity {
  readonly subject: string;
}

/**
 * Google kimlik jetonunu Apple ile aynı kurallarla doğrular (`verifyIdentityToken`): Google JWKS imzası (RS256), iki
 * `iss` biçiminden biri, `aud` ∈ `GOOGLE_CLIENT_IDS`, süre ve tek kullanımlık nonce (istemci Google'a ham nonce'un
 * SHA-256 onaltılık özetini verir). E-posta saklanmaz (sunucu kullanmaz): bu yüzden `email_verified` da istenmez.
 */
export async function verifyGoogleIdentityToken(
  db: D1Database,
  platform: Platform,
  config: Config,
  identityToken: string,
  rawNonce: string,
): Promise<GoogleIdentity> {
  const issuer: IdentityTokenIssuer = {
    displayName: "Google",
    jwksService: "google_jwks",
    jwksUrl: googleJwksUrl,
    issuers: googleIssuers,
    audiences: config.googleClientIds,
  };
  const token: VerifiedIdentityToken = await verifyIdentityToken(db, platform, issuer, identityToken, rawNonce);
  return { subject: token.subject };
}
