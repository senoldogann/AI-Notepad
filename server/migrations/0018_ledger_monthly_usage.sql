-- Kimlik defteri bu ayın kullanımını da taşır (src/trialLedger.ts): hesap silinip aynı kimlikle yeniden açılınca aylık
-- süre sınırı (`MONTHLY_CAP_HOURS`) ve aylık token sınırları sıfırlanmasın. Hesap silinirken o ayın (UTC, "YYYY-MM")
-- kullanılan süresi, token'ı ve toplantı dışı token'ı yazılır (aynı ay için büyüğü kalır, daha yeni ay eskisinin yerine
-- geçer); yeni hesap açılırken defterdeki ay bu aysa `monthly_usage`'a devralınır, başka aysa yok sayılır. Kullanımı
-- olmayan ay yazılmaz (`usage_month` NULL).
ALTER TABLE trial_identity_ledger ADD COLUMN usage_month TEXT;
ALTER TABLE trial_identity_ledger ADD COLUMN usage_seconds REAL NOT NULL DEFAULT 0;
ALTER TABLE trial_identity_ledger ADD COLUMN usage_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE trial_identity_ledger ADD COLUMN usage_account_tokens INTEGER NOT NULL DEFAULT 0;

-- Silinmiş hesaptan devralınan bu ayki süre (saniye): aylık süre sınırına toplantı ve ses süresinin üstüne eklenir.
ALTER TABLE monthly_usage ADD COLUMN carried_seconds REAL NOT NULL DEFAULT 0;
