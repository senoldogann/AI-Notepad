import type { IdentityProvider } from "./auth/users";
import { hmacSha256Hex } from "./crypto";

/**
 * Kimlik deneme defteri (`trial_identity_ledger`): hesap silinince kimlik başına harcanan deneme toplantısı sayısı ve
 * cihaz doğrulaması kalır; aynı kimlikle yeniden açılan hesap bunları devralır (`findOrCreateUser`). Kimlik açık
 * saklanmaz, sunucu sırrıyla HMAC özeti tutulur. Satır son güncellemeden 730 gün sonra silinir (`cleanup.ts`).
 */

/** Giriş kimliğinin defter anahtarı: `trial-identity:<sağlayıcı>:<sub>` metninin HMAC-SHA256 özeti (hex). */
export async function trialIdentityHash(secret: string, provider: IdentityProvider, subject: string): Promise<string> {
  return hmacSha256Hex(secret, `trial-identity:${provider}:${subject}`);
}

/**
 * Hesap silinirken kimliğin defter satırını yazan ifade; hesabın satırları silinmeden önce, aynı toplu işlemde
 * çalışmalıdır. Harcanan deneme = devralınan + deneme toplantıları; var olan satırdaki değerler küçülmez (MAX).
 * Hesap hiç deneme harcamamış ve cihaz doğrulamamışsa satır yazılmaz (saklanacak bir şey yoktur). Hesap yoksa (tekrar
 * silme) bir şey yapmaz.
 */
export function ledgerOnDeletionStatement(db: D1Database, identityHash: string, userId: string, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO trial_identity_ledger (identity_hash, trial_meetings_used, device_verified, updated_at)
       SELECT ?1, t.used, t.verified, ?3 FROM (
         SELECT u.carried_trial_meetings + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id AND m.kind = 'trial') AS used,
           CASE WHEN u.trial_device_verified_at IS NULL THEN 0 ELSE 1 END AS verified
         FROM users u WHERE u.id = ?2
       ) t
       WHERE t.used > 0 OR t.verified = 1
       ON CONFLICT(identity_hash) DO UPDATE SET
         trial_meetings_used = MAX(trial_meetings_used, excluded.trial_meetings_used),
         device_verified = MAX(device_verified, excluded.device_verified),
         updated_at = excluded.updated_at`,
    )
    .bind(identityHash, userId, now.getTime());
}

/**
 * Yeni kullanıcı satırını ekleyen ifade: kimliğin defter satırı varsa harcanan deneme sayısı devralınır ve cihaz
 * doğrulanmışsa `trial_device_verified_at` şimdi olur; yoksa sıfır ve NULL.
 */
export function insertUserFromLedgerStatement(db: D1Database, userId: string, identityHash: string, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO users (id, created_at, carried_trial_meetings, trial_device_verified_at)
       SELECT ?1, ?2,
         COALESCE((SELECT trial_meetings_used FROM trial_identity_ledger WHERE identity_hash = ?3), 0),
         (SELECT ?2 FROM trial_identity_ledger WHERE identity_hash = ?3 AND device_verified = 1)`,
    )
    .bind(userId, now.getTime(), identityHash);
}
