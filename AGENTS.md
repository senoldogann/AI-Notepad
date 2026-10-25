# AI-Notepad

macOS 26+ menü çubuğu uygulaması: toplantıları canlı yazıya döker ve Türkçeye çevirir.
Tasarım: `docs/superpowers/specs/`. Planlar: `docs/superpowers/plans/`.

## Yapı

- `Packages/AINotepadCore/` — tüm mantık (Swift paketi). Testler buradadır.
- `App/` — yalnızca SwiftUI/AppKit arayüzü ve yaşam döngüsü.
- `project.yml` — XcodeGen tanımı; `AINotepad.xcodeproj` üretilir, repoya girmez.
- İmzalama: `Config/Local.xcconfig.example` dosyasını `Config/Local.xcconfig` olarak kopyalayıp `DEVELOPMENT_TEAM` yaz.

## Komutlar

```bash
xcodegen generate
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet
swift test --package-path Packages/AINotepadCore                              # hızlı testler
AINOTEPAD_MODEL_TESTS=1 swift test --package-path Packages/AINotepadCore      # + gerçek WhisperKit modeli (~630 MB indirir)
scripts/make-test-fixtures.sh                                                 # test seslerini yeniden üretir
```

Kod değiştiren her işten önce iki test komutunu da çalıştır.
