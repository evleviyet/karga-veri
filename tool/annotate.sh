#!/usr/bin/env bash
# Feed çıktısını GitHub Actions uyarı notlarına (annotations) özetler; notlar
# çalıştırma sayfasında ve API'de herkese açık görünür.
#   tool/annotate.sh <site-klasörü> <başlık>
set -euo pipefail
dir="$1"; title="$2"
meta="$dir/data/v2/meta.json"
ok=$(jq '[.sources[] | select(.status=="ok")] | length' "$meta")
total=$(jq '.sources | length' "$meta")
records=$(jq '[.sources[].count] | add' "$meta")
files=$(ls "$dir"/data/v2/il/*.json | wc -l)
valid=0
for f in "$dir"/data/v2/il/*.json; do
  if jq -e '.schema == 2 and (.notices | type == "array") and (.sources | type == "array")' "$f" >/dev/null; then
    valid=$((valid + 1))
  fi
done
live=$(jq -r '.kapsam.canliKurumlar | join(" ")' "$meta")
echo "::notice title=$title::$ok/$total kaynak okundu · il dosyası $valid/$files geçerli · $records kayıt · canlı kurumlar: $live"
mapfile -t bad < <(jq -r '.sources | to_entries[] | select(.value.status != "ok") | "\(.value.name) (\(.key)): \(.value.error // "hata")"' "$meta")
for line in "${bad[@]:0:9}"; do
  line="${line//%/}"
  echo "::warning title=Okunamayan kaynak::${line//$'\r'/}"
done
if [ "${#bad[@]}" -gt 9 ]; then echo "::warning title=Okunamayan kaynak::… ve $((${#bad[@]} - 9)) kaynak daha"; fi
# 81 il dosyasının hepsi üretilmiş ve geçerli olmalı.
if [ "$valid" -ne 81 ]; then echo "::error title=İl dosyaları::81 yerine $valid geçerli il dosyası"; exit 1; fi
