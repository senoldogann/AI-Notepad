-- Raporların günlük bütçesi tür başına bayttır (src/reports.ts): her raporun saklanan metin alanlarının UTF-8 baytı.
ALTER TABLE reports ADD COLUMN size_bytes INTEGER NOT NULL DEFAULT 0;
UPDATE reports SET size_bytes =
  LENGTH(CAST(COALESCE(email, '') AS BLOB)) + LENGTH(CAST(COALESCE(app_version, '') AS BLOB))
  + LENGTH(CAST(COALESCE(os, '') AS BLOB)) + LENGTH(CAST(COALESCE(message, '') AS BLOB))
  + LENGTH(CAST(COALESCE(payload, '') AS BLOB)) + LENGTH(CAST(summary AS BLOB));
-- Tür başına günlük toplam ve hesap başına günlük sayı.
CREATE INDEX reports_kind_created ON reports(kind, created_at);
CREATE INDEX reports_user_created ON reports(user_id, created_at);
DROP INDEX reports_user;
