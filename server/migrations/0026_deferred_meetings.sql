-- Sonradan işlenen kayıt (bekleyen ya da içe aktarılan; src/meetings.ts `deferred`): oturum bitmiş olarak açılır
-- (canlı kullanılamaz, açık toplantıyı kapatmaz) ve aynı anda işlenen bekleyenler sınırlıdır.
ALTER TABLE meeting_sessions ADD COLUMN deferred INTEGER NOT NULL DEFAULT 0;
