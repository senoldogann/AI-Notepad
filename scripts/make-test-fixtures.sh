#!/usr/bin/env bash
# Test seslerini macOS'un yerleşik sesleriyle üretir (16 kHz, mono, 16-bit WAV).
# Çıktılar repoya eklenir; sesler makineden makineye değişebildiği için yeniden üretmek gerekmez.
set -euo pipefail

FIXTURES="$(cd "$(dirname "$0")/.." && pwd)/Packages/AINotepadCore/Tests/AINotepadCoreTests/Fixtures"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

make_fixture() {
  local voice="$1" name="$2" text="$3"
  say -v "$voice" -o "$TMP/$name.aiff" "$text"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/$name.aiff" "$FIXTURES/$name.wav"
  echo "$FIXTURES/$name.wav"
}

make_fixture "Satu" "fi-meeting" \
  "Hyvää huomenta kaikille. [[slnc 900]] Seuraavalla viikolla meidän pitää palauttaa raportti. [[slnc 900]] Kuka voisi ottaa vastuun esityksestä?"
make_fixture "Samantha" "en-meeting" \
  "Good morning everyone. [[slnc 900]] Next week we need to submit the report. [[slnc 900]] Who could take responsibility for the presentation?"
