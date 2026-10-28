# AI-Notepad

macOS 26+ menü çubuğu uygulaması: toplantıları canlı yazıya döker ve Türkçeye çevirir.
Tasarım: `docs/superpowers/specs/`. Planlar: `docs/superpowers/plans/`.

## Yapı

- `Packages/AINotepadCore/` — tüm mantık (Swift paketi). Testler buradadır.
- `App/` — yalnızca SwiftUI/AppKit arayüzü ve yaşam döngüsü.
- `iOS/` — iPhone uygulaması (SwiftUI); aynı paketi kullanır.
- `project.yml` — XcodeGen tanımı; `AINotepad.xcodeproj` üretilir, repoya girmez.
- İmzalama: `Config/Local.xcconfig.example` dosyasını `Config/Local.xcconfig` olarak kopyalayıp `DEVELOPMENT_TEAM` yaz.

## Komutlar

```bash
xcodegen generate
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet
swift test --package-path Packages/AINotepadCore                              # hızlı testler
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadiOS -configuration Debug \
  -derivedDataPath .build/xcode-ios -destination 'platform=iOS Simulator,name=iPhone 17' build -quiet   # iPhone uygulaması
(cd Packages/AINotepadCore && xcodebuild test -scheme AINotepadCore-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' -quiet)                # çekirdek testleri iOS'ta
AINOTEPAD_MODEL_TESTS=1 swift test --package-path Packages/AINotepadCore      # + gerçek WhisperKit modeli (~630 MB indirir)
AINOTEPAD_CLOUD_TESTS=1 AINOTEPAD_SCENARIO_TESTS=1 swift test --package-path Packages/AINotepadCore --filter LLMScenarioTests  # pahalı: uzun toplantı × her model × max effort
(cd server && npx wrangler dev --port 8797)   # sonra: AINOTEPAD_HOSTED_E2E=1 AINOTEPAD_HOSTED_BASE=http://127.0.0.1:8797 swift test --package-path Packages/AINotepadCore --filter HostedE2E (server/.dev.vars sahte değerlerle, migrate:local önce)
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadHosted -configuration Debug \
  -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet   # abonelik sürümü (App/Hosted, HOSTED_EDITION)
scripts/make-test-fixtures.sh                                                 # test seslerini yeniden üretir
scripts/install-app.sh                                                        # Release'i /Applications'a kurar (izinler kalıcı)
```

`xcodebuild -exportLocalizations` `-derivedDataPath` kabul etmez ve `~/Library/Developer/Xcode/DerivedData`'ya ad-hoc
imzalı bir AINotepad.app bırakır; Spotlight onu bulur, açılınca izinler her seferinde yeniden sorulur. Çalıştırdıysan
o kopyayı sil.

Kod değiştiren her işten önce iki test komutunu da çalıştır.
