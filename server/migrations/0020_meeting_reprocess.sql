-- Yeniden işleme (`POST /v1/meetings/{id}/reprocess`): ek süresi geçmiş toplantı, kendi kullanılmamış ses hakkı ve
-- yapay zekâ bütçesiyle sınırlı sayıda (`reprocess_count`) yeniden açılır; açıklık `reprocess_until`'e dek sürer. Yeni
-- deneme ya da toplantı başlatma sayılmaz.
ALTER TABLE meeting_sessions ADD COLUMN reprocess_count INTEGER NOT NULL DEFAULT 0;
ALTER TABLE meeting_sessions ADD COLUMN reprocess_until INTEGER;
