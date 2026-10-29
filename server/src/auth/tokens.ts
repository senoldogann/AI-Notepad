import { SignJWT, errors as joseErrors, jwtVerify } from "jose";
import type { Config } from "../config";
import { randomId, randomToken, sha256Hex, utf8 } from "../crypto";
import { ApiError } from "../errors";
import { log } from "../log";

const accessTokenIssuer: string = "ainotepad-server";
const accessTokenAudience: string = "ainotepad-app";
/** Erişim jetonu ömrü: 15 dakika. */
export const accessTokenTtlSeconds: number = 15 * 60;
/**
 * Yanıtı kaybolan yenilemenin aynı jetonla yeniden denenebildiği süre (jetonun kullanıldığı andan): istemcinin isteği
 * zaman aşımına uğrar ya da bağlantı koparsa sunucu jetonu döndürmüş olabilir; istemci eski jetonu tutar ve yeniden
 * sunar. Bu süre içinde, yerine geçen jeton hiç kullanılmadıysa aile düşürülmez (bkz. `rotateRefreshToken`).
 * İstemcinin istek zaman aşımından (30 sn) ve yeniden denemelerinden çok uzundur.
 */
export const refreshRetryWindowMs: number = 10 * 60_000;

/**
 * Yeniden denemede yerine yenisi verilen (kullanılmamış) eski halefin `replaced_by` işareti. Satır silinmez: o jeton
 * sonradan gelirse eski jeton iki ayrı eldeymiş demektir (biri yeniden denedi, öbürü halefi tutuyordu) ve tüm aile
 * düşürülür. Dönüşteki temizlik bu satırları silmez.
 */
const supersededMarker: string = "superseded";

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
  readonly replaced_by: string | null;
  readonly user_id: string;
  readonly revoked_at: number | null;
}

/** Ailenin kullanıcısına yeni erişim jetonu ve verilen yenileme jetonuyla oturum yanıtı. */
async function sessionFor(config: Config, row: RefreshRow, refreshToken: string, now: Date): Promise<SessionTokens> {
  return {
    accessToken: await issueAccessToken(config, { userId: row.user_id, familyId: row.family_id }, now),
    refreshToken,
    expiresIn: accessTokenTtlSeconds,
    userId: row.user_id,
  };
}

/**
 * Yenileme jetonunu tek seferlik kullanır ve aynı ailede yenisini verir; kullanılan jetonun yerine geçen jeton
 * (`replaced_by`) yazılır. Jetonu "kullanılmış" yapma, yenisini ekleme ve eski jetonları silme tek D1 toplu işlemidir
 * (`claimAndRotate`): istek yarıda kalırsa ya hepsi olur ya hiçbiri; jeton kullanılmış sayılıp yerine geçen jeton
 * eklenmemiş kalamaz. Ailede yalnızca son iki kullanılmış jeton (şimdi kullanılan ve ondan önceki) kalır, daha eskileri
 * silinir: tablo oturum başına büyümez, yeniden kullanım algılaması bir kuşak geriye bakar.
 *
 * Kullanılmış bir jeton yeniden gelirse kural:
 * - yerine geçen jeton hiç kullanılmadıysa ve jeton `refreshRetryWindowMs` içinde kullanıldıysa yanıt kaybolmuştur
 *   (istemci zaman aşımı ya da kopan bağlantıdan sonra aynı jetonu yeniden sunuyor): kullanılmamış eski halef
 *   `supersededMarker` ile geçersiz yazılır, yeni çift verilir; aile düşürülmez;
 * - geçersiz yazılmış halef sonradan gelirse eski jeton iki ayrı eldeydi (ör. çalınan eski jeton süre içinde yeniden
 *   denendi, gerçek istemci halefi tutuyordu): tüm aile düşürülür ve alarm yazılır;
 * - yerine geçen jeton kullanıldıysa (jeton iki ayrı elde) ya da süre geçtiyse jeton çalınmış olabilir: tüm aile
 *   düşürülür, `refresh_token_reuse` alarmı yazılır ve `invalid_token` döner.
 */
export async function rotateRefreshToken(db: D1Database, config: Config, refreshToken: string, now: Date): Promise<SessionTokens> {
  const tokenHash: string = await sha256Hex(refreshToken);
  const nextToken: string = randomToken(32);
  const nextHash: string = await sha256Hex(nextToken);
  const claimed: boolean = await claimAndRotate(db, config, tokenHash, nextHash, now);
  const row: RefreshRow | null = await db
    .prepare(
      `SELECT t.family_id, t.used_at, t.expires_at, t.replaced_by, f.user_id, f.revoked_at
       FROM refresh_tokens t JOIN refresh_families f ON f.id = t.family_id WHERE t.token_hash = ?`,
    )
    .bind(tokenHash)
    .first<RefreshRow>();
  if (row === null) {
    throw new ApiError("invalid_token", "Yenileme jetonu geçersiz.");
  }
  if (claimed) {
    return sessionFor(config, row, nextToken, now);
  }
  if (row.revoked_at !== null) {
    throw new ApiError("invalid_token", "Oturum kapatılmış; yeniden giriş yap.");
  }
  if (row.used_at === null) {
    throw new ApiError("invalid_token", "Yenileme jetonunun süresi dolmuş.");
  }
  if (row.replaced_by === supersededMarker) {
    await revokeFamily(db, row.family_id, "refresh_superseded_reuse", now);
    log("alert", "refresh_token_superseded_reuse", { familyId: row.family_id, userId: row.user_id });
    throw new ApiError("invalid_token", "Yenileme jetonu yeniden kullanıldı; tüm oturumlar kapatıldı.");
  }
  if (await replaceUnusedSuccessor(db, config, row, tokenHash, nextHash, now)) {
    log("warn", "refresh_token_retried", { familyId: row.family_id, userId: row.user_id });
    return sessionFor(config, row, nextToken, now);
  }
  await revokeFamily(db, row.family_id, "refresh_reuse", now);
  log("alert", "refresh_token_reuse", { familyId: row.family_id, userId: row.user_id });
  throw new ApiError("invalid_token", "Yenileme jetonu yeniden kullanıldı; tüm oturumlar kapatıldı.");
}

/**
 * Tek toplu işlemde (D1 işlemi): jeton kullanılmamış, süresi dolmamış ve ailesi düşürülmemişse "kullanılmış" yapılır ve
 * `replaced_by` yeni jetonu gösterir; yeni jeton eklenir; ailenin kullanılmış jetonlarından bu jeton ve ondan önceki
 * (yerine bu jetonun geçtiği) dışındakiler silinir. Sonraki ifadeler yalnızca ilki uygulandıysa etkilidir (yeni jetonun
 * özeti rastgeledir: `replaced_by = yeni` yalnızca bu istekte doğrudur); eşzamanlı iki yenilemeden yalnızca biri jetonu
 * alabilir. Alındıysa true.
 */
async function claimAndRotate(db: D1Database, config: Config, tokenHash: string, nextHash: string, now: Date): Promise<boolean> {
  const nowMs: number = now.getTime();
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE refresh_tokens SET used_at = ?1, replaced_by = ?2
         WHERE token_hash = ?3 AND used_at IS NULL AND expires_at > ?1
           AND family_id IN (SELECT id FROM refresh_families WHERE revoked_at IS NULL)`,
      )
      .bind(nowMs, nextHash, tokenHash),
    db
      .prepare(
        `INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at)
         SELECT ?1, family_id, ?2, ?3 FROM refresh_tokens WHERE token_hash = ?4 AND replaced_by = ?1`,
      )
      .bind(nextHash, nowMs, nowMs + config.refreshTokenMs, tokenHash),
    db
      .prepare(
        `DELETE FROM refresh_tokens
         WHERE family_id = (SELECT family_id FROM refresh_tokens WHERE token_hash = ?1 AND replaced_by = ?2)
           AND used_at IS NOT NULL AND token_hash <> ?1 AND COALESCE(replaced_by, '') NOT IN (?1, ?3)`,
      )
      .bind(tokenHash, nextHash, supersededMarker),
  ]);
  return results[0]?.meta.changes === 1;
}

/**
 * Yanıtı kaybolan yenilemenin yeniden denenmesi: jeton `refreshRetryWindowMs` içinde kullanılmış ve yerine geçen jeton
 * hiç kullanılmamışsa, tek toplu işlemde kullanılmamış eski halef `supersededMarker` ile geçersiz yazılır (silinmez:
 * sonradan gelirse aile düşer), yenisi eklenir ve `replaced_by` yenisini gösterir. Koşul ilk ifadededir; sonraki ifadeler yalnızca o başarılıysa etkilidir (eşzamanlı iki yeniden deneme
 * ikisi birden geçemez). Uygulandıysa true; halef kullanıldıysa ya da süre geçtiyse false (yeniden kullanım).
 */
async function replaceUnusedSuccessor(db: D1Database, config: Config, row: RefreshRow, tokenHash: string, nextHash: string, now: Date): Promise<boolean> {
  if (row.replaced_by === null || row.replaced_by === supersededMarker || row.used_at === null || now.getTime() - row.used_at > refreshRetryWindowMs) {
    return false;
  }
  const previousSuccessor: string = row.replaced_by;
  const applied: string = "(SELECT replaced_by FROM refresh_tokens WHERE token_hash = ?) = ?";
  // Halef satırı hiç yoksa da kullanılmamış sayılır (eski sürümde jeton kullanılmış yazılıp halef eklenmeden kalmış olabilir).
  const results: D1Result[] = await db.batch([
    db
      .prepare(
        `UPDATE refresh_tokens SET replaced_by = ? WHERE token_hash = ? AND replaced_by = ?
         AND NOT EXISTS (SELECT 1 FROM refresh_tokens WHERE token_hash = ? AND used_at IS NOT NULL)`,
      )
      .bind(nextHash, tokenHash, previousSuccessor, previousSuccessor),
    db
      .prepare(`UPDATE refresh_tokens SET used_at = ?, replaced_by = ? WHERE token_hash = ? AND used_at IS NULL AND ${applied}`)
      .bind(now.getTime(), supersededMarker, previousSuccessor, tokenHash, nextHash),
    db
      .prepare(`INSERT INTO refresh_tokens (token_hash, family_id, created_at, expires_at) SELECT ?, ?, ?, ? WHERE ${applied}`)
      .bind(nextHash, row.family_id, now.getTime(), now.getTime() + config.refreshTokenMs, tokenHash, nextHash),
  ]);
  return results[0]?.meta.changes === 1;
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
