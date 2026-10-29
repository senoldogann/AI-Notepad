-- Alarm düzeyindeki olayların günlük sayacı (yönetim paneli "Sorunlar"; src/opsEvents.ts): gün, tür ve ayrıntı başına
-- bir satır. Türler: `refusal` (ayrıntı: hata kodu; ör. `trial_capacity_reached`, `spend_ceiling_reached`,
-- `monthly_cap_reached`), `provider_error` (ayrıntı: servis; `anthropic`, `elevenlabs`, `deepgram`, `devicecheck`, …),
-- `server_error` (ayrıntı: 5xx yanıtının hata kodu). Kullanıcı, IP ya da içerik tutmaz; 400 gün tutulur
-- (src/cleanup.ts).
CREATE TABLE ops_events (
  day TEXT NOT NULL,
  kind TEXT NOT NULL CHECK (kind IN ('refusal', 'provider_error', 'server_error')),
  detail TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, kind, detail)
);

-- Harcama tavanı alarmı günde bir kez yazılır (src/usage.ts): tavan dolduktan sonra reddedilen her istek için alarm
-- satırı yazılmasın diye günün ilk reddi bu sütunu doldurur.
ALTER TABLE daily_spend ADD COLUMN ceiling_alerted_at INTEGER;
ALTER TABLE daily_spend ADD COLUMN trial_ceiling_alerted_at INTEGER;
