-- Veri azaltma: giriş kimliğinin e-postası saklanmaz (sunucu kullanmaz); var olan Apple e-postaları silinir. Sütun
-- yeni satırlarda NULL yazılır (src/auth/users.ts).
UPDATE auth_identities SET email = NULL WHERE email IS NOT NULL;
-- E-posta giriş bağlantıları 0007'de kaldırıldı; tablo hiçbir ortamda kalmasın.
DROP TABLE IF EXISTS email_login_tokens;
-- Saklama temizliği (src/cleanup.ts): kullanılmayan cihazlar son kullanımdan 13 ay sonra silinir.
CREATE INDEX IF NOT EXISTS devices_last_used ON devices(last_used_at);
