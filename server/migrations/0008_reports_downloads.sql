-- Geri bildirim, çökme raporu ve iletişim formu. `summary` eklemede hesaplanır (mesajın ilk 200 karakteri ya da çökme
-- imzası): yönetici listesi büyük `payload`'ı okumaz. 180 gün tutulur (src/cleanup.ts); hesap silinince hesabın
-- raporları da silinir (src/account.ts).
CREATE TABLE reports (
  id TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK (kind IN ('feedback', 'crash', 'contact')),
  status TEXT NOT NULL CHECK (status IN ('open', 'done')),
  created_at INTEGER NOT NULL,
  user_id TEXT REFERENCES users(id),
  email TEXT,
  app_version TEXT,
  os TEXT,
  message TEXT,
  payload TEXT,
  summary TEXT NOT NULL
);
CREATE INDEX reports_created ON reports(created_at);
CREATE INDEX reports_user ON reports(user_id);
CREATE INDEX reports_status_kind ON reports(status, kind);

-- Mac indirme sayacı: UTC gün başına tek satır. IP, tarayıcı ya da başka bir tanımlayıcı saklanmaz.
CREATE TABLE downloads (
  day TEXT PRIMARY KEY,
  count INTEGER NOT NULL
);

-- Yönetici istatistikleri için tarih aralığı sorguları.
CREATE INDEX users_created ON users(created_at);
CREATE INDEX meeting_sessions_started ON meeting_sessions(started_at);
CREATE INDEX monthly_usage_month ON monthly_usage(month);
