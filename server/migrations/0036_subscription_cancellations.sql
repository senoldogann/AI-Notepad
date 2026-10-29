-- Abonelik iptallerinin nedeni (yönetim paneli; src/cancellations.ts): Stripe'ın `customer.subscription.updated` ve
-- `.deleted` olaylarındaki `cancellation_details` — `reason` (Stripe'ın nedeni: `cancellation_requested`,
-- `payment_failed`, `payment_disputed`), `feedback` (Müşteri Portalı'ndaki sabit seçenek: `too_expensive`,
-- `missing_features`, …) ve `comment` (müşterinin serbest metni, en çok 1000 karakter). Abonelik başına bir satır;
-- yalnızca hesap kimliğine (UUID) bağlıdır, e-posta ya da ad tutmaz. Abonelik yeniden etkinleşirse satır silinir; hesap
-- silinince silinir (src/account.ts); 180 gün tutulur (src/cleanup.ts). `event_created`: satırı son yazan Stripe
-- olayının anı (ters sırada gelen eski olay yeniyi ezmez).
CREATE TABLE subscription_cancellations (
  stripe_subscription_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  event_created INTEGER NOT NULL,
  reason TEXT,
  feedback TEXT,
  comment TEXT
);
CREATE INDEX subscription_cancellations_created ON subscription_cancellations(created_at);
CREATE INDEX subscription_cancellations_user ON subscription_cancellations(user_id);
