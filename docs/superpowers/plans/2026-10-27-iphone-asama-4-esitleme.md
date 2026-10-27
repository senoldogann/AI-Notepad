# iPhone aşama 4 — Eşitleme

Tasarım: `docs/superpowers/specs/2026-10-27-iphone-design.md` (3.2, 3.3).

## Adımlar

1. Yetkiler: iki uygulamaya iCloud Drive kapsayıcısı `iCloud.com.senoldogan.AINotepad` (Xcode otomatik imzalamasıyla
   kaydedildi; Mac ve iPhone geliştirme profilleri). `release.sh` arşivleyip Developer ID ile dışa aktarır (iCloud
   ortamı Production, profil gömülü); `install-app.sh` profili gerekirse hesaptan alır.
2. Çekirdek: `StorageLocation`, `AppPaths.cloudSessionsDirectory/meetingDirectories/meetingDirectory`, birleşik okuma
   (`loadMeetings(directories:)`, inmemiş dosyada indirme), koordineli yazma, çakışma çözümü, taşıma
   (`moveFinishedMeetingsToCloud`, `moveAllMeetingsToLocal`), `ICloudMeetingWatcher`, ortak `CloudSyncController`.
3. Anahtarlar: `saveSyncedSecret`/`deleteSyncedSecret`/`syncedSecretExists`; iPhone okurken eşitlenen kopyaya da bakar.
4. Mac: Ayarlar › Genel › "iCloud ile eşitle", Ayarlar › Anahtarlar › "iPhone'da da kullan"; toplantı bitince taşıma;
   MCP sunucusu iki klasörü de okur.
5. iPhone: Ayarlar › Eşitleme, anahtarlarda "Mac'ten" durumu; toplantı bitince taşıma.

## Durum

- [x] 1–5. Mac 224 + 27 test; iOS simülatörü çekirdek testleri; iki uygulama derlenir. Gerçek iCloud'da (bu Mac, Debug
  `--icloud-yokla`): sahte toplantı iCloud'a taşındı, listede görüldü, geri geldi; Anahtar Zinciri'ne eşitlenen kopya
  yazıldı ve silindi. Developer ID dışa aktarması iCloud'lu profil ve Production ortamıyla doğrulandı.
- İki cihaz arasında gerçek eşitleme (iPhone ↔ Mac) elle kabul testinde denenecek.
