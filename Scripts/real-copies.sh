#!/bin/bash
# Makes read-only copies of the supplied iPhone videos and verifies the originals are unchanged.
# Usage: Scripts/real-copies.sh [copy|verify]
set -euo pipefail
cd "$(dirname "$0")/.."
src="${JHCUT_IPHONE_DIR:-/Volumes/T7/아이폰/동영상}"
dst="Artifacts/Upgrade-0.7/RealCopies"
names=(IMG_0140.mov IMG_0047.mov IMG_9211.mov)
mkdir -p "$dst"
fingerprint() { for f in "${names[@]}"; do stat -f "%N %z %m" "$src/$f"; shasum -a 256 "$src/$f" | sed "s#$src/##"; done; }
case "${1:-copy}" in
  copy)
    [[ -f "$dst/originals-before.txt" ]] || (cd "$src" && for f in "${names[@]}"; do stat -f "%N %z %m" "$f"; shasum -a 256 "$f"; done) > "$dst/originals-before.txt"
    for f in "${names[@]}"; do
      if [[ ! -f "$dst/$f" ]]; then cp "$src/$f" "$dst/$f"; chmod a-w "$dst/$f"; fi
    done
    echo "copies ready in $dst" ;;
  verify)
    (cd "$src" && for f in "${names[@]}"; do stat -f "%N %z %m" "$f"; shasum -a 256 "$f"; done) > "$dst/originals-after.txt"
    if diff -q "$dst/originals-before.txt" "$dst/originals-after.txt" >/dev/null; then echo "ORIGINALS_UNCHANGED size+mtime+sha256 identical"; else echo "ORIGINALS_CHANGED"; diff "$dst/originals-before.txt" "$dst/originals-after.txt"; exit 1; fi
    for f in "${names[@]}"; do
      a=$(grep "  $f\$" "$dst/originals-before.txt" | cut -d' ' -f1); b=$(shasum -a 256 "$dst/$f" | cut -d' ' -f1)
      [[ "$a" == "$b" ]] && echo "copy $f matches original" || { echo "copy $f differs"; exit 1; }
    done ;;
esac
