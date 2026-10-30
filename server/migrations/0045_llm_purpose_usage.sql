-- Yapay zekâ tokenlarının amaca göre günlük toplamı (yönetim paneli "Telemetri"; src/llm/purpose.ts): uygulama her
-- `POST /v1/llm/messages` isteğine `x-llm-purpose` başlığını koyar (ör. `live_translation`, `note`, `ask_answer`);
-- başlığı göndermeyen eski uygulamaların (0.1.9 ve öncesi) çağrıları `unattributed` satırına yazılır. Kesinleşen her
-- çağrının girdi ve çıktı tokenı ile çağrı sayısı gün ve amaç başına toplanır. Kullanıcı, toplantı ya da içerik
-- tutmaz; 400 gün tutulur (src/cleanup.ts).
CREATE TABLE llm_purpose_usage (
  day TEXT NOT NULL,
  purpose TEXT NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  calls INTEGER NOT NULL,
  PRIMARY KEY (day, purpose)
);
