#!/bin/zsh
# Turns icon/AppIcon.png (1024 px, exported from the "Portly icon - real" frame in Figma)
# into icon/AppIcon.icns with every size macOS needs.
#   ./icon/make-icns.sh
set -euo pipefail
cd "$(dirname "$0")"

SET=AppIcon.iconset
rm -rf "$SET"
mkdir "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size AppIcon.png --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) AppIcon.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o AppIcon.icns
rm -rf "$SET"
echo "Wrote icon/AppIcon.icns"
