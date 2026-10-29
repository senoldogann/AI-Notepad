import type { IdentityProvider } from "./auth/users";
import { hmacSha256Hex } from "./crypto";
import { dayKey, monthKey, monthStartMs, monthlyUsedSecondsSql } from "./usage";

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
 * Bu ayın kullanımı `monthlyUsage` ile aynı tanımdır (`monthlyUsedSecondsSql`), kesinleşmiş token ve toplantı dışı
 * token (süren ayırmalar sayılmaz). Defterdeki ay aynıysa her değerin büyüğü kalır, defterdeki ay daha eskiyse (ya da
 * yoksa) bu ayınki yerine geçer; bu ay kullanım yoksa defterdeki ay olduğu gibi kalır. Bugünün sayaçları (token,
 * denemedeki toplantı dışı token, başlatılan toplantı) aynı kuralla gün için tutulur.
 * Hesap hiç deneme harcamamış, cihaz doğrulamamış ve bu ay kullanmamışsa satır yazılmaz (saklanacak bir şey yoktur).
 * Hesap yoksa (tekrar silme) bir şey yapmaz.
 */
export function ledgerOnDeletionStatement(db: D1Database, identityHash: string, userId: string, now: Date): D1PreparedStatement {
  // Defterdeki ayın yerine bu ayınki yazılır mı (SQL; `excluded` yeni değerlerdir, yalın sütunlar var olan satırdır).
  const replacesMonth: string = "excluded.usage_month IS NOT NULL AND (usage_month IS NULL OR excluded.usage_month > usage_month)";
  const sameMonth: string = "excluded.usage_month = usage_month";
  const replacesDay: string = "excluded.usage_day IS NOT NULL AND (usage_day IS NULL OR excluded.usage_day > usage_day)";
  const sameDay: string = "excluded.usage_day = usage_day";
  const dayValue = (column: string): string =>
    `${column} = CASE WHEN ${replacesDay} THEN excluded.${column} WHEN ${sameDay} THEN MAX(${column}, excluded.${column}) ELSE ${column} END`;
  return db
    .prepare(
      `INSERT INTO trial_identity_ledger (identity_hash, trial_meetings_used, device_verified, trial_started_at, updated_at,
         usage_month, usage_seconds, usage_tokens, usage_account_tokens,
         usage_day, usage_day_tokens, usage_day_trial_account_tokens, usage_day_meetings_started)
       SELECT ?1, t.used, t.verified, t.started_at, ?3,
         CASE WHEN t.seconds > 0 OR t.tokens > 0 OR t.account_tokens > 0 THEN ?4 END, t.seconds, t.tokens, t.account_tokens,
         CASE WHEN t.day_tokens > 0 OR t.day_trial_tokens > 0 OR t.day_meetings > 0 THEN ?6 END, t.day_tokens, t.day_trial_tokens, t.day_meetings
       FROM (
         SELECT u.carried_trial_meetings + (SELECT COUNT(*) FROM meeting_sessions m WHERE m.user_id = u.id AND m.kind = 'trial') AS used,
           CASE WHEN u.trial_device_verified_at IS NULL THEN 0 ELSE 1 END AS verified,
           u.trial_started_at AS started_at,
           ${monthlyUsedSecondsSql({ user: "u.id", month: "?4", now: "?3", monthStart: "?5" })} AS seconds,
           COALESCE((SELECT input_tokens + output_tokens FROM monthly_usage WHERE user_id = u.id AND month = ?4), 0) AS tokens,
           COALESCE((SELECT account_tokens FROM monthly_usage WHERE user_id = u.id AND month = ?4), 0) AS account_tokens,
           COALESCE((SELECT tokens_used FROM daily_usage WHERE user_id = u.id AND day = ?6), 0) AS day_tokens,
           COALESCE((SELECT trial_account_tokens_used FROM daily_usage WHERE user_id = u.id AND day = ?6), 0) AS day_trial_tokens,
           COALESCE((SELECT meetings_started FROM daily_usage WHERE user_id = u.id AND day = ?6), 0) AS day_meetings
         FROM users u WHERE u.id = ?2
       ) t
       WHERE t.used > 0 OR t.verified = 1 OR t.seconds > 0 OR t.tokens > 0 OR t.account_tokens > 0
         OR t.day_tokens > 0 OR t.day_trial_tokens > 0 OR t.day_meetings > 0
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
         ${dayValue("usage_day_tokens")},
         ${dayValue("usage_day_trial_account_tokens")},
         ${dayValue("usage_day_meetings_started")},
         usage_day = CASE WHEN ${replacesDay} THEN excluded.usage_day ELSE usage_day END,
         updated_at = excluded.updated_at`,
    )
    .bind(identityHash, userId, now.getTime(), monthKey(now), monthStartMs(now), dayKey(now));
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
 * Yeni kullanıcının bugünkü sayaçlarını defterden başlatan ifade (`insertUserFromLedgerStatement`'tan sonra, aynı toplu
 * işlemde): defterdeki gün bugünse günlük token, denemedeki toplantı dışı token ve başlatılan toplantı sayısı
 * `daily_usage`'a yazılır (günlük sınırlar hesabı silip yeniden açınca sıfırlanmaz); başka günse bir şey yapmaz.
 */
export function seedDailyUsageFromLedgerStatement(db: D1Database, userId: string, identityHash: string, now: Date): D1PreparedStatement {
  return db
    .prepare(
      `INSERT INTO daily_usage (user_id, day, tokens_used, trial_account_tokens_used, meetings_started)
       SELECT ?1, usage_day, usage_day_tokens, usage_day_trial_account_tokens, usage_day_meetings_started
       FROM trial_identity_ledger WHERE identity_hash = ?2 AND usage_day = ?3`,
    )
    .bind(userId, identityHash, dayKey(now));
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
