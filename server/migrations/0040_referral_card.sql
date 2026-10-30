-- Davet kötüye kullanım koruması (src/referrals.ts).
--
-- `card_fingerprint_hash`: davet edilenin ödeme kartının Stripe parmak izinin HMAC-SHA256 özeti (`referralCardHash`;
-- sunucu sırrı TRIAL_HASH_SECRET, parmak izi açık saklanmaz). Kodla açılan aboneliğin ilk faturası ödenince
-- (`invoice.paid`, `checkout` → `joined`) aboneliğin varsayılan ödeme yönteminden yazılır; ödeme yöntemi kart değilse
-- NULL kalır. Kart davet edenin kartlarından biriyse (Stripe'taki kartları ya da kendi davet satırının kartı) satır
-- `void`/`self_card`, başka bir davette kullanılmışsa `void`/`card_reused` olur: ödül verilmez, arkadaşın Stripe'ta
-- aldığı indirim geri alınmaz. Satır, kimlik özetiyle aynı sürelerle tutulur (bkz. 0038 ve src/cleanup.ts).
ALTER TABLE referral_redemptions ADD COLUMN card_fingerprint_hash TEXT;
CREATE INDEX referral_redemptions_card ON referral_redemptions(card_fingerprint_hash) WHERE card_fingerprint_hash IS NOT NULL;

-- Ücretsiz ayında aboneliği biten arkadaş artık `void`/`canceled_before_payment` olur (src/billing.ts); bu göçten önce
-- `joined` kalmış satırlar da aynı duruma getirilir (davet edenin "bekleyen" sayısı ve tahmini ödül tarihi düzelir).
UPDATE referral_redemptions
SET status = 'void', void_reason = 'canceled_before_payment', updated_at = CAST(strftime('%s', 'now') AS INTEGER) * 1000
WHERE status = 'joined'
  AND stripe_subscription_id IN (SELECT stripe_subscription_id FROM subscriptions WHERE status IN ('canceled', 'incomplete_expired'));
