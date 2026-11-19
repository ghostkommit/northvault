#!/usr/bin/env bash
# Run only after editing NorthvaultLogo.svg; generated assets are checked in.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
mkdir -p macos/build/ModuleCache macos/build/Northvault.iconset
xcrun swiftc -module-cache-path macos/build/ModuleCache scripts/render-logo.swift -o macos/build/render-logo
macos/build/render-logo macos/Northvault/Resources/NorthvaultLogo.svg macos/Northvault/Resources/NorthvaultLogo.png
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" macos/Northvault/Resources/NorthvaultLogo.png \
    --out "macos/build/Northvault.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" macos/Northvault/Resources/NorthvaultLogo.png \
    --out "macos/build/Northvault.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
# ICNS stores a sequence of typed PNG representations. This also works on
# Command Line Tools installations where iconutil rejects valid iconsets.
python3 - <<'PYICON'
from pathlib import Path
import struct
folder = Path("macos/build/Northvault.iconset")
representations = {
    "icp4": "16x16", "icp5": "32x32", "icp6": "32x32@2x",
    "ic07": "128x128", "ic08": "256x256", "ic09": "512x512", "ic10": "512x512@2x",
    "ic11": "16x16@2x", "ic12": "32x32@2x", "ic13": "128x128@2x", "ic14": "256x256@2x",
}
chunks = []
for kind, name in representations.items():
    png = (folder / ("icon_" + name + ".png")).read_bytes()
    chunks.append(kind.encode("ascii") + struct.pack(">I", len(png) + 8) + png)
data = b"".join(chunks)
Path("macos/Northvault/Resources/Northvault.icns").write_bytes(b"icns" + struct.pack(">I", len(data) + 8) + data)
PYICON
