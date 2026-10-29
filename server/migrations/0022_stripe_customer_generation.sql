-- Stripe müşterisi silindikten (`customer.deleted`) sonra yeni müşteri açılabilsin: müşteri oluşturmanın idempotency
-- anahtarı kuşağı içerir (`customer-<kullanıcı>-g<kuşak>`); silme olayı kuşağı artırır. Aksi halde Stripe aynı anahtarla
-- 24 saat boyunca silinmiş müşteriyi döndürür ve Checkout açılamaz.
ALTER TABLE users ADD COLUMN stripe_customer_generation INTEGER NOT NULL DEFAULT 0;
