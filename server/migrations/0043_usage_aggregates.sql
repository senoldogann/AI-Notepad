-- "Sorunlar" sayacına iki yeni tür (src/opsEvents.ts): `account_deleted` (ayrıntı: silinen hesabın kesimi —
-- `subscriber`, `trial`, `signup`) ve `retry` (ayrıntı: yeniden denenen üst servis; src/retry.ts). SQLite CHECK
-- kısıtını değiştiremediği için tablo yeniden kurulur; satırlar korunur.
CREATE TABLE ops_events_next (
  day TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('refusal', 'provider_error', 'server_error', 'account_deleted', 'retry')),
  detail TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, kind, detail)
);
INSERT INTO ops_events_next (day, kind, detail, count) SELECT day, kind, detail, count FROM ops_events;
DROP TABLE ops_events;
ALTER TABLE ops_events_next RENAME TO ops_events;

-- Yapay zekâ token'ları günlük, isteğin biçiminden çıkarılan kovaya göre (src/llm/usageBuckets.ts): kapsam (toplantı ya
-- da hesap) × effort × yapılandırılmış çıktı (şema var mı). İçerik ve kullanıcı tutmaz; 400 gün tutulur.
CREATE TABLE llm_usage_daily (
  day TEXT NOT NULL,
  bucket TEXT NOT NULL,
  calls INTEGER NOT NULL,
  -- Akışlı çağrılar (`stream: true`; `calls`'ın parçası).
  streamed_calls INTEGER NOT NULL,
  input_tokens INTEGER NOT NULL,
  output_tokens INTEGER NOT NULL,
  PRIMARY KEY (day, bucket)
);

-- Konuşma tanıma dilleri günlük (src/transcribe.ts): istenen dil (`language_code` parametresi; yoksa `auto`) ve
-- ElevenLabs'in algıladığı dil, istek sayısı ve ses süresi. İçerik ve kullanıcı tutmaz; 400 gün tutulur.
CREATE TABLE transcription_languages_daily (
  day TEXT NOT NULL,
  requested TEXT NOT NULL,
  detected TEXT NOT NULL,
  requests INTEGER NOT NULL,
  audio_seconds REAL NOT NULL,
  PRIMARY KEY (day, requested, detected)
);

-- İndirmelerin kampanyası (src/downloads.ts): `GET /v1/download/mac?utm_source=…&utm_campaign=…`. Kaynak izin
-- listesindedir (tanınmayan `other`), kampanya biçimi sınırlıdır (geçersizi `other`, yoksa boş). Ağ başına günde bir
-- indirme sayılır (`download_visitors`); IP ya da başka tanımlayıcı tutmaz; 400 gün tutulur.
CREATE TABLE download_campaigns (
  day TEXT NOT NULL,
  utm_source TEXT NOT NULL,
  utm_campaign TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, utm_source, utm_campaign)
);
