-- Kimlik deneme defteri günün kullanımını da tutar (src/trialLedger.ts): aynı gün silinip yeniden açılan hesap günlük
-- token, denemedeki toplantı dışı token ve günlük toplantı başlatma sayaçlarını devralır (hesabı silmek günlük sınırları
-- sıfırlamaz).
ALTER TABLE trial_identity_ledger ADD COLUMN usage_day TEXT;
ALTER TABLE trial_identity_ledger ADD COLUMN usage_day_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE trial_identity_ledger ADD COLUMN usage_day_trial_account_tokens INTEGER NOT NULL DEFAULT 0;
ALTER TABLE trial_identity_ledger ADD COLUMN usage_day_meetings_started INTEGER NOT NULL DEFAULT 0;
