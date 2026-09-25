#!/bin/sh
# Post-image gate: refuse to ship an image the AM67A ROM cannot boot.
# $1 = BINARIES_DIR (Buildroot passes it first; any extra args are ignored).
set -e
BIN="$1"
CHK="$(dirname "$0")/check-boot-order.py"
for img in "$BIN/sdcard.img" "$BIN/boot.vfat"; do
    [ -f "$img" ] || continue
    echo "boot-order check: $(basename "$img")"
    python3 "$CHK" "$img"
done
