#!/bin/sh
# Inter Variable'ı site için küçültür: yalnızca Latin, Latin Genişletilmiş-A (Türkçe ve Fince harfler), noktalama ve
# sitede geçen birkaç simge; ağırlık ve optik boyut eksenleri korunur. Çıktı repoya girer, derleme bunu çalıştırmaz.
# Gerekenler: fonttools ve brotli (ör. `python3 -m venv /tmp/ft && /tmp/ft/bin/pip install fonttools brotli`).
# Kullanım: scripts/subset-font.sh /tmp/ft/bin/pyftsubset
set -eu

pyftsubset="$1"
web_dir="$(cd "$(dirname "$0")/.." && pwd)"

"$pyftsubset" "$web_dir/../App/Fonts/InterVariable.ttf" \
  --output-file="$web_dir/public/fonts/InterVariable-latin.woff2" \
  --flavor=woff2 \
  --unicodes="U+0000-00FF,U+0100-017F,U+0131,U+0152-0153,U+02C6,U+02DA,U+02DC,U+2000-206F,U+20AC,U+20BA,U+2122,U+2190-2193,U+2212,U+2215,U+2713" \
  --layout-features+="tnum,case,cv11,ss03" \
  --no-hinting \
  --desubroutinize

echo "Yazıldı: $web_dir/public/fonts/InterVariable-latin.woff2"
