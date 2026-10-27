# iPhone aşama 1 — Temel

Tasarım: `docs/superpowers/specs/2026-10-27-iphone-design.md`.

## Hedef

Çekirdek paket iOS'ta da derlenir ve testleri geçer; iOS uygulama hedefi simülatörde açılır ve yerel toplantı
klasörünü okuyup listeler. Mac uygulaması hiç değişmeden çalışmaya devam eder.

## Adımlar

1. `Package.swift`: `platforms: [.macOS(.v26), .iOS(.v26)]`. macOS'a özgü kaynaklar `#if os(macOS)`: sistem sesi
   yakalama (`SystemAudioCapture`), PDF belgesi, önizleme aracı. macOS'a özgü testler (WhisperKit modeli, `Process`,
   Anahtar Zinciri) yalnız macOS'ta çalışır.
2. Mikrofon için `AVAudioSession` kurulumu aşama 2'ye (Kayıt) taşındı; kayıt ekranıyla birlikte yazılır.
3. `AINotepadUI`: renkler `NSColor`/`UIColor` ile dinamik; pano (kopyala) platforma göre; PDF belgesi (`MeetingDocument`)
   macOS'ta kalır, iOS'ta web sayfası paylaşımı kullanılır.
4. `project.yml`: `AINotepadiOS` hedefi (iOS 26, iPhone), aynı paket ürünleri, Inter yazı tipi, `Localizable.xcstrings`
   paylaşılır; Info.plist: mikrofon açıklaması, arka plan ses modu.
5. iOS uygulaması iskeleti: sekmeler (Kayıt, Toplantılar, Sor, Görevler) + Ayarlar; Toplantılar yerel `Sessions`
   klasörünü okur ve listeler (Mac'teki `loadMeetings`); diğer sekmeler aşama 2–3'te dolar.
6. Doğrulama: `swift build` (macOS), `xcodebuild` iOS simülatörü için çekirdek ve uygulama; hızlı testler macOS'ta ve iOS
   simülatöründe; uygulama simülatörde açılıp ekran görüntüsü alınır.

## Durum

- [x] 1, 3–6 (aşama 2'ye taşınan 2 hariç). Mac: 222 + 27 test, uygulama derlenir. iOS simülatörü: çekirdek testleri
  geçer; uygulama açılır, toplantı listesi ve not okuma ekranı doğrulandı.
