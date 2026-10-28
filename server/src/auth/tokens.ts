import { SignJWT, errors as joseErrors, jwtVerify } from "jose";
import type { Config } from "../config";
import { randomId, randomToken, sha256Hex, utf8 } from "../crypto";
import { ApiError } from "../errors";
import { log } from "../log";

const accessTokenIssuer: string = "ainotepad-server";
const accessTokenAudience: string = "ainotepad-app";
/** Erişim jetonu ömrü: 15 dakika. */
export const accessTokenTtlSeconds: number = 15 * 60;

/** Doğrulanmış istek sahibi. */
export interface AuthedUser {
  readonly userId: string;
  readonly familyId: string;
}

/** İstemciye verilen oturum jetonları. */
export interface SessionTokens {
  readonly accessToken: string;
  readonly refreshToken: string;
  readonly expiresIn: number;
  readonly userId: string;
}

/** HS256 imzalı, 15 dakikalık erişim jetonu. */
export async function issueAccessToken(config: Config, user: AuthedUser, now: Date): Promise<string> {
  const issuedAt: number = Math.floor(now.getTime() / 1000);
  return new SignJWT({ sid: user.familyId })
    .setProtectedHeader({ alg: "HS256", typ: "JWT" })
    .setIssuer(accessTokenIssuer)
    .setAudience(accessTokenAudience)
    .setSubject(user.userId)
    .setJti(randomId())
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + accessTokenTtlSeconds)
    .sign(utf8(config.secrets.accessToken));
}

/** Erişim jetonunu doğrular (imza, süre, iss, aud, alg). Geçersizse `invalid_token`. */
export async function verifyAccessToken(config: Config, token: string, now: Date): Promise<AuthedUser> {
  try {
    const { payload } = await jwtVerify(token, utf8(config.secrets.accessToken), {
      algorithms: ["HS256"],
      issuer: accessTokenIssuer,
      audience: accessTokenAudience,
      currentDate: now,
      requiredClaims: ["sub", "exp", "sid"],
    });
    const familyId: unknown = payload["sid"];
    if (typeof payload.sub !== "string" || typeof familyId !== "string") {
      throw new ApiError("invalid_token", "Erişim jetonu geçersiz.");
    }
    return { userId: payload.sub, familyId };
  } catch (error: unknown) {
    if (error instanceof ApiError) {
      throw error;
    }
    if (error instanceof joseErrors.JOSEError) {
      throw new ApiError("invalid_token", "Erişim jetonu geçersiz ya da süresi dolmuş.");
    }
    throw error;
  }
}

/** Erişim jetonunu doğrular ve oturum ailesinin düşürülmediğini denetler. */
export async function authenticate(db: D1Database, config: Config, token: string, now: Date): Promise<AuthedUser> {
  const user: AuthedUser = await verifyAccessToken(config, token, now);
  const family: { revoked_at: number | null } | null = await db
    .prepare("SELECT revoked_at FROM refresh_families WHERE id = ? AND user_id = ?")
    .bind(user.familyId, user.userId)
    .first<{ revoked_at: number | null }>();
  if (family === null || family.revoked_at !== null) {
    throw new ApiError("invalid_token", "Oturum kapatılmış; yeniden giriş yap.");
  }
  return user;
}

/**
 * Hesap silme için kimlik: `authenticate` ile aynı denetimler; ancak imzası ve süresi geçerli jetonun kullanıcısı artık
 * yoksa (hesap zaten silinmiş) null döner. Böylece yanıtı kaybolan silme isteği aynı jetonla yeniden denenebilir.
 * Kullanıcı varken düşürülmüş ya da bilinmeyen oturum `invalid_token` olur.
 */
export async function authenticateUnlessDeleted(db: D1Database, config: Config, token: string, now: Date): Promise<AuthedUser | null> {
  const user: AuthedUser = await verifyAccessToken(config, token, now);
  const row: { user_exists: number; revoked_at: number | null; family_exists: number } | null = await db
    .prepare(
      `SELECT EXISTS (SELECT 1 FROM users WHERE id = ?1) AS user_exists,
         EXISTS (SELECT 1 FROM refresh_families WHERE id = ?2 AND user_id = ?1) AS family_exists,
         (SELECT revoked_at FROM refresh_families WHERE id = ?2 AND user_id = ?1) AS revoked_at`,
    )
    .bind(user.userId, user.familyId)
    .first<{ user_exists: number; revoked_at: number | null; family_exists: number }>();
  if (row === null) {
    throw new ApiError("internal_error", "Oturum denetlenemedi.");
  }
  if (row.user_exists === 0) {
    return null;
  }
  if (row.family_exists === 0 || row.revoked_at !== null) {
    throw new ApiError("invalid_token", "Oturum kapatılmış; yeniden giriş yap.");
  }
  return user;
}

/** Yeni oturum ailesi ve ilk yenileme jetonu oluşturur. */
export async function startSession(db: D1Database, config: Config, userId: string, now: Date): Promise<SessionTokens> {
  const familyId: string = randomId();
  const refreshToken: string = randomToken(32);
  await db.batch([
    db.prepare("INSERT INTO refresh_families (id, user_id, created_at) VALUES (?, ?, ?)").bind(familyId, userId, now.getTime()),
    insertRefreshToken(db, config, familyId, await sha256Hex(refreshToken), now),
  ]);
  return {
    accessToken: await issueAccessToken(config, { userId, familyId }, now),
    refreshToken,
    expiresIn: accessTokenTtlSeconds,
    userId,
  };
}

function insertRefreshToken(db: D1Database, config: Config, familyId: string, tokenHash: string, now: Date): D1PreparedStatement {
  return db
    .prepare("INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) VALUES (?, ?, ?, ?)")
    .bind(tokenHash, familyId, now.getTime(), now.getTime() + config.refreshTokenMs);
}

interface RefreshRow {
  readonly family_id: string;
  readonly used_at: number | null;
  readonly expires_at: number;
  readonly user_id: string;
  readonly revoked_at: number | null;
}

/**
 * Yenileme jetonunu tek seferlik kullanır ve aynı ailede yenisini verir. Kullanılmış bir jeton yeniden gelirse
 * (çalınmış olabilir) tüm aile düşürülür ve `invalid_token` döner.
 */
export async function rotateRefreshToken(db: D1Database, config: Config, refreshToken: string, now: Date): Promise<SessionTokens> {
  const tokenHash: string = await sha256Hex(refreshToken);
  // Tek ifade: eşzamanlı iki yenilemeden yalnızca biri jetonu "kullanılmış" yapabilir.
  const claimed: { family_id: string } | null = await db
    .prepare("UPDATE refresh_tokens SET used_at = ? WHERE token_hash = ? AND used_at IS NULL AND expires_at > ? RETURNING family_id")
    .bind(now.getTime(), tokenHash, now.getTime())
    .first<{ family_id: string }>();
  const row: RefreshRow | null = await db
    .prepare(
      `SELECT t.family_id, t.used_at, t.expires_at, f.user_id, f.revoked_at
       FROM refresh_tokens t JOIN refresh_families f ON f.id = t.family_id WHERE t.token_hash = ?`,
    )
    .bind(tokenHash)
    .first<RefreshRow>();
  if (row === null) {
    throw new ApiError("invalid_token", "Yenileme jetonu geçersiz.");
  }
  if (claimed === null) {
    if (row.used_at !== null) {
      await revokeFamily(db, row.family_id, "refresh_reuse", now);
      log("alert", "refresh_token_reuse", { familyId: row.family_id, userId: row.user_id });
      throw new ApiError("invalid_token", "Yenileme jetonu yeniden kullanıldı; tüm oturumlar kapatıldı.");
    }
    throw new ApiError("invalid_token", "Yenileme jetonunun süresi dolmuş.");
  }
  if (row.revoked_at !== null) {
    throw new ApiError("invalid_token", "Oturum kapatılmış; yeniden giriş yap.");
  }
  const nextToken: string = randomToken(32);
  await insertRefreshToken(db, config, row.family_id, await sha256Hex(nextToken), now).run();
  return {
    accessToken: await issueAccessToken(config, { userId: row.user_id, familyId: row.family_id }, now),
    refreshToken: nextToken,
    expiresIn: accessTokenTtlSeconds,
    userId: row.user_id,
  };
}

/** Yenileme jetonunun ailesini düşürür (çıkış). Bilinmeyen jeton sessizce kabul edilmez: `invalid_token`. */
export async function logout(db: D1Database, refreshToken: string, now: Date): Promise<void> {
  const row: { family_id: string } | null = await db
    .prepare("SELECT family_id FROM refresh_tokens WHERE token_hash = ?")
    .bind(await sha256Hex(refreshToken))
    .first<{ family_id: string }>();
  if (row === null) {
    throw new ApiError("invalid_token", "Yenileme jetonu geçersiz.");
  }
  await revokeFamily(db, row.family_id, "logout", now);
}

async function revokeFamily(db: D1Database, familyId: string, reason: string, now: Date): Promise<void> {
  await db
    .prepare("UPDATE refresh_families SET revoked_at = ?, revoke_reason = ? WHERE id = ? AND revoked_at IS NULL")
    .bind(now.getTime(), reason, familyId)
    .run();
}
