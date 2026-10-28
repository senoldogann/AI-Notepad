-- Aboneliği olmayan (deneme) kullanıcının toplantıya bağlı olmayan yapay zekâ çağrıları ayrıca sayılır: günlük küçük
-- sınır `TRIAL_ACCOUNT_DAILY_TOKENS`. Kesinleşmiş ve ayrılmış token ayrı tutulur (bkz. src/reservations.ts).
ALTER TABLE daily_usage ADD COLUMN trial_account_tokens_used INTEGER NOT NULL DEFAULT 0;
ALTER TABLE daily_usage ADD COLUMN trial_account_tokens_reserved INTEGER NOT NULL DEFAULT 0;
