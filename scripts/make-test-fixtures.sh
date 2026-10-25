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

# Çok konuşmacılı Fince diyalog: yüklü ilk üç fi_FI sesi sırayla konuşur.
FI_VOICES=()
while IFS= read -r voice; do FI_VOICES+=("$voice"); done < <(say -v '?' | sed -nE 's/^(.*[^ ]) +fi_FI .*/\1/p' | head -3)
if [ "${#FI_VOICES[@]}" -lt 3 ]; then
  echo "En az üç Fince (fi_FI) ses gerekli, bulunan: ${#FI_VOICES[@]}" >&2
  exit 1
fi
LINES=(
  "Hyvää huomenta, aloitetaan palaveri."
  "Kiitos. Minulla on raportti valmiina."
  "Hienoa, esitys on perjantaina."
  "Selvä, lähetän raportin huomenna."
)
SPEAKERS=(0 1 2 1)
PARTS=()
for i in "${!LINES[@]}"; do
  say -v "${FI_VOICES[${SPEAKERS[$i]}]}" -o "$TMP/dialog-$i.aiff" "${LINES[$i]} [[slnc 700]]"
  afconvert -f WAVE -d LEI16@16000 -c 1 "$TMP/dialog-$i.aiff" "$TMP/dialog-$i.wav"
  PARTS+=("$TMP/dialog-$i.wav")
done
swift "$(dirname "$0")/concat-wav.swift" "$FIXTURES/fi-dialog.wav" "${PARTS[@]}"
echo "$FIXTURES/fi-dialog.wav (sesler: ${FI_VOICES[*]})"
