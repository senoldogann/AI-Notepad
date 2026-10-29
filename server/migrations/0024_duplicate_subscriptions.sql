-- Kopya (fazla) abonelikler (src/billing.ts): iade ve iptalden önce kalıcı olarak yazılır. Kopyanın ödenmiş faturaları
-- iade edilir; iptalden sonra geç ödenen faturası (`invoice.paid`) da bu kayda bakılarak iade edilir. Tam iadesi
-- (`charge.refunded`) geçerli aboneliği bitirmez. Hesap silinse de kalır (iade yine yapılmalı); 400 gün sonra silinir.
CREATE TABLE duplicate_subscriptions (
  stripe_subscription_id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  stripe_customer_id TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX duplicate_subscriptions_created ON duplicate_subscriptions(created_at);
