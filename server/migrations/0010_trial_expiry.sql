-- Ücretsiz deneme: `TRIAL_MEETINGS` toplantı ya da `TRIAL_DAYS` gün, hangisi önce dolarsa. Süre hesabın ilk deneme
-- toplantısıyla başlar (kayıtla değil); kullanılmayan toplantılar süre dolunca düşer (bkz. src/entitlements.ts).
--
-- Hesabın ilk deneme toplantısının başladığı an (ms); deneme başlamadıysa NULL. İlk deneme toplantısı eklenirken aynı
-- işlemde yazılır (src/meetings.ts).
ALTER TABLE users ADD COLUMN trial_started_at INTEGER;
-- Var olan hesaplar: ilk deneme toplantısının başlangıcı.
UPDATE users SET trial_started_at = (
  SELECT MIN(started_at) FROM meeting_sessions WHERE meeting_sessions.user_id = users.id AND meeting_sessions.kind = 'trial'
) WHERE trial_started_at IS NULL;

-- Kimlik deneme defteri denemenin başlangıcını da taşır: silip aynı kimlikle yeniden açmak süreyi sıfırlamaz.
ALTER TABLE trial_identity_ledger ADD COLUMN trial_started_at INTEGER;
-- Var olan defter satırları (bu göçten önce silinmiş hesaplar): toplantıları silindiği için gerçek başlangıç
-- bilinmez; silinme anı (`updated_at`) üst sınırdır, süre en geç oradan başlar.
UPDATE trial_identity_ledger SET trial_started_at = updated_at WHERE trial_started_at IS NULL AND trial_meetings_used > 0;
