#!/bin/bash
# Geliştirici sürümünün (AI-Notepad, şema AINotepad) dağıtım sürümü: Release'i Developer ID ile imzalar (hardened
# runtime, zaman damgası), DMG'ye koyar, Apple'a noter onayına (notarization) gönderir ve onayı DMG'ye ekler (staple).
# Çıktı: .build/release/AI-Notepad-<sürüm>.dmg. Abonelik sürümü (Gistsmith) için scripts/release-gistsmith.sh.
#
# Ardından Sparkle güncellemesini hazırlar: DMG'yi Sparkle'ın EdDSA anahtarıyla imzalar (hesap "ainotepad"), yerel
# release-archive/ klasöründe appcast.xml'i yeni sürümle günceller ve yayın deposunda (Config/Signing.xcconfig'teki
# RELEASES_REPO_AINOTEPAD) sürümü açacak `gh release create` komutunu yazar; komutu çalıştırmaz. Uygulamanın akışı aynı
# deponun releases/latest/download/appcast.xml adresidir (project.yml SUFeedURL).
#
# Kullanım:
#   scripts/release.sh <sürüm-notları.md>
# Her sürümden önce project.yml'de MARKETING_VERSION ve CURRENT_PROJECT_VERSION artırılır (Sparkle sürümleri
# CFBundleVersion ile karşılaştırır; tüm hedefler aynı değeri taşır). Sürüm notları Markdown'dır; appcast'e gömülür,
# Sparkle güncelleme penceresinde gösterir.
#
# Bir kerelik hazırlık (noter onayı profili, Sparkle araçları): bkz. scripts/release-common.sh. Sparkle anahtarı
# `generate_keys --account ainotepad`; açık anahtar Config/Signing.xcconfig'teki SPARKLE_PUBLIC_KEY'dir.
#
# release-archive/ (repoya girmez) appcast.xml'in yerel kopyasını tutar; silinmez, her sürüm üstüne eklenir. Başka bir
# Mac'ten yayınlarken önce yayımlanmış appcast indirilir:
#   mkdir -p release-archive && curl -sSfL -o release-archive/appcast.xml \
#       https://github.com/<RELEASES_REPO_AINOTEPAD>/releases/latest/download/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/release-common.sh

[[ $# -eq 1 ]] || { echo "Kullanım: scripts/release.sh <sürüm-notları.md>" >&2; exit 1; }
notes="$(release_notes_path "$1")"

# Sparkle gizli anahtarının Anahtar Zinciri hesabı (AI-Notepad'e özel).
sparkle_account="ainotepad"
sparkle_public_key="$(xcconfig_value SPARKLE_PUBLIC_KEY)"
repo="$(xcconfig_value RELEASES_REPO_AINOTEPAD)"
version="$(project_version)"
build="$(project_build)"
team="$(development_team)"
archive_dir="release-archive"
out=".build/release"
app="$out/export/AINotepad.app"
dmg="$out/AI-Notepad-$version.dmg"

# Uzun derlemeden önce: aynı derleme numarası appcast'te varsa güncelleme görünmez.
require_new_build "$archive_dir/appcast.xml" "$build"

xcodegen generate
rm -rf "$out"
archive_and_export AINotepad "$out/AINotepad.xcarchive" "$out/export" "$team"
sparkle_bin="$(sparkle_tools_dir)"
require_sparkle_keychain_key "$sparkle_bin" "$sparkle_account" "$sparkle_public_key"

verify_distribution_app "$app" "$sparkle_public_key"
# iCloud eşitlemesi Developer ID profilindeki iCloud yetkisini ister; profil uygulamaya gömülü olmalı.
[[ -f "$app/Contents/embedded.provisionprofile" ]] || { echo "Developer ID profili gömülü değil." >&2; exit 1; }
[[ "$(app_entitlements "$app")" == *"iCloud.com.senoldogan.AINotepad"* ]] || { echo "iCloud yetkisi eksik." >&2; exit 1; }
require_info_value "$app" CFBundleDisplayName "AI-Notepad"
require_info_value "$app" SUFeedURL "https://github.com/$repo/releases/latest/download/appcast.xml"

make_notarized_dmg "$app" "$dmg" "AI-Notepad $version" Config/DMG/AI-Notepad
sparkle_sign_dmg "$sparkle_bin" "$sparkle_account" "$dmg"
update_appcast "$sparkle_bin" "$sparkle_account" "$archive_dir" "$dmg" "$notes" "$repo" "$version" "$build"
print_release_command "$repo" "$version" "AI-Notepad $version" "$notes" "$dmg" "$out/AI-Notepad.dmg" "$archive_dir/appcast.xml"
