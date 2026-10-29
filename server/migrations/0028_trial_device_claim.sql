-- Denemenin Mac'e bağlanması yarıda kalırsa hesap kilitlenmesin (src/meetings.ts `requireTrialDevice`): Apple
-- DeviceCheck'te Mac işaretlenmeden (`bit0`) önce hesabın bekleyen talebi yazılır. İşaretleme ile
-- `trial_device_verified_at` arasında istek düşerse, aynı hesap yeniden denediğinde `bit0` dolu ama bekleyen talep
-- olduğu için doğrulama tamamlanır (`trial_device_used` verilmez). Doğrulanınca ya da Apple yazmadığı kesinse silinir.
ALTER TABLE users ADD COLUMN trial_device_claim_started_at INTEGER;
