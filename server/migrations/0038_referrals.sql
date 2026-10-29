-- Davet programı ("bir ay ver, bir ay al"; src/referrals.ts).
--
-- Davet kodu: abonelik erişimi olan hesaba ilk istekte üretilir (8 karakter, rastgele; sıralı değil). Hesap silinince
-- silinir.
CREATE TABLE referral_codes (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  code TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

-- Davetle abonelik: davet edilen hesap başına bir satır (`referred_user_id` ve kimlik özeti tekildir: yeni ödeyen hesap
-- başına bir ödül). Durumlar:
-- - `checkout`: kod Checkout oturumuna uygulandı (ödeme yok); kodsuz yeni Checkout satırı siler;
-- - `joined`: kodla açılan aboneliğin ilk faturası ödendi (aylıkta 0 $; `joined_at`);
-- - `qualified`: ilk gerçek (sıfırdan büyük) ödeme alındı; `reward_due_at`'e dek iade ya da itiraz gelmezse ödül verilir;
-- - `granted`: davet edene Stripe müşteri bakiyesi alacağı yazıldı (`stripe_balance_transaction_id`);
-- - `capped`: davet eden son 365 günde 12 ödüle ulaşmıştı; `void`: iade, itiraz, kendi kendini davet ya da davet eden
--   silindi (`void_reason`).
-- Davet edilen hesap silinince `referred_user_id` NULL olur, kimlik özeti (`referred_identity_hash`: giriş kimliğinin
-- HMAC özeti, bkz. src/trialLedger.ts) ve zamanlar kalır: aynı kimlikle yeniden açılan hesap ikinci kez davet indirimi
-- alamaz. Böyle satırlar son güncellemeden 730 gün sonra silinir (src/cleanup.ts). Abonelik açılmamış (`joined_at`
-- NULL) satırlar hesapla birlikte silinir. Davet eden silinince `referrer_user_id` NULL olur ve bekleyen ödül `void`
-- olur.
CREATE TABLE referral_redemptions (
  id TEXT PRIMARY KEY,
  referred_user_id TEXT UNIQUE,
  referred_identity_hash TEXT NOT NULL UNIQUE,
  referrer_user_id TEXT,
  code TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('checkout', 'joined', 'qualified', 'granted', 'capped', 'void')),
  void_reason TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  stripe_subscription_id TEXT UNIQUE,
  joined_at INTEGER,
  qualifying_invoice_id TEXT,
  qualified_at INTEGER,
  reward_due_at INTEGER,
  rewarded_at INTEGER,
  stripe_balance_transaction_id TEXT
);
CREATE INDEX referral_redemptions_referrer ON referral_redemptions(referrer_user_id, status);
CREATE INDEX referral_redemptions_due ON referral_redemptions(status, reward_due_at);
CREATE INDEX referral_redemptions_updated ON referral_redemptions(updated_at);
