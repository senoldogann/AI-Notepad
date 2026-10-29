-- Reddedilen deneme başlatmalarının günlük sayacı (yönetim paneli; src/trialRefusals.ts): gün ve neden başına bir
-- satır, kullanıcı ya da IP tutmaz. Nedenler: `device_used` (Mac'te deneme başka hesapla kullanılmış), `exhausted`
-- (toplantılar harcanmış), `expired` (süre dolmuş), `ip_daily_limit` (aynı ağdan günlük yeni deneme sınırı). Kişisel
-- veri içermeyen toplam sayılardır (günde en çok 4 satır); temizlik sorgu bütçesini (src/cleanup.ts) büyütmemek için
-- silinmez.
CREATE TABLE trial_refusals (
  day TEXT NOT NULL,
  reason TEXT NOT NULL CHECK (reason IN ('device_used', 'exhausted', 'expired', 'ip_daily_limit')),
  count INTEGER NOT NULL,
  PRIMARY KEY (day, reason)
);
