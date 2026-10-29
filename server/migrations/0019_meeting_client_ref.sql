-- İstemcinin kayıt kimliği (`clientRef`): aynı kayıt için yinelenen `/v1/meetings/start` (yanıt kaybolduysa ya da
-- çevrimdışı kaydedilmiş toplantı bağlantı gelince açılırken) yeni oturum açmaz, aynı oturumu döndürür; deneme hakkı ve
-- süre iki kez düşmez. Eski oturumlarda NULL.
ALTER TABLE meeting_sessions ADD COLUMN client_ref TEXT;
CREATE UNIQUE INDEX meeting_sessions_user_client_ref ON meeting_sessions (user_id, client_ref) WHERE client_ref IS NOT NULL;
