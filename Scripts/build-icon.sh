#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source='Resources/Brand/JHCutStudio-icon-master.png'
iconset='Build/JHCutStudio.iconset'
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
  doubled=$((size * 2))
  sips -z "$doubled" "$doubled" "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Resources/JHCutStudio.icns
