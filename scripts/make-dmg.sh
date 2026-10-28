#!/bin/bash
# Tasarlanmış kurulum penceresiyle DMG üretir: Finder açıldığında arka plan resmi, solda uygulama, sağda Uygulamalar
# kısayolu ve aralarında ok görünür; araç çubuğu, durum çubuğu ve kenar çubuğu gizlidir. Birimin simgesi uygulamanın
# simgesidir. Arka plan `scripts/render-dmg-background.swift` ile çizilir (Config/DMG/); simge konumları oradaki
# yuvalarla aynıdır, biri değişirse diğeri de değişir.
#
# Kullanım:
#   scripts/make-dmg.sh <uygulama.app> <çıktı.dmg> <birim-adı> <arka-plan-klasörü>
# Arka plan klasöründe background.png (660×420) ve background@2x.png (1320×840) bulunmalı; Retina'da keskin görünsün
# diye tek, çok çözünürlüklü bir TIFF'te birleştirilir.
#
# Finder düzeni AppleScript ile kurulur ve .DS_Store'a yazılır: betiği çalıştıran uygulamanın (Terminal vb.) Finder'ı
# denetleme (Otomasyon) izni olmalı. Aynı adlı bir birim takılıysa Finder ikisini karıştırır; betik bu durumda durur.
set -euo pipefail

[[ $# -eq 4 ]] || { echo "Kullanım: scripts/make-dmg.sh <uygulama.app> <çıktı.dmg> <birim-adı> <arka-plan-klasörü>" >&2; exit 1; }
app="$1"
dmg="$2"
volume_name="$3"
background_dir="$4"

# Pencere içeriği arka plan resmiyle aynı boyutta; simge konumları simgelerin merkezleridir (pencere içeriğinin sol üst
# köşesinden, nokta).
window_width=660
window_height=420
window_left=200
window_top=120
icon_size=128
text_size=13
app_x=170
app_y=200
applications_x=490
applications_y=200

[[ -d "$app" && "$app" == *.app ]] || { echo "Uygulama paketi yok ya da .app değil: $app" >&2; exit 1; }
[[ "$dmg" == *.dmg ]] || { echo "Çıktı .dmg ile bitmeli: $dmg" >&2; exit 1; }
[[ ! -e "$dmg" ]] || { echo "Çıktı zaten var (üzerine yazılmaz): $dmg" >&2; exit 1; }
[[ -n "$volume_name" ]] || { echo "Birim adı boş." >&2; exit 1; }
for image in background.png background@2x.png; do
    [[ -f "$background_dir/$image" ]] || { echo "Arka plan resmi yok: $background_dir/$image (swift scripts/render-dmg-background.swift <ürün-adı> $background_dir)" >&2; exit 1; }
done
for tool in hdiutil osascript tiffutil SetFile ditto; do
    command -v "$tool" >/dev/null || { echo "Gerekli araç bulunamadı: $tool (SetFile Xcode Komut Satırı Araçları ile gelir: xcode-select --install)" >&2; exit 1; }
done
[[ ! -e "/Volumes/$volume_name" ]] || {
    echo "/Volumes/$volume_name zaten takılı; Finder iki birimi karıştırır. Önce onu çıkar: hdiutil detach \"/Volumes/$volume_name\"" >&2
    exit 1
}
icon_name="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")"
icon="$app/Contents/Resources/${icon_name%.icns}.icns"
[[ -f "$icon" ]] || { echo "Uygulama simgesi yok: $icon" >&2; exit 1; }
app_name="$(basename "$app")"

work="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
staging="$work/staging"
writable="$work/writable.dmg"
device=""

# Hata olursa takılı kalan birim çıkarılır ve geçici dosyalar silinir; çıkarılamazsa bunu söyler (hata gizlenmez).
cleanup() {
    if [[ -n "$device" ]]; then
        hdiutil detach "$device" -force -quiet || echo "Uyarı: geçici birim çıkarılamadı: $device (elle: hdiutil detach $device -force)" >&2
    fi
    rm -rf "$work"
}
trap cleanup EXIT

# Hazırlık klasörü: uygulama, Uygulamalar kısayolu ve gizli arka plan klasörü.
mkdir -p "$staging/.background"
ditto "$app" "$staging/$app_name"
ln -s /Applications "$staging/Applications"
tiffutil -cathidpicheck "$background_dir/background.png" "$background_dir/background@2x.png" \
    -out "$staging/.background/background.tiff"

# Yazılabilir imaj: içerik + Finder'ın .DS_Store'u için pay.
size_mb=$(( $(du -sm "$staging" | cut -f1) + 20 ))
hdiutil create -volname "$volume_name" -srcfolder "$staging" -fs HFS+ -format UDRW -size "${size_mb}m" "$writable" -quiet

# Finder birimi görmeli (AppleScript ona adıyla ulaşır); bu yüzden -nobrowse kullanılmaz.
attach_output="$(hdiutil attach "$writable" -readwrite -noverify -noautoopen)"
device="$(printf '%s\n' "$attach_output" | awk -F'\t' '$3 ~ /^\/Volumes\// { sub(/[[:space:]]+$/, "", $1); print $1; exit }')"
mount_point="$(printf '%s\n' "$attach_output" | awk -F'\t' '$3 ~ /^\/Volumes\// { print $3; exit }')"
[[ -n "$device" && -n "$mount_point" ]] || { echo "Takılan birim bulunamadı. hdiutil çıktısı:" >&2; echo "$attach_output" >&2; exit 1; }
[[ "$mount_point" == "/Volumes/$volume_name" ]] || {
    echo "Birim beklenmeyen yere takıldı: $mount_point (beklenen /Volumes/$volume_name)" >&2
    exit 1
}

# Pencere düzeni: Finder ayarları .DS_Store'a yazar. close/open/close, ayarların diske yazılmasını sağlar.
osascript - "$volume_name" "$app_name" "$window_left" "$window_top" "$window_width" "$window_height" "$icon_size" \
    "$text_size" "$app_x" "$app_y" "$applications_x" "$applications_y" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    set appName to item 2 of argv
    set windowLeft to (item 3 of argv) as integer
    set windowTop to (item 4 of argv) as integer
    set windowWidth to (item 5 of argv) as integer
    set windowHeight to (item 6 of argv) as integer
    set iconSize to (item 7 of argv) as integer
    set textSize to (item 8 of argv) as integer
    set appX to (item 9 of argv) as integer
    set appY to (item 10 of argv) as integer
    set applicationsX to (item 11 of argv) as integer
    set applicationsY to (item 12 of argv) as integer
    tell application "Finder"
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set sidebar width of container window to 0
            set the bounds of container window to {windowLeft, windowTop, windowLeft + windowWidth, windowTop + windowHeight}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to iconSize
            set text size of viewOptions to textSize
            set label position of viewOptions to bottom
            set shows item info of viewOptions to false
            set shows icon preview of viewOptions to false
            set background picture of viewOptions to file ".background:background.tiff"
            set position of item appName of container window to {appX, appY}
            set position of item "Applications" of container window to {applicationsX, applicationsY}
            close
            open
            update without registering applications
            delay 2
            close
        end tell
    end tell
end run
APPLESCRIPT

# Finder .DS_Store'u gecikmeli yazabilir; düzen yazılmadan imaj kapatılmaz.
for _ in $(seq 1 20); do
    [[ -f "$mount_point/.DS_Store" ]] && break
    sleep 1
done
[[ -f "$mount_point/.DS_Store" ]] || { echo "Finder pencere düzenini yazmadı ($mount_point/.DS_Store yok)." >&2; exit 1; }

# Birim simgesi Finder'dan sonra kopyalanır: Finder pencere ayarlanırken kökteki .VolumeIcon.icns'i siliyor. Ardından
# özel simge bayrağı ve yardımcı dosyaların gizlenmesi (gizli dosyalar gösterilse bile).
cp "$icon" "$mount_point/.VolumeIcon.icns"
SetFile -a C "$mount_point"
# SetFile tek çağrıda birden çok dosyada ikinciyi bulamıyor (-43); her dosya ayrı işaretlenir.
SetFile -a V "$mount_point/.background"
SetFile -a V "$mount_point/.VolumeIcon.icns"
# `bless --openfolder` Apple Silicon'da desteklenmiyor; gerekmez de: salt okunur DMG çift tıklanınca Finder pencereyi
# kendiliğinden açar.
rm -rf "$mount_point/.fseventsd"
sync

# Çıkarma: Finder ya da Spotlight birimi kısa süre tutabilir; birkaç kez denenir, sonra son hatayla durulur.
detach_error=""
for attempt in 1 2 3 4 5; do
    if detach_error="$(hdiutil detach "$device" -quiet 2>&1)"; then
        device=""
        break
    fi
    echo "Uyarı: birim meşgul, çıkarma yeniden denenecek (deneme $attempt/5): $detach_error" >&2
    sleep 2
done
[[ -z "$device" ]] || { echo "Birim çıkarılamadı ($device): $detach_error" >&2; exit 1; }

# Sıkıştırılmış, salt okunur son imaj.
hdiutil convert "$writable" -format UDZO -imagekey zlib-level=9 -o "$dmg" -quiet
echo "DMG hazır: $dmg"
