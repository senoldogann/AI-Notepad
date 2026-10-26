#!/bin/bash
# Dağıtım sürümü: Release'i Developer ID ile imzalar (hardened runtime, zaman damgası), DMG'ye koyar, Apple'a noter
# onayına (notarization) gönderir ve onayı DMG'ye ekler (staple). Çıktı: .build/release/AI-Notepad-<sürüm>.dmg
#
# Bir kerelik hazırlık (Apple kimliği ve uygulamaya özel şifre Keychain'e kaydedilir, betikte görünmez):
#   xcrun notarytool store-credentials AINotepad --apple-id <apple-id-e-postan> --team-id <takım-kimliği>
set -euo pipefail
cd "$(dirname "$0")/.."

profile="AINotepad"
version="$(grep -E '^\s+MARKETING_VERSION:' project.yml | sed -E 's/.*"(.*)".*/\1/')"
out=".build/release"
app="$out/export/AINotepad.app"
dmg="$out/AI-Notepad-$version.dmg"

xcodegen generate
rm -rf "$out"
mkdir -p "$out/export"
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Release \
    -derivedDataPath .build/xcode-dist -destination 'platform=macOS,arch=arm64' \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Developer ID Application" OTHER_CODE_SIGN_FLAGS="--timestamp" \
    build -quiet
ditto .build/xcode-dist/Build/Products/Release/AINotepad.app "$app"

codesign --verify --deep --strict --verbose=2 "$app"
# Çıktı önce değişkene alınır: `grep -q` boruyu erken kapatınca pipefail yanlış hata verirdi.
signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
[[ "$signature" == *"Authority=Developer ID Application"* ]] || { echo "Developer ID imzası yok." >&2; exit 1; }
[[ "$signature" == *"(runtime)"* ]] || { echo "Hardened runtime kapalı (noter onayı reddeder)." >&2; exit 1; }
entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null)"
[[ "$entitlements" == *"com.apple.security.device.audio-input"* ]] || { echo "Mikrofon yetkisi (entitlement) eksik." >&2; exit 1; }

# DMG: uygulama + Uygulamalar kısayolu (sürükle-bırak kurulum).
staging="$out/dmg"
mkdir -p "$staging"
ditto "$app" "$staging/AINotepad.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "AI-Notepad $version" -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg" -quiet
codesign --sign "Developer ID Application" --timestamp "$dmg"

xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
xcrun stapler staple "$dmg"
spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
shasum -a 256 "$dmg"
echo "Hazır: $dmg"
