# iPhone aşama 5 — Cila

Tasarım: `docs/superpowers/specs/2026-10-27-iphone-design.md` (3.4).

## Adımlar

1. Canlı etkinlik (`RecordingActivityAttributes`): kilit ekranı ve Dynamic Island'da kırmızı nokta, süre, son cümle
   (konuşmacısıyla), "Bitir" (uygulamayı açmadan `StopRecordingIntent`). Kayıt başlayınca açılır, cümlelerle en fazla
   2 sn'de bir güncellenir, bitirilirken "Bitiriliyor…", oturum bitince kalkar.
2. Niyetler (`iOS/Shared/RecordingIntents.swift`, uygulama ve eklentide ortak; eklentide gövde boş): "Toplantıyı kaydet"
   (uygulamayı açar, Kayıt sekmesine geçip başlatır) ve "Kaydı bitir"; Kısayollar/Siri komutları (`AppShortcuts`).
3. Widget eklentisi `AINotepadWidgets`: canlı etkinlik, Denetim Merkezi / Eylem düğmesi kontrolü, ana ekran (küçük) ve
   kilit ekranı (yuvarlak) widget'ı.
4. TestFlight: kullanıcı kararıyla şimdilik yapılmadı.

## Durum

- [x] 1–3. Simülatör ve cihaz (generic iOS, otomatik imzalama) derlemesi; simülatörde örnek kayıtla etkinlik istendi ve
  sistem güncellemeyi teslim etti (`liveactivitiesd`), eklenti çizimi başarılı. Kilit ekranı / Dynamic Island görünümü
  simülatörün ekran görüntüsüne girmediği için gerçek telefonda elle kabul testinde bakılacak.
