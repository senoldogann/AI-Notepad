-- Son geçiş yüklemesinin tekrar güvenliği (src/transcriptionCache.ts): tamamlanan yazıya dökmenin sonucu, istemcinin
-- yükleme anahtarının özetiyle ve o anahtardan türetilen anahtarla şifreli olarak kısa süre saklanır; yanıtı kaybolan
-- istek sesi yeniden işletmeden ve faturalanmadan aynı sonucu alır. Anahtar saklanmaz (sunucu metni okuyamaz).
CREATE TABLE transcription_results (
  key_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL,
  meeting_id TEXT NOT NULL,
  ciphertext BLOB NOT NULL,
  iv BLOB NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL
);
CREATE INDEX transcription_results_expires ON transcription_results(expires_at);
CREATE INDEX transcription_results_user ON transcription_results(user_id);
