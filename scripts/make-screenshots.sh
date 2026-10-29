#!/bin/bash
# Web sitesinin uygulama ekran görüntülerini sahte (tanıtım) verilerle çeker: Gistsmith'in Debug derlemesi geçici bir
# kopyada, ayrı paket kimliğiyle ve geçici bir ev klasörüyle (CFFIXED_USER_HOME) açılır; kullanıcının toplantılarına,
# ayarlarına ve Anahtar Zinciri öğelerine dokunulmaz (bkz. App/DemoData.swift). Yalnızca bu betiğin açtığı sürecin
# pencereleri numarasıyla çekilir (tam ekran ya da başka uygulama çekilmez); bitince yalnızca o süreç kapatılır.
# Çıktı: .build/screenshots/<sahne>.png (Retina, gölgesiz, köşeleri saydam) ve sitenin kaynağı
# web/src/assets/screenshots/<ad>.webp (yüksek kaliteli WebP; site derlemede AVIF/WebP boyutlarını bundan üretir).
# Gerekenler: xcodegen, Xcode, cwebp (brew install webp); çekim Retina ekranda yapılır (App/DemoData.swift taşır).
# Kullanım: scripts/make-screenshots.sh [sahne ...]   (varsayılan: ana not sor canli)
set -euo pipefail
cd "$(dirname "$0")/.."

scenes=("$@")
if [ ${#scenes[@]} -eq 0 ]; then
    scenes=(ana not sor canli)
fi

if ! command -v cwebp >/dev/null; then
    echo "cwebp yok: brew install webp" >&2
    exit 1
fi

xcodegen generate >/dev/null
xcodebuild -project AINotepad.xcodeproj -scheme AINotepadHosted -configuration Debug \
    -derivedDataPath .build/xcode -destination 'platform=macOS,arch=arm64' build -quiet

work="$(mktemp -d /tmp/gistsmith-tanitim.XXXXXX)"
demo_id="com.senoldogan.AINotepad.hosted.tanitim"
app="$work/Gistsmith.app"
out=".build/screenshots"
assets="web/src/assets/screenshots"
mkdir -p "$out" "$assets"

# Ayrı paket kimliği: ayarlar sahibin uygulamasının alanına değil tanıtım alanına yazılır (sonda silinir). Güncelleme
# anahtarı kaldırılır: tanıtım kopyası güncelleme denetlemez. Değişen Info.plist için kopya geçici imzayla yeniden
# imzalanır (yetkisiz: mikrofon, Apple ile giriş gerekmez).
ditto ".build/xcode/Build/Products/Debug/Gistsmith.app" "$app"
plist="$app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $demo_id" "$plist"
for key in SUPublicEDKey SUFeedURL; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Delete :$key" "$plist"
    fi
done
codesign --force --deep --sign - "$app" 2>/dev/null

# Saat dilimi yerel saati sabah 10'a yakın tutar: ana sayfa "Good morning" der, "bugün" toplantısı sabah olur.
utc_hour=$((10#$(date -u +%H)))
offset=$(( (10 - utc_hour + 36) % 24 - 12 ))
if [ "$offset" -ge 0 ]; then tz="Etc/GMT-$offset"; else tz="Etc/GMT+$((-offset))"; fi

cleanup() {
    defaults delete "$demo_id" >/dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

for scene in "${scenes[@]}"; do
    home="$work/home-$scene"
    mkdir -p "$home"
    env CFFIXED_USER_HOME="$home" TZ="$tz" "$app/Contents/MacOS/Gistsmith" --tanitim "$scene" \
        -AppleLanguages "(en)" -AppleLocale en_US \
        -onboardingCompleted YES -hideFromScreenCapture NO -userName "Alex Morgan" \
        -appearance.theme light -language.note en -displayMode bilingual \
        >"$work/$scene.log" 2>&1 &
    pid=$!
    # Açılış ekranı, pencerenin Retina ekrana taşınması ve Sor sohbetinin açılması için bekler.
    sleep 6
    if ! kill -0 "$pid" 2>/dev/null; then
        echo "Tanıtım uygulaması kapandı ($scene); günlük:" >&2
        cat "$work/$scene.log" >&2
        exit 1
    fi
    # Canlı sahnede yüzen panel (katman > 0), diğerlerinde en büyük normal pencere (katman 0).
    if [ "$scene" = "canli" ]; then
        window=$(swift scripts/demo-windows.swift "$pid" | awk -F'\t' '$2 > 0 && $3 >= 380 && $3 <= 460 { print $1; exit }')
    else
        window=$(swift scripts/demo-windows.swift "$pid" | awk -F'\t' '$2 == 0 { print $3 * $4 "\t" $1 }' | sort -rn | head -1 | cut -f2)
    fi
    if [ -z "$window" ]; then
        echo "Tanıtım penceresi bulunamadı ($scene)." >&2
        kill "$pid"
        exit 1
    fi
    screencapture -x -o -l "$window" "$out/$scene.png"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
    case "$scene" in
        ana) asset=home ;;
        not) asset=note ;;
        sor) asset=ask ;;
        canli) asset=live ;;
        *) echo "Bilinmeyen sahne: $scene" >&2; exit 1 ;;
    esac
    cwebp -quiet -q 94 -m 6 -alpha_q 100 "$out/$scene.png" -o "$assets/$asset.webp"
    echo "$assets/$asset.webp ($(sips -g pixelWidth -g pixelHeight "$out/$scene.png" | awk '/pixel/ { printf "%s ", $2 }'))"
done
