-- Denemeye başlayan hesaplar: IP başına günlük yeni hesap sınırı için.
-- IP açık saklanmaz: HMAC-SHA256 (sunucu sırrıyla) özeti tutulur.
CREATE TABLE trial_starts (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  ip_hash TEXT NOT NULL,
  day TEXT NOT NULL,
  created_at INTEGER NOT NULL
);
CREATE INDEX trial_starts_ip_day ON trial_starts(ip_hash, day);
