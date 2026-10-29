-- Önceden ayırma satırları (src/reservations.ts): üst servise giden her çağrı (LLM ya da ses) için tek satır. Sınırlar
-- kesinleşmiş kullanım + süresi dolmamış satırların toplamıdır; kesinleştirme satırı siler. İstemci koparsa ya da Worker
-- kesinleştiremeden durursa satırın süresi dolar: sınır hesapları onu yok sayar, günlük temizlik tahmini maliyetini
-- günlük harcamaya ekleyip siler (src/cleanup.ts). Toplantıda süren ses satırı varken yeni ses isteği reddedilir.
CREATE TABLE usage_reservations (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  meeting_id TEXT,
  kind TEXT NOT NULL CHECK (kind IN ('llm', 'audio')),
  month TEXT NOT NULL,
  day TEXT NOT NULL,
  tokens INTEGER NOT NULL,
  trial_account_tokens INTEGER NOT NULL,
  account_tokens INTEGER NOT NULL,
  audio_seconds REAL NOT NULL,
  estimated_micro_usd INTEGER NOT NULL,
  trial_spend INTEGER NOT NULL CHECK (trial_spend IN (0, 1)),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX usage_reservations_user_month ON usage_reservations(user_id, month);
CREATE INDEX usage_reservations_user_day ON usage_reservations(user_id, day);
CREATE INDEX usage_reservations_meeting ON usage_reservations(meeting_id, kind);
CREATE INDEX usage_reservations_expires ON usage_reservations(expires_at);

-- Abonenin toplantıya bağlı olmayan çağrılarının bu ayki kesinleşmiş tokenı (`MONTHLY_ACCOUNT_TOKEN_CAP`).
ALTER TABLE monthly_usage ADD COLUMN account_tokens INTEGER NOT NULL DEFAULT 0;

-- Eski sayaç sütunları (`monthly_usage.tokens_reserved`, `monthly_usage.audio_reserved`, `daily_usage.tokens_reserved`,
-- `daily_usage.trial_account_tokens_reserved`, `meeting_sessions.audio_reserved`) artık okunmaz ve yazılmaz; dağıtım
-- sırasında eski sürümün süren istekleri onları kesinleştirebilsin diye bu göçte silinmez.
