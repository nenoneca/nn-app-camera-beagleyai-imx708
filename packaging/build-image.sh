#!/bin/bash
#
# Build the BeagleY-AI (byai) SD-card image from a clean checkout.
#
#   ./packaging/build-image.sh
#   -> <work>/output/images/sdcard.img, <work>/byai_sdcard-<ver>.img.xz and
#      <work>/byai_system-<ver>.rootfs.ext4.xz (the ab-v1 OTA artifact), each
#      with a <name>.manifest.json
#
# Everything host-specific is fetched or passed in; nothing here depends on
# a path that happens to exist on one machine.
#
# Inputs it fetches itself:
#   * Buildroot, at the pinned tag, plus our uboot.mk backport
#   * the TI vendor kernel, shallow-fetched BY COMMIT (no 3 GB clone)
#   * nn-setupd's source: this repo, resolved from the script's own location
#
# Inputs it CANNOT fetch:
#   * the TI cc33xx firmware.  Those are vendor blobs, not redistributable,
#     and pinning them to a scraped URL is how a build breaks silently a year
#     later.  Provide them via NN_FW_DIR (in CI: from the artifact store).
#   * the prebuilt cross toolchain, from build-toolchain.sh, named by its key.
#     NN_TOOLCHAIN_DIR holds it (default: where build-toolchain.sh puts it;
#     in CI: fetched from the artifact store by key).
set -euo pipefail

K_URL=https://github.com/beagleboard/linux.git
K_COMMIT=2eea568f445af33f3280261904bf1027b02512d8
K_NAME=linux-6.12.57-ti-arm64-r64bt
DEFCONFIG=nn_beagley_ai_612bt_defconfig
VERSION="${NN_IMAGE_VERSION:-$(date -u +%Y%m%d)}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$REPO/packaging/br2-external"
WORK="${NN_WORK:-$REPO/_build}"
JOBS="${NN_JOBS:-$(nproc)}"
FW_DIR="${NN_FW_DIR:-}"
# shellcheck source=br-common.sh
. "$REPO/packaging/br-common.sh"

# ── prerequisites ────────────────────────────────────────────────────────
# Buildroot's own mandatory set plus what THIS config needs.  NOT dtc:
# Buildroot builds host-dtc itself (BR2_TARGET_UBOOT_NEEDS_DTC), so
# requiring device-tree-compiler on the builder would be a dependency we
# do not actually use.
for t in git make gcc g++ bison flex bc gawk perl patch which sed \
         unzip rsync cpio file wget python3 xz tar gzip bzip2; do
    command -v "$t" >/dev/null || die "missing tool: $t"
done
[ -f /usr/include/openssl/ssl.h ] || die "missing libssl-dev (kernel + u-boot need it)"
[ -f /usr/include/ncurses.h ] || [ -f /usr/include/ncursesw/ncurses.h ] \
    || die "missing libncurses-dev"

# ── vendor firmware: the one thing we cannot fetch ───────────────────────
FW_FILES="cc33xx_fw.bin cc33xx-conf.bin cc33xx_2nd_loader.bin"
[ -n "$FW_DIR" ] || die "set NN_FW_DIR to a directory holding: $FW_FILES
  These are TI cc33xx vendor blobs (release 1.0.2.10: fw 1.7.0.323 + conf 1282).
  fw and conf are a MATCHED PAIR -- mixing releases does not degrade, it kills
  the radio outright. In CI, pull them from the artifact store."
for f in $FW_FILES; do
    [ -f "$FW_DIR/$f" ] || die "NN_FW_DIR is missing $f"
done

# The TI RTOS firmware the camera path runs on: the VPAC ISP is driven from
# the main R5F and the DL accelerators are the two C7x DSPs, all loaded by the
# host kernel's remoteproc from /lib/firmware under the names the device tree
# asks for.  They are a MATCHED PAIR with the TIOVX userspace in the container
# (libtivision_apps): mixing SDK releases does not degrade, it desynchronises
# the shared object descriptors and the pipeline wedges in a way only a power
# cycle clears.  So the version is explicit here and recorded in the image.
TI_FW_VERSION="${NN_TI_FW_VERSION:-11.0.0}"
TI_FW_FILES="j722s-main-r5f0_0-fw j722s-c71_0-fw j722s-c71_1-fw"
TI_FW_DIR="${NN_TI_FW_DIR:-}"
[ -n "$TI_FW_DIR" ] || die "set NN_TI_FW_DIR to a directory holding: $TI_FW_FILES
  These are TI vision-apps RTOS firmware blobs from Processor SDK
  $TI_FW_VERSION (libtivision_apps.so.$TI_FW_VERSION).  In CI, pull them from
  the artifact store: nn-fetch-vendor ti-vision-apps-$TI_FW_VERSION <dir>."
for f in $TI_FW_FILES; do
    [ -f "$TI_FW_DIR/$f" ] || die "NN_TI_FW_DIR is missing $f"
done

# ── prebuilt cross toolchain: found by key, never rebuilt here ───────────
# The defconfig names it as file://$(NN_TOOLCHAIN_TARBALL).  No fallback to
# an internal toolchain: that would hide a stale or missing key behind an
# extra hour and a quietly different compiler.
TC_KEY="$(toolchain_key "$EXT")"
TC_DIR="${NN_TOOLCHAIN_DIR:-$WORK/toolchain}"
export NN_TOOLCHAIN_TARBALL="$(cd "$(dirname "$TC_DIR")" 2>/dev/null && pwd)/$(basename "$TC_DIR")/nn-byai-toolchain-$TC_KEY.tar.gz"
[ -s "$NN_TOOLCHAIN_TARBALL" ] || die "no prebuilt toolchain for key $TC_KEY at
  $NN_TOOLCHAIN_TARBALL
  Build it once with ./packaging/build-toolchain.sh (same NN_WORK), or in CI
  run nn-byai-toolchain, which publishes it for this key."
say "toolchain $TC_KEY: $NN_TOOLCHAIN_TARBALL"

# No host paths in the defconfig.  A literal /media/... or file:/// makes the
# build succeed on the machine where that path happens to exist and fail
# everywhere else -- and it fails LATE, after the toolchain and u-boot, so it
# costs an hour to discover.  Cheap to check, expensive to miss.
DC="$EXT/configs/$DEFCONFIG"
[ -f "$DC" ] || die "defconfig not found: $DC"
if grep -nE '"(file://)?/(media|home|tmp|Users)/' "$DC"; then
    die "the lines above hardcode a host path in $DEFCONFIG.
  Use \$(BR2_EXTERNAL_NN_PATH) instead -- Buildroot expands it in .config values."
fi

# nn-setupd is built with SITE_METHOD=local from the REPO ROOT, so anything
# under the repo is inside Buildroot's rsync source.  A work dir in there
# recurses into itself unless the package excludes it.  Belt and braces:
# check the exclusion is present rather than trusting it stayed.
case "$(cd "$(dirname "$WORK")" 2>/dev/null && pwd)/$(basename "$WORK")" in
    "$REPO"/*)
        grep -q 'NN_SETUPD_OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS' \
             "$EXT/package/nn-setupd/nn-setupd.mk" \
          || die "NN_WORK ($WORK) is inside the repo, and nn-setupd.mk has no
  OVERRIDE_SRCDIR_RSYNC_EXCLUSIONS -- Buildroot would rsync the work dir into
  itself recursively.  Set NN_WORK outside the repo, or restore the exclusions."
        ;;
esac

mkdir -p "$WORK"

# ── Buildroot ────────────────────────────────────────────────────────────
BR="$WORK/buildroot"
fetch_buildroot "$BR" "$EXT"

# ── vendor kernel -> tarball ─────────────────────────────────────────────
# A tarball, not a git package: Buildroot's git downloader needs to walk
# parents, and we only ever want one commit's tree.
TARBALL="$EXT/dl/$K_NAME.tar"
if [ ! -s "$TARBALL" ]; then
    say "fetching the vendor kernel at $K_COMMIT (shallow, by commit)"
    KSRC="${NN_KERNEL_MIRROR:-}"
    KDIR="$WORK/kernel"
    if [ -n "$KSRC" ]; then
        [ -d "$KDIR/.git" ] || git clone -q --no-checkout "$KSRC" "$KDIR"
    else
        mkdir -p "$KDIR"
        [ -d "$KDIR/.git" ] || ( cd "$KDIR" && git init -q . && git remote add origin "$K_URL" )
        ( cd "$KDIR" && git fetch -q --depth 1 origin "$K_COMMIT" )
    fi
    mkdir -p "$(dirname "$TARBALL")"
    say "exporting $K_NAME.tar"
    ( cd "$KDIR" && git archive --format=tar --prefix="$K_NAME/" "$K_COMMIT" ) > "$TARBALL.tmp"
    mv "$TARBALL.tmp" "$TARBALL"
else
    say "kernel tarball already present"
fi

# ── vendor firmware into the board dir ───────────────────────────────────
say "staging cc33xx firmware from $FW_DIR"
mkdir -p "$EXT/board/nn/beagley-ai-612bt/fw"
for f in $FW_FILES; do
    install -m 0644 "$FW_DIR/$f" "$EXT/board/nn/beagley-ai-612bt/fw/$f"
done

say "staging TI vision-apps firmware $TI_FW_VERSION from $TI_FW_DIR"
mkdir -p "$EXT/board/nn/beagley-ai-612bt/fw/ti"
for f in $TI_FW_FILES; do
    install -m 0644 "$TI_FW_DIR/$f" "$EXT/board/nn/beagley-ai-612bt/fw/ti/$f"
done
# The image records which SDK these came from, so the container bundle's TI
# userspace can be checked against it rather than assumed to match.
echo "$TI_FW_VERSION" > "$EXT/board/nn/beagley-ai-612bt/fw/ti/VERSION"

# ── build ────────────────────────────────────────────────────────────────
O="$WORK/output"
say "configuring ($DEFCONFIG)"
make -C "$BR" BR2_EXTERNAL="$EXT" O="$O" "$DEFCONFIG" >/dev/null

# Fail loudly rather than shipping a silently wrong image.
grep -q '^BR2_PACKAGE_NN_SETUPD=y'   "$O/.config" || die "nn-setupd not enabled"
grep -q '^BR2_TOOLCHAIN_USES_GLIBC=y' "$O/.config" || die "glibc was dropped (headers cascade?)"
grep -q '^BR2_PACKAGE_LXC=y'          "$O/.config" || die "lxc was dropped"

say "building (-j$JOBS) — this takes a while"
# post-build writes it into the rootfs (/etc/nn-system-version): the image, the
# OTA artifact cut from the same rootfs and the running system agree on it.
export NN_IMAGE_VERSION="$VERSION"
make -C "$BR" BR2_EXTERNAL="$EXT" O="$O" -j"$JOBS"

IMG="$O/images/sdcard.img"
[ -s "$IMG" ] || die "no sdcard.img produced"

# ── package ──────────────────────────────────────────────────────────────
# Two artifacts of ONE rootfs, each with its own manifest named after it (a
# bare manifest.json would be overwritten by nn-publish's build metadata):
#   byai_sdcard-VER.img.xz         the whole card, for the Factory
#   byai_system-VER.rootfs.ext4.xz one root slot, for the ab-v1 system OTA
say "compressing"
OUTX="$WORK/byai_sdcard-$VERSION.img.xz"
RAW_SIZE=$(stat -L -c%s "$IMG"); RAW_SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
xz -T0 -c "$IMG" > "$OUTX"
SIZE=$(stat -c%s "$OUTX");   SHA=$(sha256sum "$OUTX" | cut -d' ' -f1)
rm -f "$WORK/manifest.json"
cat > "$WORK/byai_sdcard-$VERSION.manifest.json" <<EOM
{
  "device_type": "byai_sdcard",
  "version": "$VERSION",
  "format": "sdcard.img.xz",
  "sha256": "$SHA",
  "size_bytes": $SIZE,
  "raw_sha256": "$RAW_SHA",
  "raw_size_bytes": $RAW_SIZE
}
EOM

# rootfs.ext4 is a SYMLINK to rootfs.ext2: sizes must follow it (stat -L), or
# raw_size_bytes becomes the length of the link name (11) and the board refuses.
SYS="$O/images/rootfs.ext4"
SYSX="$WORK/byai_system-$VERSION.rootfs.ext4.xz"
# The slot must say what it is: the agent refuses a slot whose
# /etc/nn-system-version is not the version it was asked to install.
GOT=$("$O/host/sbin/debugfs" -R 'cat /etc/nn-system-version' "$SYS" 2>/dev/null | tr -d '\n')
[ "$GOT" = "$VERSION" ] || die "rootfs.ext4 says version '$GOT', building '$VERSION'"
S_RAW_SIZE=$(stat -L -c%s "$SYS"); S_RAW_SHA=$(sha256sum "$SYS" | cut -d' ' -f1)
xz -T0 -c "$SYS" > "$SYSX"
S_SIZE=$(stat -c%s "$SYSX");    S_SHA=$(sha256sum "$SYSX" | cut -d' ' -f1)
# the digests the board will check, checked here first, on the bytes that ship
[ "$(xz -dc "$SYSX" | sha256sum | cut -d' ' -f1)" = "$S_RAW_SHA" ] \
    || die "byai_system artifact does not decompress to the rootfs it was cut from"
# and the sizes in both manifests are what the files really decompress to
for pair in "$OUTX:$RAW_SIZE" "$SYSX:$S_RAW_SIZE"; do
    f=${pair%:*}; want=${pair##*:}
    got=$(xz --robot -l "$f" | awk '$1 == "totals" {print $5}')
    [ "$got" = "$want" ] || die "$(basename "$f") decompresses to $got bytes, manifest would say $want"
done
BOOT_CHAIN=$(sed -n 's/^BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE="\(.*\)"$/\1/p' "$O/.config")
KREL=$(cat "$O/build/linux-custom/include/config/kernel.release")
KCFG=$(sha256sum "$O/build/linux-custom/.config" | cut -c1-12)
GIT=$(git -C "$REPO" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)
cat > "$WORK/byai_system-$VERSION.manifest.json" <<EOM
{
  "device_type": "byai_system",
  "version": "$VERSION",
  "format": "rootfs.ext4.xz",
  "sha256": "$S_SHA",
  "size_bytes": $S_SIZE,
  "raw_sha256": "$S_RAW_SHA",
  "raw_size_bytes": $S_RAW_SIZE,
  "requires": {"layout": "ab-v1", "boot_chain_min": "$BOOT_CHAIN"},
  "kernel": "$KREL config:$KCFG",
  "git": "$GIT"
}
EOM

cat <<EOM

=== done ===
  image     $OUTX
  system    $SYSX
  manifests $WORK/byai_sdcard-$VERSION.manifest.json
            $WORK/byai_system-$VERSION.manifest.json
  raw       $IMG
  sha256    $SHA
EOM
