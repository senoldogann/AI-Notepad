-- E-posta bağlantısıyla giriş kaldırıldı; Google ile giriş eklendi.
-- Üretimde e-posta göndericisi hep "dev" idi (bağlantı hiç gönderilmedi): 'email' kimliği yoktur. Varsa aşağıdaki
-- kopyalama CHECK kısıtına takılır ve göç açıkça başarısız olur (sessizce satır kaybolmaz).
DROP TABLE email_login_tokens;

-- SQLite CHECK kısıtını değiştiremez: tablo yeni kısıtla yeniden oluşturulur. Hesaplar arasında otomatik bağlama yoktur:
-- Apple ve Google kimliği ayrı kullanıcılardır.
CREATE TABLE auth_identities_new (
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'google')),
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id),
  email TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (provider, subject)
);
INSERT INTO auth_identities_new (provider, subject, user_id, email, created_at)
  SELECT provider, subject, user_id, email, created_at FROM auth_identities;
DROP TABLE auth_identities;
ALTER TABLE auth_identities_new RENAME TO auth_identities;
CREATE INDEX auth_identities_user ON auth_identities(user_id);
