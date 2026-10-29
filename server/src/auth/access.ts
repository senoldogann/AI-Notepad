import { type JSONWebKeySet, createLocalJWKSet, errors as joseErrors, jwtVerify } from "jose";
import type { CloudflareAccessConfig } from "../config";
import { ApiError } from "../errors";
import { log } from "../log";
import type { Platform } from "../platform";
import { type IdentityTokenIssuer, issuerKeys, tokenKeyId } from "./identityToken";

/** Cloudflare Access'in yönetici isteğine eklediği imzalı jeton başlığı. */
export const accessJwtHeader: string = "cf-access-jwt-assertion";

/** Access ekibinin JWKS adresi. Saf fonksiyondur. */
export function accessJwksUrl(teamDomain: string): string {
  return `https://${teamDomain}/cdn-cgi/access/certs`;
}

/** `CF_ACCESS_AUD` boşsa (Access denetimi kapalı) uyarı yazar; günlük bakım (`index.ts`) çağırır, günde bir satır. */
export function warnIfAccessCheckDisabled(access: CloudflareAccessConfig): void {
  if (access.audience === null) {
    log("warn", "cf_access_check_disabled", {});
  }
}

/**
 * Yönetici uçlarının ikinci kapısı: istek Cloudflare Access'ten geçmiş olmalı. `Cf-Access-Jwt-Assertion` jetonu ekibin
 * JWKS'iyle (RS256), `iss` = `https://<ekip>`, `aud` ∋ `CF_ACCESS_AUD` ve süreyle doğrulanır. `CF_ACCESS_AUD` boşsa
 * denetim kapalıdır ve yalnızca `ADMIN_IDENTITIES` denetlenir; bunun uyarısı her yönetici isteğinde değil günlük
 * bakımda bir kez yazılır (`warnIfAccessCheckDisabled`). Jeton yoksa ya da geçersizse 403.
 *
 * Üretimde `CF_ACCESS_AUD` bilerek boştur: yönetim paneli (site) API'yi tarayıcıdan, Access çerezi olmadan çağırır;
 * API alan adı Access'in arkasında olmadığı için başlık gelmez ve denetim açılırsa panel 403 alır. Açmadan önce API'nin
 * `/v1/admin/*` yolu panelle aynı Access uygulamasına alınmalı ve panel isteklerini çerezle göndermelidir.
 */
export async function requireCloudflareAccess(platform: Platform, access: CloudflareAccessConfig, request: Request): Promise<void> {
  if (access.audience === null) {
    return;
  }
  const token: string | null = request.headers.get(accessJwtHeader);
  if (token === null || token.length === 0) {
    log("warn", "cf_access_missing", {});
    throw new ApiError("forbidden", "Bu işleme izin yok: Cloudflare Access doğrulaması gerekli.");
  }
  const issuer: IdentityTokenIssuer = {
    displayName: "Cloudflare Access",
    jwksService: "cf_access_jwks",
    jwksUrl: accessJwksUrl(access.teamDomain),
    issuers: [`https://${access.teamDomain}`],
    audiences: [access.audience],
  };
  const keys: JSONWebKeySet = await issuerKeys(platform, issuer, tokenKeyId(token, issuer));
  try {
    await jwtVerify(token, createLocalJWKSet(keys), {
      algorithms: ["RS256"],
      issuer: [...issuer.issuers],
      audience: [...issuer.audiences],
      currentDate: platform.now(),
      requiredClaims: ["exp", "iat"],
    });
  } catch (error: unknown) {
    if (error instanceof joseErrors.JOSEError) {
      log("warn", "cf_access_invalid", { error: error.code });
      throw new ApiError("forbidden", "Bu işleme izin yok: Cloudflare Access jetonu geçersiz.");
    }
    throw error;
  }
}
