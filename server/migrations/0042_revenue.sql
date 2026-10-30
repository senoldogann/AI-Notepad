-- Gerçek gelir (src/revenue.ts): Stripe `invoice.paid` ve `charge.refunded` webhook'larından fatura tutarları. Muhasebe
-- kaydı olarak 10 yıl tutulur (src/cleanup.ts; Finlandiya muhasebe yasası). Kart ya da ödeme bilgisi yoktur.

-- Hesabın ilk ücretli (tutarı 0'dan büyük) faturasının ödendiği an (ms): yeniden abone olunca da korunur. Abonelik
-- satırı faturadan sonra gelirse webhook onu `revenue_invoices`'tan doldurur. Bu göçten önceki abonelerde NULL.
ALTER TABLE subscriptions ADD COLUMN first_paid_at INTEGER;

-- Ödenmiş abonelik faturaları (bizim müşterimizin abonelik faturası; tutarı 0 olan davet ayı da yazılır). Tutarlar
-- faturanın para biriminin en küçük biriminde (sent). `user_id` hesap silinince NULL olur (satır muhasebe için kalır,
-- hesaba bağlanmaz).
CREATE TABLE revenue_invoices (
  invoice_id TEXT PRIMARY KEY,
  user_id TEXT REFERENCES users(id),
  subscription_id TEXT NOT NULL,
  -- Ödeme günü (UTC) ve anı (ms; `status_transitions.paid_at`, yoksa olay anı).
  day TEXT NOT NULL,
  paid_at INTEGER NOT NULL,
  currency TEXT NOT NULL,
  -- Tahsil edilen (`amount_paid`; vergi dahil, müşteri bakiyesi düşülmüş), vergisiz toplam (`total_excluding_tax`),
  -- indirim (`total_discount_amounts`) ve vergi (`total_taxes`).
  amount_paid INTEGER NOT NULL,
  total_excluding_tax INTEGER NOT NULL,
  discount INTEGER NOT NULL,
  tax INTEGER NOT NULL,
  -- `subscription_create`, `subscription_cycle`, `subscription_update`, …
  billing_reason TEXT
);
CREATE INDEX revenue_invoices_day ON revenue_invoices(day);
CREATE INDEX revenue_invoices_subscription ON revenue_invoices(subscription_id, paid_at);
CREATE INDEX revenue_invoices_user ON revenue_invoices(user_id);

-- Bu faturaların iadeleri: ödeme (charge) başına bir satır; `amount_refunded` Stripe'ın birikimli iade tutarıdır (kısmi
-- iadelerde büyür). Gün ve an son iadenindir.
CREATE TABLE revenue_refunds (
  charge_id TEXT PRIMARY KEY,
  invoice_id TEXT NOT NULL REFERENCES revenue_invoices(invoice_id),
  day TEXT NOT NULL,
  refunded_at INTEGER NOT NULL,
  currency TEXT NOT NULL,
  amount_refunded INTEGER NOT NULL
);
CREATE INDEX revenue_refunds_day ON revenue_refunds(day);

-- Günlük anlık görüntünün gelir kısmı (src/dailyMetrics.ts): gün sonunda yenilenecek ödenmiş aboneliklerin son ücretli
-- faturasından MRR (vergisiz, yıllık /12) para birimine göre. Toplamlar; 5 yıl tutulur.
CREATE TABLE daily_revenue_metrics (
  day TEXT NOT NULL,
  currency TEXT NOT NULL,
  mrr_cents INTEGER NOT NULL,
  paying_subscriptions INTEGER NOT NULL,
  PRIMARY KEY (day, currency)
);
