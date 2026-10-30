-- İstemci telemetrisi (yönetim paneli "Telemetri"; src/telemetry.ts). Uygulama Ayarlar'daki "Anonim kullanım
-- istatistiklerini paylaş" açıkken gönderir. Toplamlar hesaba bağlı değildir; 400 gün tutulur (src/cleanup.ts).
--
-- Güvenilirlik olaylarının günlük sayısı (`POST /v1/telemetry`): tür (ör. `deepgram_socket_drop`,
-- `final_pass_give_up`) ve uygulama sürümü başına. Gün sunucunun UTC günüdür.
CREATE TABLE client_event_counts (
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  app_version TEXT NOT NULL,
  count INTEGER NOT NULL,
  PRIMARY KEY (day, kind, app_version)
);

-- Süre olaylarının (son geçiş, not yazımı) günlük dağılımı: tür, sürüm ve süre kovası (`le_10` … `gt_3600`, saniye)
-- başına sayı ve saniye toplamı (ortalama için).
CREATE TABLE client_event_durations (
  day TEXT NOT NULL,
  kind TEXT NOT NULL,
  app_version TEXT NOT NULL,
  bucket TEXT NOT NULL,
  count INTEGER NOT NULL,
  seconds_sum REAL NOT NULL,
  PRIMARY KEY (day, kind, app_version, bucket)
);

-- Günlük özellik kullanımı (`POST /v1/telemetry/features`; uygulama günde bir, biten günü raporlar): özellik
-- (`report` paydadır; `live_translation`, `translation_language`, `ask`, `integration`, `export`, `mcp`,
-- `on_device_live`) ve değer (dil kodu, entegrasyon türü, dışa aktarma biçimi; yoksa "") başına o gün kullanan hesap
-- sayısı (`users`) ve kullanım toplamı (`total`). Gün, raporun ait olduğu UTC günüdür.
CREATE TABLE feature_usage_daily (
  day TEXT NOT NULL,
  feature TEXT NOT NULL,
  value TEXT NOT NULL,
  users INTEGER NOT NULL,
  total INTEGER NOT NULL,
  PRIMARY KEY (day, feature, value)
);

-- Kötüye kullanım sınırı ve tekilleştirme (hesabın satırında, hesapla silinir): bugünün (UTC) telemetri istek sayısı
-- (günde en çok 200) ve özellik raporunun son kabul edilen günü (aynı gün ya da daha eskisi yeniden sayılmaz).
ALTER TABLE users ADD COLUMN telemetry_day TEXT;
ALTER TABLE users ADD COLUMN telemetry_batches INTEGER NOT NULL DEFAULT 0;
ALTER TABLE users ADD COLUMN telemetry_features_day TEXT;
