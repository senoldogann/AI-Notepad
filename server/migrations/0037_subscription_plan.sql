-- Aboneliğin planı (src/billing.ts `planOfSubscription`): webhook, geçerli aboneliğin fiyatından yazar — aylık
-- (`STRIPE_PRICE_ID`) ya da yıllık (`STRIPE_YEARLY_PRICE_ID`). Fiyatı ikisi de olmayan (yalnızca `metadata.user_id`
-- taşıyan) abonelikte NULL. `/v1/me` ve yönetim paneli planı gösterir; MRR plan başına hesaplanır. Haklar plana bakmaz.
ALTER TABLE subscriptions ADD COLUMN plan TEXT CHECK (plan IN ('monthly', 'yearly'));
-- Bu göçten önce yalnızca aylık fiyat satılıyordu.
UPDATE subscriptions SET plan = 'monthly';
