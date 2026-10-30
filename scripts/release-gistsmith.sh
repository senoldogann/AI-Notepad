#!/bin/bash
# Abonelik sürümünün (Gistsmith, şema AINotepadHosted) dağıtım sürümü: çalışma ağacı temizse Gistsmith.app'i Release
# olarak Developer ID ile imzalar (hardened runtime, zaman damgası), uygulamayı noter onayına gönderip onayı uygulamaya
# ekler (staple), DMG'ye koyar (arka plan Config/DMG/Gistsmith), DMG'yi de onaylatıp onayı DMG'ye ekler. Çıktı:
# .build/release-gistsmith/Gistsmith-<sürüm>.dmg.
#
# Ardından Sparkle güncellemesini hazırlar: DMG'yi bu sürümün kendi Sparkle anahtarıyla imzalar (hesap "gistsmith";
# geliştirici sürümünün "ainotepad" anahtarından ayrı), yerel release-archive-gistsmith/ klasöründe kendi
# appcast.xml'ini günceller ve yalnızca sürümleri taşıyan herkese açık depoda (Config/Signing.xcconfig'teki
# RELEASES_REPO_GISTSMITH) sürümü açacak `gh release create` komutunu yazar; komutu çalıştırmaz. Varlıklar:
# Gistsmith-<sürüm>.dmg, sabit adlı Gistsmith.dmg (site releases/latest/download/Gistsmith.dmg adresinden indirir) ve
# appcast.xml (uygulama releases/latest/download/appcast.xml adresinden okur; project.yml SUFeedURL).
#
# Kullanım:
#   scripts/release-gistsmith.sh <sürüm-notları.md>
# Sürüm ve derleme numarası project.yml'den (tüm hedefler aynı); her sürümden önce artırılır.
#
# Bir kerelik hazırlık (noter onayı profili, Sparkle araçları): bkz. scripts/release-common.sh. Sparkle anahtarı
# `generate_keys --account gistsmith`; açık anahtar Config/Signing.xcconfig'teki SPARKLE_PUBLIC_KEY_GISTSMITH'tir.
#
# release-archive-gistsmith/ (repoya girmez) appcast.xml'in yerel kopyasını tutar; silinmez, her sürüm üstüne eklenir.
# Başka bir Mac'ten yayınlarken önce yayımlanmış appcast indirilir:
#   mkdir -p release-archive-gistsmith && curl -sSfL -o release-archive-gistsmith/appcast.xml \
#       https://github.com/<RELEASES_REPO_GISTSMITH>/releases/latest/download/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/release-common.sh

[[ $# -eq 1 ]] || { echo "Kullanım: scripts/release-gistsmith.sh <sürüm-notları.md>" >&2; exit 1; }
notes="$(release_notes_path "$1")"

# Sparkle gizli anahtarının Anahtar Zinciri hesabı (Gistsmith'e özel).
sparkle_account="gistsmith"
sparkle_public_key="$(xcconfig_value SPARKLE_PUBLIC_KEY_GISTSMITH)"
repo="$(xcconfig_value RELEASES_REPO_GISTSMITH)"
version="$(project_version)"
build="$(project_build)"
team="$(development_team)"
archive_dir="release-archive-gistsmith"
out=".build/release-gistsmith"
app="$out/export/Gistsmith.app"
dmg="$out/Gistsmith-$version.dmg"

# Uzun derlemeden önce: yayın yalnızca işlenmiş koddan; aynı derleme numarası appcast'te varsa güncelleme görünmez,
# aynı sürüm varsa indirme adresi ve yayın etiketi eski sürümle çakışır.
require_clean_worktree
require_new_build "$archive_dir/appcast.xml" "$build"
require_new_version "$archive_dir/appcast.xml" "$version"

xcodegen generate
rm -rf "$out"
archive_and_export AINotepadHosted "$out/Gistsmith.xcarchive" "$out/export" "$team"
sparkle_bin="$(sparkle_tools_dir)"
require_sparkle_keychain_key "$sparkle_bin" "$sparkle_account" "$sparkle_public_key"

verify_distribution_app "$app" "$sparkle_public_key"
# Apple ile giriş yetkisi olmamalı: Apple onu Developer ID profillerine vermez (dışa aktarım reddedilir); giriş tarayıcıda
# yapılır. İç kimlikler değişmez (izinler, Anahtar Zinciri ve veri klasörü paket kimliğine bağlı).
[[ "$(app_entitlements "$app")" != *"com.apple.developer.applesignin"* ]] || { echo "Apple ile giriş yetkisi Developer ID'de kullanılamaz." >&2; exit 1; }
require_info_value "$app" CFBundleIdentifier "com.senoldogan.AINotepad.hosted"
require_info_value "$app" CFBundleDisplayName "Gistsmith"
require_info_value "$app" HostedAPIBase "https://api.gistsmith.com"
require_info_value "$app" HostedSiteBase "https://gistsmith.com"
require_info_value "$app" SUFeedURL "https://github.com/$repo/releases/latest/download/appcast.xml"
# Abonelik sürümü iCloud kullanmaz (eşitleme kapalı); Release Anahtar Zinciri servisi ve veri klasörü yayındakiler.
require_no_icloud_entitlement "$app"
require_info_value "$app" HostedKeychainService "AINotepadHosted"
require_info_value "$app" AINotepadDataFolderName "AINotepad Hosted"
require_info_value "$app" CFBundleDevelopmentRegion "en"

notarize_app "$app"
make_notarized_dmg "$app" "$dmg" "Gistsmith $version" Config/DMG/Gistsmith
sparkle_sign_dmg "$sparkle_bin" "$sparkle_account" "$dmg"
update_appcast "$sparkle_bin" "$sparkle_account" "$archive_dir" "$dmg" "$notes" "$repo" "$version" "$build"
print_release_command "$repo" "$version" "Gistsmith $version" "$notes" "$dmg" "$out/Gistsmith.dmg" "$archive_dir/appcast.xml"
