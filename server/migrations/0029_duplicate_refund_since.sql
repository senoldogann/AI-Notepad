-- Kopya aboneliğin iadesi yalnızca çakışan döneme (src/billing.ts `duplicateInvoicesToRefund`): korunan abonelik
-- oluşturulduktan (Stripe saniyesi) sonra kesilen faturalar iade edilir; kopya daha eski abonelikse onun önceki meşru
-- ayları iade edilmez. Geç ödenen fatura (`invoice.paid`) da bu sınıra bakar. NULL: bu sütundan önce yazılmış kayıt
-- (tüm faturalar, eski davranış).
ALTER TABLE duplicate_subscriptions ADD COLUMN refund_since INTEGER;
