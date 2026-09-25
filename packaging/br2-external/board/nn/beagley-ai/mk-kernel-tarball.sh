#!/bin/sh
# Export the TI vendor kernel commit as a tarball for BR2_LINUX_KERNEL_CUSTOM_TARBALL.
# The mirror is a shallow clone, which Buildroot's git downloader cannot use
# (it needs to traverse parents); git archive only needs the tree.
set -e
K=${K:-/media/chalos/mx500/beagley-image-build/from-source/work/kernel}
C=ac5c6fe561c328dc989be8c9e45c31ad775abba9      # tag 6.1.83-ti-arm64-r72
OUT=${OUT:-/media/chalos/mx500/beagley-image-build/br2-nn/dl}
mkdir -p "$OUT"
cd "$K"
git archive --format=tar --prefix=linux-6.1.83-ti-arm64-r72/ "$C" \
    > "$OUT/linux-6.1.83-ti-arm64-r72.tar"
echo "wrote $OUT/linux-6.1.83-ti-arm64-r72.tar"
