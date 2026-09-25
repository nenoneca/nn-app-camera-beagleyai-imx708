#!/bin/bash
#
# Build the BeagleY-AI cross toolchain once, as a Buildroot SDK tarball, so
# image builds use it prebuilt.  Rebuilding gcc, binutils and glibc from
# source cost about 8 minutes of every clean image build, for a toolchain
# that only changes with the Buildroot release.
#
#   ./packaging/build-toolchain.sh [outdir]   -> <outdir>/nn-byai-toolchain-<key>.tar.gz
#   ./packaging/build-toolchain.sh --key      -> prints <key> and exits
#
# <key> is br-common.sh's toolchain_key.  In CI, nn-byai-toolchain runs this
# and publishes the tarball to the artifact store as
# vendor/nn-byai-toolchain-<key>; nn-byai-image computes the same key and
# fetches it.  Locally, run this once before build-image.sh (default outdir
# is where build-image.sh looks).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$REPO/packaging/br2-external"
WORK="${NN_WORK:-$REPO/_build}"
JOBS="${NN_JOBS:-$(nproc)}"
# shellcheck source=br-common.sh
. "$REPO/packaging/br-common.sh"

KEY="$(toolchain_key "$EXT")"
if [ "${1:-}" = --key ]; then echo "$KEY"; exit 0; fi

OUT="${1:-$WORK/toolchain}"
NAME="nn-byai-toolchain-$KEY.tar.gz"
if [ -s "$OUT/$NAME" ]; then
    say "toolchain $KEY already built: $OUT/$NAME"
    exit 0
fi

mkdir -p "$WORK"
fetch_buildroot "$WORK/buildroot" "$EXT"

# Its own output dir, always from scratch: nothing from an image build may
# leak into the SDK, and a half-built earlier attempt must not either.
O="$WORK/toolchain-output"
rm -rf "$O"
say "configuring ($TOOLCHAIN_DEFCONFIG), key $KEY"
make -C "$WORK/buildroot" BR2_EXTERNAL="$EXT" O="$O" "$TOOLCHAIN_DEFCONFIG" >/dev/null
say "building the toolchain SDK (-j$JOBS)"
make -C "$WORK/buildroot" BR2_EXTERNAL="$EXT" O="$O" -j"$JOBS" sdk

SDK="$(ls "$O"/images/*_sdk-buildroot.tar.gz)"
mkdir -p "$OUT"
cp "$SDK" "$OUT/$NAME.tmp"
mv "$OUT/$NAME.tmp" "$OUT/$NAME"

cat <<EOM

=== toolchain done ===
  key       $KEY
  tarball   $OUT/$NAME
  size      $(stat -c%s "$OUT/$NAME") B
  sha256    $(sha256sum "$OUT/$NAME" | cut -d' ' -f1)
EOM
