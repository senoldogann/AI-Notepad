-- Toplantının sonucu (yönetim paneli: huni ve "ne ters gitti"):
-- - `first_note_at`: toplantıda ilk not çağrısının (toplantı kapsamlı, `effort: medium` yapay zekâ çağrısı) başarıyla
--   bittiği an (src/llm/proxy.ts); bu göçten önceki toplantılarda boştur.
-- - `failure_count`, `last_failure_code`, `last_failure_at`: toplantıya bağlı isteklerden (yapay zekâ, yazıya dökme,
--   Deepgram jetonu, bitirme, yeniden işleme) başarısız olanların sayısı, son hata kodu (ör.
--   `upstream_rejected:elevenlabs`, `meeting_budget_exhausted`) ve anı (src/opsEvents.ts). İçerik tutulmaz.
ALTER TABLE meeting_sessions ADD COLUMN first_note_at INTEGER;
ALTER TABLE meeting_sessions ADD COLUMN failure_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE meeting_sessions ADD COLUMN last_failure_code TEXT;
ALTER TABLE meeting_sessions ADD COLUMN last_failure_at INTEGER;
