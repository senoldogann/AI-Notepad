-- AI-Notepad abonelik sürümü: ilk şema.
-- Zamanlar Unix milisaniyesidir (INTEGER). Jetonlar yalnızca SHA-256 karması olarak saklanır.

CREATE TABLE users (
  id TEXT PRIMARY KEY,
  created_at INTEGER NOT NULL
);

-- Giriş kimlikleri: Apple `sub` ya da küçük harfe çevrilmiş e-posta.
CREATE TABLE auth_identities (
  provider TEXT NOT NULL CHECK (provider IN ('apple', 'email')),
  subject TEXT NOT NULL,
  user_id TEXT NOT NULL REFERENCES users(id),
  email TEXT,
  created_at INTEGER NOT NULL,
  PRIMARY KEY (provider, subject)
);
CREATE INDEX auth_identities_user ON auth_identities(user_id);

-- Yenileme jetonu aileleri: her girişte bir aile; yeniden kullanım tüm aileyi düşürür.
CREATE TABLE refresh_families (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  revoked_at INTEGER,
  revoke_reason TEXT
);
CREATE INDEX refresh_families_user ON refresh_families(user_id);

CREATE TABLE refresh_tokens (
  token_hash TEXT PRIMARY KEY,
  family_id TEXT NOT NULL REFERENCES refresh_families(id),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);
CREATE INDEX refresh_tokens_family ON refresh_tokens(family_id);

-- E-posta giriş bağlantıları: tek kullanımlık, 15 dakika.
CREATE TABLE email_login_tokens (
  token_hash TEXT PRIMARY KEY,
  email TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);

-- Apple ile giriş nonce'ları: aynı kimlik jetonu ikinci kez kullanılamaz.
CREATE TABLE used_nonces (
  nonce_hash TEXT PRIMARY KEY,
  expires_at INTEGER NOT NULL
);

-- App Attest tek kullanımlık meydan okumaları.
CREATE TABLE device_challenges (
  challenge_hash TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  purpose TEXT NOT NULL CHECK (purpose IN ('attest', 'assert')),
  created_at INTEGER NOT NULL,
  expires_at INTEGER NOT NULL,
  used_at INTEGER
);

-- App Attest ile doğrulanmış cihaz anahtarları; kimlik App Attest anahtar kimliğidir (base64).
CREATE TABLE devices (
  id TEXT PRIMARY KEY,
  public_key_spki TEXT NOT NULL,
  sign_count INTEGER NOT NULL,
  environment TEXT NOT NULL CHECK (environment IN ('development', 'production')),
  validation_category INTEGER NOT NULL,
  bundle_version TEXT NOT NULL,
  receipt TEXT NOT NULL,
  attested_by_user_id TEXT NOT NULL REFERENCES users(id),
  created_at INTEGER NOT NULL,
  last_used_at INTEGER NOT NULL
);

-- Toplantı oturumları: her vekil çağrısı açık (ya da yeni kapanmış) bir oturuma bağlıdır.
CREATE TABLE meeting_sessions (
  id TEXT PRIMARY KEY,
  user_id TEXT NOT NULL REFERENCES users(id),
  device_id TEXT REFERENCES devices(id),
  kind TEXT NOT NULL CHECK (kind IN ('trial', 'subscription')),
  started_at INTEGER NOT NULL,
  max_ends_at INTEGER NOT NULL,
  ended_at INTEGER,
  minutes INTEGER,
  token_budget INTEGER NOT NULL,
  tokens_used INTEGER NOT NULL DEFAULT 0,
  audio_seconds REAL NOT NULL DEFAULT 0
);
CREATE INDEX meeting_sessions_user ON meeting_sessions(user_id, started_at);
CREATE INDEX meeting_sessions_user_kind ON meeting_sessions(user_id, kind);
CREATE INDEX meeting_sessions_device_kind ON meeting_sessions(device_id, kind);

-- Aylık kullanım (ay: "YYYY-MM", UTC). Toplantı süresi meeting_sessions'tan hesaplanır.
CREATE TABLE monthly_usage (
  user_id TEXT NOT NULL REFERENCES users(id),
  month TEXT NOT NULL,
  audio_seconds REAL NOT NULL DEFAULT 0,
  input_tokens INTEGER NOT NULL DEFAULT 0,
  output_tokens INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (user_id, month)
);

-- Stripe müşteri eşlemesi: Checkout'ta oluşturulur, sonraki ödemelerde yeniden kullanılır.
CREATE TABLE stripe_customers (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  stripe_customer_id TEXT NOT NULL UNIQUE,
  created_at INTEGER NOT NULL
);

-- Abonelik durumu: yalnızca Stripe webhook'u yazar.
CREATE TABLE subscriptions (
  user_id TEXT PRIMARY KEY REFERENCES users(id),
  stripe_customer_id TEXT NOT NULL UNIQUE,
  stripe_subscription_id TEXT NOT NULL UNIQUE,
  status TEXT NOT NULL,
  current_period_end INTEGER NOT NULL,
  last_event_created INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

-- İşlenmiş Stripe olayları: aynı olay ikinci kez işlenmez.
CREATE TABLE stripe_events (
  id TEXT PRIMARY KEY,
  type TEXT NOT NULL,
  processed_at INTEGER NOT NULL
);

-- Günlük tahmini harcama (mikro dolar, gün: "YYYY-MM-DD", UTC).
CREATE TABLE daily_spend (
  day TEXT PRIMARY KEY,
  micro_usd INTEGER NOT NULL DEFAULT 0
);
