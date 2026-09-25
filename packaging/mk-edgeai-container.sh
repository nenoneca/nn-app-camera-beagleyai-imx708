#!/bin/bash
#
# Build the trimmed TI edgeai container rootfs for the BeagleY camera.
#
#   ./packaging/mk-edgeai-container.sh <plat.ext4> [-o out.tar.xz] [-V 11.0.0]
#
# The TI platform rootfs is 2.7 GB; the camera pipeline needs about 65 MB of
# it.  This takes the ELF dependency closure of the pipeline (see
# edgeai-closure.py) and assembles just that, plus the ISP tuning data and
# enough scaffolding to be a container -- reading everything out of the ext4
# with debugfs, so it needs no root and never extracts /usr/lib (1.4 GB).
#
# WHAT IS DELIBERATELY NOT IN HERE
#   * the model.  Models are user-swappable and live on nn-data with their own
#     post-processing metadata (param.yaml), so a new detector is not a new
#     container.  Baking one in would make "swappable" a lie.
#   * the RTOS firmware.  Only the host kernel can load remoteproc firmware,
#     so that ships in the image -- which is why this records the SDK version:
#     firmware and libtivision_apps are ONE release and a mismatch does not
#     degrade, it wedges the object-descriptor table until a power cycle.
set -euo pipefail

IMG="${1:?usage: mk-edgeai-container.sh <plat.ext4> [-o out.tar.xz] [-V version]}"; shift
OUT=""; VER=""
while [ $# -gt 0 ]; do case "$1" in
    -o) OUT="$2"; shift 2;;
    -V) VER="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 2;;
esac; done

[ -f "$IMG" ] || { echo "no such image: $IMG" >&2; exit 2; }
command -v debugfs >/dev/null || { echo "need debugfs (e2fsprogs)" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
say() { printf '\n==> %s\n' "$*"; }

# The SDK version is not guessed: it is the soname of the library the firmware
# must match, read out of the image itself.
if [ -z "$VER" ]; then
    VER=$(debugfs -R "ls -l /usr/lib" "$IMG" 2>/dev/null \
          | sed -n 's/.*libtivision_apps\.so\.\([0-9.]*\).*/\1/p' | sort -u | tail -1)
fi
[ -n "$VER" ] || { echo "cannot determine the TI SDK version from $IMG" >&2; exit 3; }
say "TI vision-apps SDK $VER"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ROOTFS="$W/rootfs"; CACHE="$W/cache"
mkdir -p "$ROOTFS" "$CACHE"
OUT="${OUT:-ti-edgeai-rootfs-$VER.tar.xz}"

# ── the pipeline's linked closure ────────────────────────────────────────
# Roots are everything loaded by dlopen (GStreamer plugins, the TIDL delegate)
# plus the few binaries worth having on a camera that is misbehaving.  The
# closure tool follows DT_NEEDED from here; it CANNOT follow dlopen, so this
# list is the part a human has to get right.
say "ELF closure"
python3 "$HERE/edgeai-closure.py" --image "$IMG" --cache "$CACHE" --stage "$ROOTFS" \
    /usr/lib/gstreamer-1.0/libgsttiovx.so \
    /usr/lib/gstreamer-1.0/libgstvideo4linux2.so \
    /usr/lib/gstreamer-1.0/libgstvideoparsersbad.so \
    /usr/lib/gstreamer-1.0/libgstapp.so \
    /usr/lib/gstreamer-1.0/libgstcoreelements.so \
    /usr/lib/gstreamer-1.0/libgsttypefindfunctions.so \
    /usr/lib/gstreamer-1.0/libgstvideoconvertscale.so \
    /usr/lib/libonnxruntime.so \
    /usr/lib/libtidl_onnxrt_EP.so \
    /usr/bin/gst-inspect-1.0 \
    /usr/bin/gst-launch-1.0 \
    /usr/bin/busybox.nosuid \
    /usr/libexec/gstreamer-1.0/gst-plugin-scanner \
    /opt/vision_apps/vx_app_heap_stats.out \
    /usr/lib/libmbedcrypto.so.16 \
    /usr/lib/libvx_tidl_rt.so \
    | tail -1
# libvx_tidl_rt: the TIDL runtime over TIOVX.  The ONNX Runtime TIDL execution
# provider dlopen()s it by name -- it is not in the EP's DT_NEEDED, so no
# closure walk can find it.  Without it the EP constructor fails
# ("TidlExecutionProvider ... status == true was false") and the camera
# streams with "edge inference unavailable".  Found on hardware, 2026-09-17.
# libmbedcrypto: not part of the TI pipeline at all -- it is what OUR app
# links (nn_crypto: device identity, the sectun uplink).  nn-camera is built
# against this same Arago rootfs, so its runtime deps must be provided by
# this container; the first run on hardware died with
#     nn-camera: error while loading shared libraries: libmbedcrypto.so.16
# The self-check below cannot catch this because nn-camera is not in the
# tarball; the guard for it is nn-app-install, which refuses a bundle whose
# DT_NEEDED the installed container does not satisfy.

# ── ISP tuning ───────────────────────────────────────────────────────────
# tiovxisp will not start without a DCC file, and the file is per sensor.
# NOTE: there is no imx708 tuning in TI's set -- the deployed pipeline runs the
# IMX708 through the imx219 tables, which works but gets the colour wrong.
say "ISP tuning (/opt/imaging)"
debugfs -R "rdump /opt/imaging $ROOTFS/opt" "$IMG" 2>&1 | grep -v 'ownership' || true

# ── scaffolding ──────────────────────────────────────────────────────────
# Merged /usr, like the rootfs this came from: the binaries' PT_INTERP is
# /usr/lib/ld-linux-aarch64.so.1, but plenty of things still say /lib.
say "scaffolding"
mkdir -p "$ROOTFS"/{proc,sys,dev,tmp,run,etc,var/log,opt/nn}
ln -sfn usr/lib "$ROOTFS/lib"
ln -sfn usr/bin "$ROOTFS/bin"
ln -sfn usr/bin "$ROOTFS/sbin"
ln -sfn busybox.nosuid "$ROOTFS/usr/bin/sh"
# Every applet, not a hand-picked few.  busybox only answers to names it is
# linked as, and the first run on hardware died on "basename: not found" from
# a script that had no reason to expect a rootfs without basename.  The list
# comes from the binary itself, run under qemu-user, so it cannot drift from
# what the busybox in the tarball actually implements.
if command -v qemu-aarch64-static >/dev/null; then
    # -L: busybox is dynamically linked, so qemu-user needs the container as
    # its sysroot to find ld-linux; without it qemu exits 255 and set -e
    # killed the build with no message at all.
    applets=$(qemu-aarch64-static -L "$ROOTFS" "$ROOTFS/usr/bin/busybox.nosuid" --list 2>/dev/null)
else
    echo "WARNING: no qemu-aarch64-static -- linking a minimal applet set only" >&2
    applets="ls cat ps kill pgrep killall sleep mkdir rm mount env basename readlink"
fi
for t in $applets; do
    [ "$t" = sh ] && continue
    ln -sfn busybox.nosuid "$ROOTFS/usr/bin/$t"
done
echo "  busybox: $(echo "$applets" | wc -w) applets linked"
chmod 1777 "$ROOTFS/tmp"
printf 'root:x:0:0:root:/:/bin/sh\n' > "$ROOTFS/etc/passwd"
printf 'root:x:0:\n'                 > "$ROOTFS/etc/group"
printf 'nameserver 127.0.0.1\n'      > "$ROOTFS/etc/resolv.conf"

# The marker the host is checked against before anything is started.
echo "$VER" > "$ROOTFS/etc/nn-ti-vision-apps-version"

# ── self-check ───────────────────────────────────────────────────────────
# Every DT_NEEDED of every ELF in here must resolve INSIDE here.  The closure
# walker already believes that, but it reasons about the source rootfs; this
# checks the thing we are actually shipping, after staging renamed files to
# their sonames and after anything else touched the tree.  A container that
# fails this does not fail at build time -- it fails when the camera starts.
say "self-check: the container resolves its own libraries"
python3 - "$ROOTFS" <<'PY' || { echo "FATAL: container is not self-contained" >&2; exit 4; }
import os, subprocess, sys
root = sys.argv[1]
have = set()
for d, _, fs in os.walk(root):
    have.update(fs)
    have.update(os.listdir(d))
missing, n = {}, 0
for d, _, fs in os.walk(root):
    for f in fs:
        p = os.path.join(d, f)
        if os.path.islink(p):
            continue
        with open(p, "rb") as fh:
            if fh.read(4) != b"\x7fELF":
                continue
        n += 1
        out = subprocess.run(["readelf", "-d", p], capture_output=True, text=True).stdout
        for line in out.splitlines():
            if "(NEEDED)" in line:
                lib = line.split("[")[1].split("]")[0]
                if lib not in have:
                    missing.setdefault(lib, []).append(f)
print("  %d ELF files checked" % n)
for lib, users in sorted(missing.items()):
    print("  MISSING %-34s needed by %s" % (lib, ", ".join(users[:3])))
sys.exit(1 if missing else 0)
PY

# ── package ──────────────────────────────────────────────────────────────
say "packing $OUT"
tar -C "$ROOTFS" --numeric-owner --owner=0 --group=0 -cf - . | xz -T0 -6 > "$OUT"
printf '  %s\n  %s bytes, sha256 %s\n' "$OUT" "$(wc -c < "$OUT")" \
    "$(sha256sum "$OUT" | cut -c1-16)…"
printf '  contents: %s files, %s uncompressed\n' \
    "$(find "$ROOTFS" -type f | wc -l)" "$(du -sh "$ROOTFS" | cut -f1)"
