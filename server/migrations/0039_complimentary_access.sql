-- Ücretsiz tam erişim (src/complimentary.ts): Stripe'tan faturalanmayan, yöneticinin verdiği abonelik satırı (sahibin
-- kendi hesabı, basın, arkadaşlar). Satır ödeyen abonenin satırıyla aynı biçimdedir: `status = 'active'`,
-- `plan = 'monthly'` (`/v1/me` uygulama 0.1.6'nın tanıdığı değerleri gönderir), haklar ve davet kodu aynıdır.
-- Stripe kimlikleri yapaydır ve açıkça işaretlidir (`comp_cus_<uuid>`, `comp_sub_<uuid>`): Stripe'a hiç gönderilmez,
-- hiçbir Stripe olayıyla eşleşmez (`customer.deleted`, `charge.refunded` satırı kimlikle bulur). `stripe_customers`
-- satırı yazılmaz. Süresiz erişimde dönem sonu verilişten 100 yıl sonradır ve `cancel_at` boştur; bitiş tarihli
-- erişimde dönem sonu ve `cancel_at` o tarihtir. Webhook süren ücretsiz erişimi ezmez; gelir, abone sayısı, dönüşüm ve
-- kayıp istatistikleri bu satırları saymaz (src/admin.ts). Davet edenin ücretsiz erişimi varsa ödülü Stripe'a gitmez:
-- davet satırı `void` olur (`void_reason = 'referrer_complimentary'`, src/referralRewards.ts).
ALTER TABLE subscriptions ADD COLUMN complimentary INTEGER NOT NULL DEFAULT 0 CHECK (complimentary IN (0, 1));
