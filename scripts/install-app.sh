#!/bin/bash
# AI-Notepad'i Release olarak derleyip /Applications/AINotepad.app'e kurar.
# Kalıcı yer ve geliştirici sertifikası imzası: macOS izinleri (mikrofon, sistem sesi) imzaya bağlıdır; geçici
# (ad-hoc) imzalı ya da her derlemede başka yerden açılan kopyada izinler kalıcı olmaz, her açılışta yeniden sorulur.
# iCloud yetkisi profil ister: Xcode'un otomatik imzalaması profili gerekirse geliştirici hesabından alır.
set -euo pipefail
cd "$(dirname "$0")/.."

# Yalnız Mac uygulaması aranır (iPhone simülatöründeki uygulamanın süreç adı da AINotepad).
if pgrep -f "AINotepad.app/Contents/MacOS/AINotepad" >/dev/null; then
    echo "AI-Notepad açık: önce menüden çık (kayıt sürüyorsa bitmesini bekle), sonra yeniden çalıştır." >&2
    exit 1
fi

xcodegen generate
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Release \
    -derivedDataPath .build/xcode-release -destination 'platform=macOS,arch=arm64' -allowProvisioningUpdates build -quiet

app=".build/xcode-release/Build/Products/Release/AINotepad.app"
codesign --verify --deep --strict "$app"
if ! codesign -d -r- "$app" 2>&1 | grep -q "anchor apple generic"; then
    echo "Uygulama geliştirici sertifikasıyla imzalanmamış (izinler kalıcı olmaz): Config/Local.xcconfig'teki DEVELOPMENT_TEAM'i kontrol et." >&2
    exit 1
fi

rm -rf /Applications/AINotepad.app
ditto "$app" /Applications/AINotepad.app
echo "Kuruldu: /Applications/AINotepad.app"
