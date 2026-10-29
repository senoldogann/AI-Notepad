#!/bin/bash
# Mac sürümlerinin yayın betiklerinin ortak adımları: scripts/release.sh (geliştirici sürümü, AI-Notepad) ve
# scripts/release-gistsmith.sh (abonelik sürümü, Gistsmith) bu dosyayı `source` ile yükler. Her fonksiyon tek iş yapar,
# tüm değerleri parametre olarak alır ve hata olursa açık mesajla betiği durdurur. Komutlar deponun kökünden çalışır.
#
# Bir kerelik hazırlık (iki sürüm için ortak; Apple kimliği ve uygulamaya özel şifre Anahtar Zinciri'ne kaydedilir,
# betikte görünmez):
#   xcrun notarytool store-credentials AINotepad --apple-id <apple-id-e-postan> --team-id <takım-kimliği>
# Sparkle araçları (generate_keys, sign_update, generate_appcast) arşivlemenin indirdiği Sparkle paketindedir:
#   xcodegen generate && xcodebuild -resolvePackageDependencies -project AINotepad.xcodeproj -scheme AINotepad \
#       -derivedDataPath .build/xcode-dist
#   .build/xcode-dist/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys --account <hesap>
# Her sürümün kendi Sparkle hesabı ve açık anahtarı var (Config/Signing.xcconfig). Anahtar kaybolursa yayınlanmış
# sürümler artık güncelleme alamaz: Anahtar Zinciri yedeği için `generate_keys --account <hesap> -x <dosya>`.

[[ "${BASH_SOURCE[0]}" != "$0" ]] || { echo "Bu dosya doğrudan çalıştırılmaz; scripts/release.sh ya da scripts/release-gistsmith.sh onu yükler." >&2; exit 1; }

# Noter onayı kimlik bilgilerinin Anahtar Zinciri profili (iki sürüm aynı Apple hesabıyla onaylanır).
notary_profile="AINotepad"
# Arşivleme ve Sparkle araçlarının indirildiği türetilmiş veri klasörü.
dist_derived_data=".build/xcode-dist"

# Config/Signing.xcconfig'teki `<anahtar> = <değer>` satırının değeri; yoksa ya da boşsa durur.
xcconfig_value() {
    local key="$1"
    local value
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" Config/Signing.xcconfig | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')"
    [[ -n "$value" ]] || { echo "Config/Signing.xcconfig'te $key boş ya da yok." >&2; exit 1; }
    printf '%s\n' "$value"
}

# Config/Local.xcconfig'teki Apple takım kimliği.
development_team() {
    local team
    team="$(grep -E '^[[:space:]]*DEVELOPMENT_TEAM' Config/Local.xcconfig | sed -E 's/^[^=]*=[[:space:]]*//' | tr -d '[:space:]')"
    [[ -n "$team" ]] || { echo "Config/Local.xcconfig'te DEVELOPMENT_TEAM yok." >&2; exit 1; }
    printf '%s\n' "$team"
}

# project.yml'deki tek ve tutarlı `<ayar>` değeri (MARKETING_VERSION ya da CURRENT_PROJECT_VERSION): tüm hedefler aynı
# değeri taşımalı; farklıysa durulur (önceden satırlar birleşip bozuk DMG adı çıkıyordu).
project_setting() {
    local setting="$1"
    local values
    values="$(grep -E "^[[:space:]]+${setting}:" project.yml | sed -E 's/.*"(.*)".*/\1/' | sort -u)"
    [[ -n "$values" ]] || { echo "project.yml'de $setting yok." >&2; exit 1; }
    [[ "$(printf '%s\n' "$values" | wc -l | tr -d '[:space:]')" == "1" ]] || {
        echo "project.yml'deki hedeflerin $setting değerleri farklı: $(printf '%s ' $values)" >&2
        exit 1
    }
    printf '%s\n' "$values"
}

# Sürüm (MARKETING_VERSION), x.y.z biçiminde.
project_version() {
    local version
    version="$(project_setting MARKETING_VERSION)" || exit 1
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Geçersiz sürüm: '$version'" >&2; exit 1; }
    printf '%s\n' "$version"
}

# Derleme numarası (CURRENT_PROJECT_VERSION): Sparkle sürümleri CFBundleVersion ile karşılaştırır.
project_build() {
    local build
    build="$(project_setting CURRENT_PROJECT_VERSION)" || exit 1
    [[ "$build" =~ ^[0-9]+$ ]] || { echo "Geçersiz derleme numarası: '$build'" >&2; exit 1; }
    printf '%s\n' "$build"
}

# Sürüm notları dosyasının mutlak yolu: var olmalı ve Markdown (.md) olmalı (appcast'e gömülür, Sparkle güncelleme
# penceresinde gösterir).
release_notes_path() {
    local notes="$1"
    [[ -f "$notes" ]] || { echo "Sürüm notları dosyası yok: $notes" >&2; exit 1; }
    [[ "$notes" == *.md ]] || { echo "Sürüm notları Markdown (.md) olmalı: $notes" >&2; exit 1; }
    printf '%s\n' "$(cd "$(dirname "$notes")" && pwd)/$(basename "$notes")"
}

# Çalışma ağacı temiz olmalı (işlenmemiş ya da izlenmeyen dosya yok): yayın, depodaki bir işlemeden derlenir; yerel
# değişiklik sürüme sızmaz ve sürüm hangi işlemeden çıktığı bilinir.
require_clean_worktree() {
    local changes
    changes="$(git status --porcelain)"
    [[ -z "$changes" ]] || {
        echo "Çalışma ağacı temiz değil; önce işle ya da geri al:" >&2
        printf '%s\n' "$changes" >&2
        exit 1
    }
}

# Yerel appcast'te bu derleme zaten varsa durur (her sürümde CURRENT_PROJECT_VERSION artırılır).
require_new_build() {
    local appcast="$1"
    local build="$2"
    if [[ -f "$appcast" ]] && grep -q "<sparkle:version>$build</sparkle:version>" "$appcast"; then
        echo "$appcast'te $build derlemesi zaten var; project.yml'de CURRENT_PROJECT_VERSION'ı artır." >&2
        exit 1
    fi
}

# Şemayı Release olarak arşivler ve Developer ID ile dışa aktarır: Xcode'un otomatik imzalaması profili geliştirici
# hesabından alır (iCloud profil ister; özel yetkisi olmayan uygulamaya profil gömülmez), hardened runtime ve zaman damgasıyla imzalar. Uygulama
# `<çıktı>/export/` altına çıkar.
archive_and_export() {
    local scheme="$1"
    local archive="$2"
    local export_dir="$3"
    local team="$4"
    local options="$export_dir/ExportOptions.plist"
    mkdir -p "$export_dir"
    xcodebuild -project AINotepad.xcodeproj -scheme "$scheme" -configuration Release \
        -derivedDataPath "$dist_derived_data" -destination 'generic/platform=macOS' ARCHS=arm64 \
        -archivePath "$archive" -allowProvisioningUpdates archive -quiet
    cat > "$options" <<PLIST
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
    xcodebuild -exportArchive -archivePath "$archive" -exportPath "$export_dir" \
        -exportOptionsPlist "$options" -allowProvisioningUpdates
}

# Sparkle araçlarının klasörü: SPARKLE_BIN ortam değişkeni ya da arşivlemenin indirdiği Sparkle paketi; araçlar yoksa
# durur. Noter onayından önce denetlenir: anahtar sorunu uzun beklemeden sonra çıkmasın.
sparkle_tools_dir() {
    local bin="${SPARKLE_BIN:-$dist_derived_data/SourcePackages/artifacts/sparkle/Sparkle/bin}"
    local tool
    for tool in sign_update generate_appcast generate_keys; do
        [[ -x "$bin/$tool" ]] || { echo "Sparkle aracı bulunamadı: $bin/$tool (SPARKLE_BIN ile klasörü ver)." >&2; exit 1; }
    done
    printf '%s\n' "$bin"
}

# Anahtar Zinciri'ndeki gizli anahtarın açık anahtarı uygulamadakiyle eşleşmeli; yoksa güncellemenin imzası reddedilir.
require_sparkle_keychain_key() {
    local bin="$1"
    local account="$2"
    local expected="$3"
    local actual
    actual="$("$bin/generate_keys" --account "$account" -p)" || {
        echo "Anahtar Zinciri'nde Sparkle anahtarı (hesap: $account) yok. Bir kez generate_keys --account $account çalıştır." >&2
        exit 1
    }
    [[ "$actual" == "$expected" ]] || {
        echo "Anahtar Zinciri'ndeki Sparkle anahtarı (hesap: $account) Config/Signing.xcconfig'teki açık anahtarla eşleşmiyor." >&2
        exit 1
    }
}

# Dışa aktarılan uygulamanın dağıtıma uygunluğu: Developer ID imzası, hardened runtime, mikrofon yetkisi,
# Developer ID ile yeniden imzalanmış Sparkle yardımcıları, Info.plist'teki Sparkle açık anahtarı ve hata
# ayıklayıcı izninin yokluğu. Sürüme özgü yetkiler ve gömülü profil (yalnızca iCloud'lu geliştirici sürümünde) çağıran
# betikte denetlenir.
verify_distribution_app() {
    local app="$1"
    local sparkle_public_key="$2"
    codesign --verify --deep --strict --verbose=2 "$app"
    # Çıktı önce değişkene alınır: `grep -q` boruyu erken kapatınca pipefail yanlış hata verirdi.
    local signature
    signature="$(codesign -dv --verbose=2 "$app" 2>&1)"
    [[ "$signature" == *"Authority=Developer ID Application"* ]] || { echo "Developer ID imzası yok." >&2; exit 1; }
    [[ "$signature" == *"(runtime)"* ]] || { echo "Hardened runtime kapalı (noter onayı reddeder)." >&2; exit 1; }
    local entitlements
    entitlements="$(app_entitlements "$app")"
    [[ "$entitlements" == *"com.apple.security.device.audio-input"* ]] || { echo "Mikrofon yetkisi (entitlement) eksik." >&2; exit 1; }
    # Hata ayıklayıcı izni dağıtımda olmamalı (Apple noter onayı reddeder).
    [[ "$entitlements" != *"get-task-allow"* ]] || { echo "get-task-allow yetkisi var (noter onayı reddeder)." >&2; exit 1; }
    # Sparkle gömülü ve açık anahtar uygulamada (yoksa yayınlanan sürüm güncelleme alamaz).
    [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]] || { echo "Sparkle.framework uygulamaya gömülmemiş." >&2; exit 1; }
    # Sparkle'ın yardımcıları pakette ad-hoc imzalı gelir; Developer ID dışa aktarımı onları yeniden imzalamalı (noter
    # onayı her iç kodda Developer ID, hardened runtime ve zaman damgası ister).
    local versioned="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
    local helper
    local helper_signature
    for helper in "$versioned/XPCServices/Installer.xpc" "$versioned/XPCServices/Downloader.xpc" \
        "$versioned/Autoupdate" "$versioned/Updater.app"; do
        [[ -e "$helper" ]] || { echo "Sparkle yardımcısı eksik: $helper" >&2; exit 1; }
        helper_signature="$(codesign -dv --verbose=2 "$helper" 2>&1)"
        [[ "$helper_signature" == *"Authority=Developer ID Application"* && "$helper_signature" == *"(runtime)"* ]] || {
            echo "Sparkle yardımcısı Developer ID ve hardened runtime ile imzalı değil: $helper" >&2
            exit 1
        }
    done
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" == "$sparkle_public_key" ]] || {
        echo "Uygulamanın Info.plist'indeki SUPublicEDKey, Config/Signing.xcconfig'teki açık anahtarla aynı değil." >&2
        exit 1
    }
}

# Uygulamanın imzasındaki yetkiler (entitlements) metin olarak.
app_entitlements() {
    local app="$1"
    codesign -d --entitlements - "$app" 2>/dev/null
}

# Info.plist'teki bir anahtarın değeri beklenenle aynı olmalı (ör. görünen ad, Sparkle akışı).
require_info_value() {
    local app="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$app/Contents/Info.plist")"
    [[ "$actual" == "$expected" ]] || { echo "$app Info.plist $key: '$actual', beklenen '$expected'." >&2; exit 1; }
}

# Uygulamanın imzasında iCloud yetkisi olmamalı (abonelik sürümü eşitleme yapmaz; yetki profil ve Apple hesabı ister).
require_no_icloud_entitlement() {
    local app="$1"
    local entitlements
    entitlements="$(app_entitlements "$app")"
    [[ "$entitlements" != *"com.apple.developer.icloud"* && "$entitlements" != *"com.apple.developer.ubiquity"* ]] || {
        echo "$app imzasında iCloud yetkisi var; bu sürümde olmamalı." >&2
        exit 1
    }
}

# Uygulamanın kendisini noter onayına gönderir ve onayı uygulamaya ekler (staple): DMG'den çıkarılan ya da Sparkle'ın
# kurduğu uygulama, ilk açılışta Apple'a sormadan (çevrimdışı da) Gatekeeper'dan geçer. DMG'den önce çağrılır; DMG
# ayrıca onaylanır (bkz. `make_notarized_dmg`).
notarize_app() {
    local app="$1"
    local zip
    zip="$(dirname "$app")/$(basename "${app%.app}")-notarize.zip"
    rm -f "$zip"
    ditto -c -k --keepParent "$app" "$zip"
    xcrun notarytool submit "$zip" --keychain-profile "$notary_profile" --wait
    rm -f "$zip"
    xcrun stapler staple "$app"
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
}

# DMG: tasarlanmış kurulum penceresi (arka plan, uygulama → Uygulamalar kısayolu), Developer ID imzası, noter onayı ve
# onayın DMG'ye eklenmesi (staple). Uygulama önceden `notarize_app` ile onaylanmış olmalı.
make_notarized_dmg() {
    local app="$1"
    local dmg="$2"
    local volume_name="$3"
    local background_dir="$4"
    scripts/make-dmg.sh "$app" "$dmg" "$volume_name" "$background_dir"
    codesign --sign "Developer ID Application" --timestamp "$dmg"
    xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$dmg"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$dmg"
    shasum -a 256 "$dmg"
    echo "Hazır: $dmg"
}

# DMG'yi Sparkle anahtarıyla imzalar. Staple'dan sonra çağrılır: staple DMG'yi değiştirir, imza son dosyanın baytlarına
# aittir.
sparkle_sign_dmg() {
    local bin="$1"
    local account="$2"
    local dmg="$3"
    local signature
    signature="$("$bin/sign_update" --account "$account" "$dmg")" || {
        echo "DMG Sparkle anahtarıyla imzalanamadı: $dmg" >&2
        exit 1
    }
    echo "Sparkle imzası: $signature"
}

# Yerel arşiv klasöründeki appcast.xml'i yeni sürümle günceller. Kökte yalnızca yeni sürümün DMG'si ve notları kalır;
# önceki sürümlerinkiler old_updates/'e taşınır (generate_appcast yalnızca kökteki arşivleri işler; eski öğelerin
# indirme adresleri olduğu gibi kalır). İndirme adresi yayın deposunun bu sürümün etiketidir.
update_appcast() {
    local bin="$1"
    local account="$2"
    local archive_dir="$3"
    local dmg="$4"
    local notes="$5"
    local repo="$6"
    local version="$7"
    local build="$8"
    local old
    mkdir -p "$archive_dir/old_updates"
    for old in "$archive_dir"/*.dmg "$archive_dir"/*.md; do
        [[ -e "$old" ]] || continue
        mv "$old" "$archive_dir/old_updates/"
    done
    cp "$dmg" "$archive_dir/"
    cp "$notes" "$archive_dir/$(basename "${dmg%.dmg}").md"
    "$bin/generate_appcast" --account "$account" --embed-release-notes --maximum-deltas 0 \
        --download-url-prefix "https://github.com/$repo/releases/download/v$version/" "$archive_dir"
    local appcast="$archive_dir/appcast.xml"
    grep -q "<sparkle:version>$build</sparkle:version>" "$appcast" || { echo "$appcast'te $build derlemesi yok; generate_appcast çıktısını kontrol et." >&2; exit 1; }
    grep -q "github.com/$repo/releases/download/v$version/$(basename "$dmg")" "$appcast" || { echo "$appcast'teki indirme adresi beklenen gibi değil." >&2; exit 1; }
    echo "appcast güncellendi: $appcast"
}

# Yayın deposunda sürümü açacak komutu yazar; çalıştırmaz (yayın elle onaylanır). Varlıklar: sürümlü DMG, sabit adlı
# kopya (site her zaman releases/latest/download/<ürün>.dmg adresinden son sürümü indirir; sürümlü adla o adres bir
# sonraki sürümde 404 verirdi) ve appcast.xml (uygulamalar onu releases/latest/download/appcast.xml adresinden okur).
print_release_command() {
    local repo="$1"
    local version="$2"
    local title="$3"
    local notes="$4"
    local dmg="$5"
    local stable_dmg="$6"
    local appcast="$7"
    cp "$dmg" "$stable_dmg"
    echo
    echo "Yayınlamak için:"
    printf '  gh release create %q %q %q %q --repo %q --title %q --notes-file %q\n' \
        "v$version" "$dmg" "$stable_dmg" "$appcast" "$repo" "$title" "$notes"
}
