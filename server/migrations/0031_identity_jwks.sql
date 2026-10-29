-- Kimlik sağlayıcılarının (Apple, Google) açık anahtarları (JWKS) kalıcı önbellekte (src/auth/identityToken.ts
-- `persistedIssuerKeys`): Worker örnekleri kısa ömürlü olduğu için bellekteki önbellek çoğu girişte boştu ve her giriş
-- sağlayıcıya gidiyordu; sağlayıcı yavaşsa giriş zaman aşımına düşüyordu. Günlük bakım anahtarları önceden tazeler.
CREATE TABLE identity_jwks (
  jwks_url TEXT PRIMARY KEY,
  keys_json TEXT NOT NULL,
  fetched_at INTEGER NOT NULL
);
