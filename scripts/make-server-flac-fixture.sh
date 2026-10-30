#!/usr/bin/env bash
# Sunucu testlerinin FLAC örneğini (server/test/flacFixture.ts) üretir: Mac testlerinin konuşma kaydının
# (en-meeting.wav, 16 kHz mono 16 bit) ilk saniyesi, uygulamanın da kullandığı Apple FLAC kodlayıcısıyla (afconvert)
# kodlanır ve base64 olarak yazılır. Çıktı repoya eklenir; kodlayıcı sürümden sürüme farklı bayt üretebileceği için
# yeniden üretmek gerekmez.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Packages/AINotepadCore/Tests/AINotepadCoreTests/Fixtures/en-meeting.wav"
OUTPUT="$ROOT/server/test/flacFixture.ts"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# İlk 16000 örnek (1 sn): standart kitaplıktaki wave modülüyle kırpılır.
python3 -I - "$SOURCE" "$TMP/speech.wav" <<'PY'
import sys
import wave

with wave.open(sys.argv[1], "rb") as source:
    assert (source.getframerate(), source.getnchannels(), source.getsampwidth()) == (16000, 1, 2)
    frames = source.readframes(16000)
with wave.open(sys.argv[2], "wb") as target:
    target.setnchannels(1)
    target.setsampwidth(2)
    target.setframerate(16000)
    target.writeframes(frames)
PY
afconvert -f flac -d flac@16000 -c 1 "$TMP/speech.wav" "$TMP/speech.flac"

{
  echo "// scripts/make-server-flac-fixture.sh üretir; elle düzenlenmez."
  echo ""
  echo "/** Gerçek konuşmanın 1 saniyesi: Apple FLAC kodlayıcısıyla 16 kHz mono 16 bit, STREAMINFO'da 16000 örnek. */"
  echo "export const speechFlacBase64: string ="
  echo "  \"$(base64 -i "$TMP/speech.flac" | tr -d '\n')\";"
} > "$OUTPUT"
echo "$OUTPUT"
