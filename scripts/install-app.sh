#!/bin/bash
# AI-Notepad'i Release olarak derleyip /Applications/AINotepad.app'e kurar.
# Kalıcı yer ve geliştirici sertifikası imzası: macOS izinleri (mikrofon, sistem sesi) imzaya bağlıdır; geçici
# (ad-hoc) imzalı ya da her derlemede başka yerden açılan kopyada izinler kalıcı olmaz, her açılışta yeniden sorulur.
# iCloud yetkisi profil ister: Xcode'un otomatik imzalaması profili gerekirse geliştirici hesabından alır.
set -euo pipefail
cd "$(dirname "$0")/.."

# Yalnız Mac uygulamasının arayüz süreci aranır: iPhone simülatöründeki uygulamanın süreç adı da AINotepad, aynı
# ikilinin `--mcp` ile açılan yerel MCP sunucusu (Claude Desktop vb. başlatır) ise kurulumu engellemez.
if pgrep -lf "AINotepad\.app/Contents/MacOS/AINotepad" | grep -v -e "--mcp" >/dev/null; then
    echo "AI-Notepad açık: önce menüden çık (kayıt sürüyorsa bitmesini bekle), sonra yeniden çalıştır." >&2
    exit 1
fi

# En son toplantı kayıtta ya da işlemedeyse kurulmaz (yerel ve iCloud klasörleri; yalnızca okunur, uygulama kapatılmaz).
# Uygulama kapalıyken bu durum, yarıda kalmış bir toplantı demektir: uygulamayı açınca "yarıda kaldı" olarak kapanır.
latest="$(python3 -I - "$HOME/Library/Application Support/AINotepad/Sessions" \
    "$HOME/Library/Mobile Documents/iCloud~com~senoldogan~AINotepad/Documents/Sessions" <<'PY'
import json
import pathlib
import sys

meetings = []
for root in sys.argv[1:]:
    folder = pathlib.Path(root)
    if not folder.is_dir():
        continue
    for path in folder.glob("*/meeting.json"):
        record = json.loads(path.read_text(encoding="utf-8"))
        meetings.append((record["startedAt"], record["status"], str(path)))
if meetings:
    started, status, path = max(meetings)
    print(f"{status}\t{path}")
PY
)"
latest_status="${latest%%$'\t'*}"
if [[ "$latest_status" == "recording" || "$latest_status" == "processing" ]]; then
    echo "En son toplantının durumu '$latest_status' (${latest#*$'\t'}): bitmesini bekle, sonra yeniden çalıştır." >&2
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
