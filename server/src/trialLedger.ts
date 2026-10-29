import type { IdentityProvider } from "./auth/users";
import { hmacSha256Hex } from "./crypto";
import { monthKey, monthStartMs } from "./usage";

/**
 * Kimlik deneme defteri (`trial_identity_ledger`): hesap silinince kimlik başına harcanan deneme toplantısı sayısı,
 * denemenin başladığı an, cihaz doğrulaması ve o ayın (UTC) kullanımı (süre, token, toplantı dışı token) kalır; aynı
 * kimlikle yeniden açılan hesap bunları devralır (`findOrCreateUser`; ay kullanımı yalnızca aynı ay içinde): hesabı silip
 * yeniden açmak denemeyi de aylık sınırları da sıfırlamaz. Kimlik açık saklanmaz, sunucu sırrıyla HMAC özeti tutulur.
 * Satır son güncellemeden 730 gün sonra silinir (`cleanup.ts`).
 */

/** Giriş kimliğinin defter anahtarı: `trial-identity:<sağlayıcı>:<sub>` metninin HMAC-SHA256 özeti (hex). */
export async function trialIdentityHash(secret: string, provider: IdentityProvider, subject: string): Promise<string> {
  return hmacSha256Hex(secret, `trial-identity:${provider}:${subject}`);
}

/**
 * Hesap silinirken kimliğin defter satırını yazan ifade; hesabın satırları silinmeden önce, aynı toplu işlemde
 * çalışmalıdır. Harcanan deneme = devralınan + deneme toplantıları; var olan satırdaki değerler küçülmez (MAX),
 * denemenin başlangıcı en eskisidir (MIN; NULL olmayan kazanır).
 * Bu ayın kullanımı `monthlyUsage` ile aynı tanımdır: devralınan süre + toplantı ve ses süresinin büyüğü (bu ay
 * başlayan toplantılar), kesinleşmiş token ve toplantı dışı token (süren ayırmalar sayılmaz). Defterdeki ay aynıysa her
 * değerin büyüğü kalır, defterdeki ay daha eskiyse (ya da yoksa) bu ayınki yerine geçer; bu ay kullanım yoksa defterdeki
 * ay olduğu gibi kalır.
 * Hesap hiç deneme harcamamış, cihaz doğrulamamış ve bu ay kullanmamışsa satır yazılmaz (saklanacak bir şey yoktur).
 * Hesap yoksa (tekrar silme) bir şey yapmaz.
 */
export function ledgerOnDeletionStatement(db: D1Database, identityHash: string, userId: string, now: Date): D1PreparedStatement {
  // Defterdeki ayın yerine bu ayınki yazılır mı (SQL; `excluded` yeni değerlerdir, yalın sütunlar var olan satırdır).
  const replacesMonth: string = "excluded.usage_month IS NOT NULL AND (usage_month IS NULL OR excluded.usage_month > usage_month)";
  const sameMonth: string = "excluded.usage_month = usage_month";
  return db
    .prepare(
      `INSERT INTO trial_identity_ledger (identity_hash, trial_meetings_used, device_verified, trial_started_at, updated_at,
         usage_month, usage_seconds, usage_tokens, usage_account_tokens)
       SELECT ?1, t.used, t.verified, t.started_at, ?3,
         CASE WHEN t.seconds > 0 OR t.tokens > 0 OR t.account_tokens > 0 THEN ?4 END, t.seconds, t.tokens, t.account_tokens
       FROM (
         SELECT u.carried_trial_meetings + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id AND m.kind = 'trial') AS used,
           CASE WHEN u.trial_device_verified_at IS NULL THEN 0 ELSE 1 END AS verified,
           u.trial_started_at AS started_at,
           COALESCE((SELECT carried_seconds FROM monthly_usage WHERE user_id = u.id AND month = ?4), 0)
             + MAX(
               COALESCE((SELECT SUM(MAX(0, MIN(COALESCE(m.ended_at, ?3), m.max_ends_at, ?3) - m.started_at)) / 1000.0
                 FROM meeting_sessions m WHERE m.user_id = u.id AND m.started_at >= ?5), 0),
               COALESCE((SELECT audio_seconds FROM monthly_usage WHERE user_id = u.id AND month = ?4), 0)
             ) AS seconds,
           COALESCE((SELECT input_tokens + output_tokens FROM monthly_usage WHERE user_id = u.id AND month = ?4), 0) AS tokens,
           COALESCE((SELECT account_tokens FROM monthly_usage WHERE user_id = u.id AND month = ?4), 0) AS account_tokens
         FROM users u WHERE u.id = ?2
       ) t
       WHERE t.used > 0 OR t.verified = 1 OR t.seconds > 0 OR t.tokens > 0 OR t.account_tokens > 0
       ON CONFLICT(identity_hash) DO UPDATE SET
         trial_meetings_used = MAX(trial_meetings_used, excluded.trial_meetings_used),
         device_verified = MAX(device_verified, excluded.device_verified),
         trial_started_at = COALESCE(MIN(trial_started_at, excluded.trial_started_at), trial_started_at, excluded.trial_started_at),
         usage_seconds = CASE WHEN ${replacesMonth} THEN excluded.usage_seconds
           WHEN ${sameMonth} THEN MAX(usage_seconds, excluded.usage_seconds) ELSE usage_seconds END,
         usage_tokens = CASE WHEN ${replacesMonth} THEN excluded.usage_tokens
           WHEN ${sameMonth} THEN MAX(usage_tokens, excluded.usage_tokens) ELSE usage_tokens END,
         usage_account_tokens = CASE WHEN ${replacesMonth} THEN excluded.usage_account_tokens
           WHEN ${sameMonth} THEN MAX(usage_account_tokens, excluded.usage_account_tokens) ELSE usage_account_tokens END,
         usage_month = CASE WHEN ${replacesMonth} THEN excluded.usage_month ELSE usage_month END,
         updated_at = excluded.updated_at`,
    )
    .bind(identityHash, userId, now.getTime(), monthKey(now), monthStartMs(now));
}

/**
 * Yeni kullanıcı satırını ekleyen ifade: kimliğin defter satırı varsa harcanan deneme sayısı ve denemenin başladığı an
 * devralınır, cihaz doğrulanmışsa `trial_device_verified_at` şimdi olur; yoksa sıfır ve NULL.
 */
export function insertUserFromLedgerStatement(db: D1Database, userId: string, identityHash: string, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO users (id, created_at, carried_trial_meetings, trial_device_verified_at, trial_started_at)
       SELECT ?1, ?2,
         COALESCE((SELECT trial_meetings_used FROM trial_identity_ledger WHERE identity_hash = ?3), 0),
         (SELECT ?2 FROM trial_identity_ledger WHERE identity_hash = ?3 AND device_verified = 1),
         (SELECT trial_started_at FROM trial_identity_ledger WHERE identity_hash = ?3)`,
    )
    .bind(userId, now.getTime(), identityHash);
}

/**
 * Yeni kullanıcının bu ayki kullanımını defterden başlatan ifade (`insertUserFromLedgerStatement`'tan sonra, aynı toplu
 * işlemde): defterdeki ay bu aysa süre `monthly_usage.carried_seconds`'a (aylık süre sınırına eklenir), token'lar
 * kesinleşmiş kullanıma yazılır; başka aysa ya da satır yoksa bir şey yapmaz (yeni ay sıfırdan başlar).
 */
export function seedMonthlyUsageFromLedgerStatement(db: D1Database, userId: string, identityHash: string, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO monthly_usage (user_id, month, carried_seconds, input_tokens, account_tokens)
       SELECT ?1, usage_month, usage_seconds, usage_tokens, usage_account_tokens
       FROM trial_identity_ledger WHERE identity_hash = ?2 AND usage_month = ?3`,
    )
    .bind(userId, identityHash, monthKey(now));
}
