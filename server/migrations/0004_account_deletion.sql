-- Hesap silme: silinen hesapların deneme başlangıçları IP başına günlük sayaçta hesap bağı olmadan kalır
-- (hesabı silip yeniden açarak IP başına günlük deneme sınırı aşılamaz). IP açık saklanmaz: HMAC özetidir.
CREATE TABLE deleted_trial_starts (
  ip_hash TEXT NOT NULL,
  day TEXT NOT NULL,
  accounts INTEGER NOT NULL,
  PRIMARY KEY (ip_hash, day)
);
