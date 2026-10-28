#!/bin/bash
# Dağıtım sürümü: Release'i Developer ID ile imzalar (hardened runtime, zaman damgası), DMG'ye koyar, Apple'a noter
# onayına (notarization) gönderir ve onayı DMG'ye ekler (staple). Çıktı: .build/release/AI-Notepad-<sürüm>.dmg
#
# Ardından Sparkle güncellemesini hazırlar: DMG'yi Sparkle'ın EdDSA anahtarıyla imzalar (sign_update), yerel
# release-archive/ klasöründe appcast.xml'i yeni sürümle günceller (generate_appcast) ve GitHub sürümünü açacak
# `gh release create` komutunu yazar; komutu çalıştırmaz.
#
# Kullanım:
#   scripts/release.sh <sürüm-notları.md>
# Her sürümden önce project.yml'de MARKETING_VERSION ve CURRENT_PROJECT_VERSION artırılır (Sparkle sürümleri
# CFBundleVersion ile karşılaştırır). Sürüm notları Markdown'dır; appcast'e gömülür, Sparkle güncelleme penceresinde
# gösterir.
#
# Bir kerelik hazırlık (Apple kimliği ve uygulamaya özel şifre Keychain'e kaydedilir, betikte görünmez):
#   xcrun notarytool store-credentials AINotepad --apple-id <apple-id-e-postan> --team-id <takım-kimliği>
# Sparkle anahtarı (bir kez; gizli anahtar giriş Anahtar Zinciri'nde "ed25519" hesabına kaydedilir, asla repoya girmez):
#   xcodegen generate && xcodebuild -resolvePackageDependencies -project AINotepad.xcodeproj -scheme AINotepad \
#       -derivedDataPath .build/xcode-dist
#   .build/xcode-dist/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
# Aracın yazdığı açık anahtar Config/Signing.xcconfig'teki SPARKLE_PUBLIC_KEY'e yazılıp repoya işlenir. Anahtar
# kaybolursa yayınlanmış sürümler artık güncelleme alamaz: Anahtar Zinciri yedeği için `generate_keys -x <dosya>`.
#
# release-archive/ (repoya girmez) appcast.xml'in yerel kopyasını tutar; silinmez, her sürüm üstüne eklenir. Önceki
# sürümlerin DMG'leri release-archive/old_updates/'e taşınır (generate_appcast yalnızca kökteki arşivleri işler; eski
# öğelerin indirme adresleri olduğu gibi kalır).
set -euo pipefail
cd "$(dirname "$0")/.."

[[ $# -eq 1 ]] || { echo "Kullanım: scripts/release.sh <sürüm-notları.md>" >&2; exit 1; }
notes="$1"
[[ -f "$notes" ]] || { echo "Sürüm notları dosyası yok: $notes" >&2; exit 1; }
[[ "$notes" == *.md ]] || { echo "Sürüm notları Markdown (.md) olmalı: $notes" >&2; exit 1; }
notes="$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")"

profile="AINotepad"
version="$(grep -E '^\s+MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')"
build="$(grep -E '^\s+CURRENT_PROJECT_VERSION:' project.yml | head -1 | sed -E 's/.*"(.*)".*/\1/')"
repo="senoldogann/AI-Notepad"
archive_dir="release-archive"
out=".build/release"
app="$out/export/AINotepad.app"
dmg="$out/AI-Notepad-$version.dmg"

team="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM' Config/Local.xcconfig | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
[[ -n "$team" ]] || { echo "Config/Local.xcconfig'te DEVELOPMENT_TEAM yok." >&2; exit 1; }
# Uzun derlemeden önce: açık anahtar yoksa uygulama güncelleme denetlemez, bu sürüm de güncellenemez.
sparkle_public_key="$(grep -E '^[[:space:]]*SPARKLE_PUBLIC_KEY[[:space:]]*=' Config/Signing.xcconfig | sed -E 's/.*=[[:space:]]*//' | tr -d '[:space:]')"
[[ -n "$sparkle_public_key" ]] || {
    echo "Config/Signing.xcconfig'te SPARKLE_PUBLIC_KEY boş. Bir kez generate_keys çalıştırıp açık anahtarı oraya yaz (bkz. betiğin başı)." >&2
    exit 1
}
if [[ -f "$archive_dir/appcast.xml" ]] && grep -q "<sparkle:version>$build</sparkle:version>" "$archive_dir/appcast.xml"; then
    echo "appcast.xml'de $build derlemesi zaten var; project.yml'de CURRENT_PROJECT_VERSION'ı artır." >&2
    exit 1
fi

xcodegen generate
rm -rf "$out"
mkdir -p "$out/export"
# Arşivle ve Developer ID ile dışa aktar: iCloud yetkisi Developer ID profili ister; Xcode'un otomatik imzalaması
# profili geliştirici hesabından alır, hardened runtime ve zaman damgasıyla imzalar, iCloud ortamını Production yapar.
xcodebuild -project AINotepad.xcodeproj -scheme AINotepad -configuration Release \
    -derivedDataPath .build/xcode-dist -destination 'generic/platform=macOS' ARCHS=arm64 \
    -archivePath "$out/AINotepad.xcarchive" -allowProvisioningUpdates archive -quiet
cat > "$out/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>automatic</string>
    <key>teamID</key>
    <string>$team</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive -archivePath "$out/AINotepad.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates

codesign --verify --deep --strict --verbose=2 "$app"
# Çıktı önce değişkene alınır: `grep -q` boruyu erken kapatınca pipefail yanlış hata verirdi.
signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
[[ "$signature" == *"Authority=Developer ID Application"* ]] || { echo "Developer ID imzası yok." >&2; exit 1; }
[[ "$signature" == *"(runtime)"* ]] || { echo "Hardened runtime kapalı (noter onayı reddeder)." >&2; exit 1; }
entitlements="$(codesign -d --entitlements - "$app" 2>/dev/null)"
[[ "$entitlements" == *"com.apple.security.device.audio-input"* ]] || { echo "Mikrofon yetkisi (entitlement) eksik." >&2; exit 1; }
[[ "$entitlements" == *"iCloud.com.senoldogan.AINotepad"* ]] || { echo "iCloud yetkisi eksik." >&2; exit 1; }
[[ -f "$app/Contents/embedded.provisionprofile" ]] || { echo "Developer ID profili gömülü değil (iCloud çalışmaz)." >&2; exit 1; }
# Sparkle gömülü ve açık anahtar uygulamada (yoksa yayınlanan sürüm güncelleme alamaz).
[[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle.framework uygulamaya gömülmemiş." >&2; exit 1; }
[[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" == "$sparkle_public_key" ]] || {
    echo "Uygulamanın Info.plist'indeki SUPublicEDKey, Config/Signing.xcconfig'teki SPARKLE_PUBLIC_KEY ile aynı değil." >&2
    exit 1
}
# Hata ayıklayıcı izni dağıtımda olmamalı (Apple noter onayı reddeder).
[[ "$entitlements" != *"get-task-allow"* ]] || { echo "get-task-allow yetkisi var (noter onayı reddeder)." >&2; exit 1; }

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

# Sparkle: araçlar Sparkle paketinin (SPM) ikili dağıtımında; SPARKLE_BIN ile başka bir klasör verilebilir.
sparkle_bin="${SPARKLE_BIN:-.build/xcode-dist/SourcePackages/artifacts/sparkle/Sparkle/bin}"
for tool in sign_update generate_appcast generate_keys; do
    [[ -x "$sparkle_bin/$tool" ]] || { echo "Sparkle aracı bulunamadı: $sparkle_bin/$tool (SPARKLE_BIN ile klasörü ver)." >&2; exit 1; }
done
# Anahtar Zinciri'ndeki gizli anahtar uygulamadaki açık anahtarla eşleşmeli; yoksa güncellemenin imzası reddedilir.
keychain_public_key="$("$sparkle_bin/generate_keys" --account ed25519 -p)" || {
    echo "Anahtar Zinciri'nde Sparkle anahtarı (hesap: ed25519) yok. Bir kez generate_keys çalıştır (bkz. betiğin başı)." >&2
    exit 1
}
[[ "$keychain_public_key" == "$sparkle_public_key" ]] || {
    echo "Anahtar Zinciri'ndeki Sparkle anahtarı Config/Signing.xcconfig'teki SPARKLE_PUBLIC_KEY ile eşleşmiyor." >&2
    exit 1
}
# Staple'dan sonra imzalanır: staple DMG'yi değiştirir, imza son dosyanın baytlarına aittir.
sparkle_signature="$("$sparkle_bin/sign_update" --account ed25519 "$dmg")" || {
    echo "DMG Sparkle anahtarıyla imzalanamadı: $dmg" >&2
    exit 1
}
echo "Sparkle imzası: $sparkle_signature"

# appcast: kökte yalnızca yeni sürümün DMG'si ve notları kalır (eskiler old_updates/'e; adresleri değişmesin).
mkdir -p "$archive_dir/old_updates"
for old in "$archive_dir"/*.dmg "$archive_dir"/*.md; do
    [[ -e "$old" ]] || continue
    mv "$old" "$archive_dir/old_updates/"
done
cp "$dmg" "$archive_dir/"
cp "$notes" "$archive_dir/$(basename "${dmg%.dmg}").md"
"$sparkle_bin/generate_appcast" --account ed25519 --embed-release-notes --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$repo/releases/download/v$version/" "$archive_dir"
appcast="$archive_dir/appcast.xml"
grep -q "<sparkle:version>$build</sparkle:version>" "$appcast" || { echo "appcast.xml'de $build derlemesi yok; generate_appcast çıktısını kontrol et." >&2; exit 1; }
grep -q "releases/download/v$version/$(basename "$dmg")" "$appcast" || { echo "appcast.xml'deki indirme adresi beklenen gibi değil." >&2; exit 1; }
echo "appcast güncellendi: $appcast"

# GitHub sürümü elle açılır (betik yayımlamaz); appcast.xml her sürümde varlık olarak eklenir, uygulamalar onu
# releases/latest/download/appcast.xml adresinden okur.
echo
echo "Yayınlamak için:"
printf '  gh release create %q %q %q --repo %q --title %q --notes-file %q\n' \
    "v$version" "$dmg" "$appcast" "$repo" "AI-Notepad $version" "$notes"
