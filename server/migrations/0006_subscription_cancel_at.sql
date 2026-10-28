-- İptal edilmiş ama dönemi süren abonelik: erişimin biteceği an (ms). NULL ise abonelik dönem sonunda yenilenir.
-- Stripe'ta `cancel_at` (Portal'daki iptal) ya da `cancel_at_period_end` (dönem sonu); bkz. src/billing.ts.
ALTER TABLE subscriptions ADD COLUMN cancel_at INTEGER;
