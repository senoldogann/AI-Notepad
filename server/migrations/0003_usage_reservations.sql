-- Kötüye kullanım sınırları: ses ve token için önceden ayırma, günlük kullanım, toplantı bitiş nedeni.

-- Toplantı: üst servise giden sesin ayrılmış süresi; gerçek süre ayrılanı aşarsa toplantının ses hakkı kapanır.
ALTER TABLE meeting_sessions ADD COLUMN audio_reserved REAL NOT NULL DEFAULT 0;
ALTER TABLE meeting_sessions ADD COLUMN transcription_closed INTEGER NOT NULL DEFAULT 0;
-- 'ended': kullanıcı bitirdi (not için ek süre var); 'superseded': yeni toplantı başlayınca kapandı (ek süre yok).
ALTER TABLE meeting_sessions ADD COLUMN end_reason TEXT CHECK (end_reason IN ('ended', 'superseded'));

-- Aylık sınırlar için ayrılmış (henüz kesinleşmemiş) miktarlar.
ALTER TABLE monthly_usage ADD COLUMN audio_reserved REAL NOT NULL DEFAULT 0;
ALTER TABLE monthly_usage ADD COLUMN tokens_reserved INTEGER NOT NULL DEFAULT 0;

-- Günlük kullanım (gün: "YYYY-MM-DD", UTC): token sınırı ve toplantı başlatma sayısı.
CREATE TABLE daily_usage (
  user_id TEXT NOT NULL REFERENCES users(id),
  day TEXT NOT NULL,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  tokens_reserved INTEGER NOT NULL DEFAULT 0,
  meetings_started INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, day)
);
