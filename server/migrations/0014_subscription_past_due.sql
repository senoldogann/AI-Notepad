-- `past_due` ek süresi dönem sonundan değil, aboneliğin `past_due`'ya geçtiği andan hesaplanır (Stripe yenilemede
-- dönem sonunu hemen ilerletir). Webhook durum `past_due` olunca yazar, sürdükçe korur, çıkınca siler (src/billing.ts).
ALTER TABLE subscriptions ADD COLUMN past_due_since INTEGER;
-- Var olan `past_due` satırları: geçiş anı bilinmez; son webhook yazımı (`updated_at`) kullanılır.
UPDATE subscriptions SET past_due_since = updated_at WHERE status = 'past_due';
