-- Uygulama sürümü benimsenmesi (yönetim paneli "Telemetri"; src/clientVersions.ts): uygulama her abonelik sunucusu
-- isteğine `x-app-version` (pazarlama sürümü + yapı numarası, ör. "0.1.10 (19)") ve `x-os-version` (ör. "macOS 15.4.1")
-- başlıklarını koyar; `GET /v1/me` bunların sonuncusunu ve son görülme anını hesabın satırına yazar (aynı sürümler bir
-- saat içinde yeniden yazılmaz). Site ve başlığı göndermeyen eski uygulamalar bir şey yazmaz. Alanlar hesapla birlikte
-- silinir. İçerik tutulmaz.
ALTER TABLE users ADD COLUMN last_app_version TEXT;
ALTER TABLE users ADD COLUMN last_os_version TEXT;
ALTER TABLE users ADD COLUMN last_seen_at INTEGER;
CREATE INDEX users_last_seen_at ON users (last_seen_at);
