-- Ücretsiz denemenin kötüye kullanımına karşı (bkz. src/trialLedger.ts, src/deviceCheck.ts).
--
-- Kimlik deneme defteri: hesap silinince kimlik başına harcanan deneme toplantısı sayısı ve cihaz doğrulaması burada
-- kalır; aynı Apple ya da Google kimliğiyle yeniden açılan hesap yeni deneme almaz, kalan denemeyle sürer. Kimlik açık
-- saklanmaz: `trial-identity:<sağlayıcı>:<sub>` metninin HMAC-SHA256 (sunucu sırrıyla) özetidir. Son güncellemeden
-- 730 gün sonra silinir (src/cleanup.ts).
CREATE TABLE trial_identity_ledger (
  identity_hash TEXT PRIMARY KEY,
  trial_meetings_used INTEGER NOT NULL,
  device_verified INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);
CREATE INDEX trial_identity_ledger_updated ON trial_identity_ledger(updated_at);

-- Yeniden açılan hesabın defterden devraldığı deneme sayısı; hesabın harcadığı deneme = bu + deneme toplantıları.
ALTER TABLE users ADD COLUMN carried_trial_meetings INTEGER NOT NULL DEFAULT 0;
-- Hesabın denemesi bir Mac'e (Apple DeviceCheck bit0) bağlandığı an (ms); NULL ise deneme için DeviceCheck gerekir.
ALTER TABLE users ADD COLUMN trial_device_verified_at INTEGER;

-- Deneme harcaması (deneme toplantıları ve denemedeki toplantı dışı çağrılar; `micro_usd` toplamının parçası): ayrı
-- günlük tavan `DAILY_TRIAL_SPEND_CEILING_USD` (bkz. src/usage.ts `requireTrialSpendHeadroom`).
ALTER TABLE daily_spend ADD COLUMN trial_micro_usd INTEGER NOT NULL DEFAULT 0;
