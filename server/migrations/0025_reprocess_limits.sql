-- Yeniden işlemenin ses sınırı (src/meetings.ts `reprocessMeeting`): yeniden açılan toplantı en çok kaydın gerçek
-- süresi (+ parça örtüşme payı) kadar yeni ses yazabilir; toplantının kalan en uzun süresi kadar değil. NULL: sınır yok
-- (toplantı hiç yeniden işlenmedi ya da sesi hiç yazılmadı).
ALTER TABLE meeting_sessions ADD COLUMN reprocess_audio_cap REAL;
