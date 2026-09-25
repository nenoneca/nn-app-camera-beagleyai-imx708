#!/bin/bash
#
# Dev-drop installer for the BeagleY (byai) card — idempotent.
#
# Installs, side by side with what is already there:
#   * kernel 6.12.57-ti-arm64-r64bt (Image_612.gz + its own dtb/overlays)
#   * its modules
#   * the cc33xx 1.0.2.10 firmware pair, in a SEPARATE directory
#   * nn-setupd (BLE setup mode) + its systemd unit
#   * a NEW extlinux label; the existing default is left untouched
#
# Nothing here changes what the board boots by default.  Pick the new
# entry at the boot menu; if it misbehaves, power-cycle and take the old
# one.  Re-running is safe.
set -euo pipefail

SET_DEFAULT=0
SELFTEST=0
for a in "$@"; do
    case "$a" in
        --default) SET_DEFAULT=1 ;;
        --selftest) SELFTEST=1 ;;
        -h|--help)
            echo "usage: $0 [--default]"
            echo "  --default   also make the 6.12 entry the DEFAULT boot choice"
            echo "  --selftest  run the bring-up capture once, unattended, at next boot"
            exit 0 ;;
        *) echo "unknown option: $a" >&2; exit 2 ;;
    esac
done

SRC="$(cd "$(dirname "$0")" && pwd)"
BOOT=/boot/firmware
KREL=6.12.57-ti-arm64-r64bt
FWDIR=/lib/firmware/cc33xx-1.0.2.10
LABEL="microSD (6.12 r64bt)"

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -d "$BOOT/extlinux" ] || { echo "no $BOOT/extlinux — wrong board?" >&2; exit 1; }

say() { printf '==> %s\n' "$*"; }

say "kernel image + device tree"
install -m 0644 "$SRC/kernel/Image.gz"                        "$BOOT/Image_612.gz"
install -m 0644 -D "$SRC/kernel/ti/k3-am67a-beagley-ai.dtb"   "$BOOT/ti/k3-am67a-beagley-ai-612.dtb"
mkdir -p "$BOOT/overlays612"
install -m 0644 "$SRC"/kernel/overlays/*.dtbo                 "$BOOT/overlays612/"

say "modules -> /lib/modules/$KREL"
rm -rf "/lib/modules/$KREL"
cp -a "$SRC/kernel/modules-$KREL" "/lib/modules/$KREL"
# build/source are symlinks into the build host's tree; they dangle here and
# make depmod noisy.
rm -f "/lib/modules/$KREL/build" "/lib/modules/$KREL/source"
depmod -a "$KREL"

# The 1.0.2.10 pair (fw 1.7.0.323 + conf 1282) is what 6.12/btti_sdio needs.
# It must NOT replace the top-level firmware: the r72 kernel this card boots
# by default needs the OLD 1.7.0.130 pair, and mixing releases does not
# degrade gracefully -- it gives "FW is stuck, triggering recovery" and the
# radio dies completely, wifi included.  So install it in its own directory
# and point ONLY the 6.12 boot entry at it via firmware_class.path, which
# the kernel searches ahead of /lib/firmware.  The fallback entry keeps a
# working radio.
say "cc33xx 1.0.2.10 firmware -> $FWDIR (fallback firmware untouched)"
install -m 0644 -D "$SRC/fw/ti-connectivity/cc33xx_fw.bin"         "$FWDIR/ti-connectivity/cc33xx_fw.bin"
install -m 0644 -D "$SRC/fw/ti-connectivity/cc33xx-conf.bin"       "$FWDIR/ti-connectivity/cc33xx-conf.bin"
install -m 0644 -D "$SRC/fw/ti-connectivity/cc33xx_2nd_loader.bin" "$FWDIR/ti-connectivity/cc33xx_2nd_loader.bin"

say "bluetooth module policy"
# On 6.12 the cc33xx BT is on SDIO and generic btsdio will claim it if
# allowed, leaving hci0 dead with "Opcode 0x0c03 failed: -110".
# NB plain redirection, not `install -D /dev/stdin`: this script is also
# run OFFLINE inside an aarch64 chroot, where /dev may not be mounted and
# /dev/stdin would not resolve.
mkdir -p /etc/modprobe.d
cat > /etc/modprobe.d/nn-cc33xx-bt.conf <<'EOM'
# cc33xx BT must bind to TI's btti_sdio, never the generic btsdio.
blacklist btsdio
EOM
chmod 0644 /etc/modprobe.d/nn-cc33xx-bt.conf
# Harmless on the r72 kernel, which has no btti_sdio — systemd just logs
# that it could not load it.
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/nn-bt.conf <<'EOM'
btti_sdio
EOM
chmod 0644 /etc/modules-load.d/nn-bt.conf

say "nn-setupd + unit"
install -m 0755 -D "$SRC/bin/nn-setupd" /usr/local/sbin/nn-setupd
install -m 0644 -D "$SRC/systemd/nn-setupd.service" /etc/systemd/system/nn-setupd.service
# Tolerate a chroot where systemctl is shimmed or absent.
systemctl daemon-reload 2>/dev/null || say "systemctl unavailable (chroot?) — skipped daemon-reload"
# Deliberately NOT enabled here: the first boot of a new kernel should be
# about the kernel.  Enable when you want it: systemctl enable --now nn-setupd
say "nn-setupd installed but NOT enabled (systemctl enable --now nn-setupd)"

if [ "$SELFTEST" = 1 ]; then
    # Removes the console from the critical path: the board runs the whole
    # bring-up sequence itself at next boot and leaves the answers in
    # /var/log/nn-bringup.txt.  Nobody types anything, so dropped keystrokes,
    # a dead getty after logout and U-Boot menu capture all stop mattering.
    say "unattended bring-up capture (one shot at next boot)"
    install -m 0755 -D "$SRC/selftest/nn-bringup-capture.sh" /usr/sbin/nn-bringup-capture.sh
    install -m 0644 -D "$SRC/selftest/nn-bringup-capture.service" \
        /etc/systemd/system/nn-bringup-capture.service
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf ../nn-bringup-capture.service \
        /etc/systemd/system/multi-user.target.wants/nn-bringup-capture.service
    say "  -> results will be in /var/log/nn-bringup.txt (also echoed to console)"
fi

say "extlinux entry"
CONF="$BOOT/extlinux/extlinux.conf"
if grep -qF "label $LABEL" "$CONF"; then
    say "label already present — leaving extlinux.conf alone"
else
    cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d%H%M%S)"
    cat >> "$CONF" <<EOM

label $LABEL
    kernel /Image_612.gz
    append console=ttyS2,115200n8 root=/dev/mmcblk1p3 ro rootfstype=ext4 fsck.repair=yes resume=/dev/mmcblk1p2 rootwait net.ifnames=0 firmware_class.path=$FWDIR
    fdtdir /
    fdt /ti/k3-am67a-beagley-ai-612.dtb
    fdtoverlays /overlays612/k3-am67a-beagley-ai-edgeai-apps.dtbo /overlays612/k3-am67a-beagley-ai-uart-ttyama0.dtbo /overlays612/k3-am67a-beagley-ai-ncp-ctl-pins.dtbo
EOM
    say "appended '$LABEL' (default unchanged; backup taken)"
fi
# csi0-ov5647 is deliberately absent from that fdtoverlays line: it does not
# apply to the 6.12 dtb (FDT_ERR_NOTFOUND, verified with fdtoverlay) and
# would make the entry unbootable.

if [ "$SET_DEFAULT" = 1 ]; then
    if grep -qFx "default $LABEL" "$CONF"; then
        say "default is already '$LABEL'"
    else
        # Only rewrite the ONE `default` directive; the r72 labels stay in
        # the menu as fallback.  extlinux's `timeout` is deliberately left
        # alone: it is the only escape hatch if 6.12 does not come up, and
        # someone on the console can still pick a working entry.
        [ -f "$CONF.bak-predefault" ] || cp -a "$CONF" "$CONF.bak-predefault"
        sed -i -E "s|^default .*$|default $LABEL|" "$CONF"
        say "default is now '$LABEL' (r72 labels kept as fallback)"
    fi
    grep -E "^default " "$CONF" | sed 's/^/    /'
fi

sync
if [ "$SET_DEFAULT" = 1 ]; then
    # The previous kernel oopsed on every AF_ALG hash bind (TI SA2UL), and iwd
# binds one at startup — so on a card that has been through that, iwd may
# still be masked from the recovery.  Unmask it: THIS kernel has SA2UL
# disabled, so iwd is safe again.
if command -v systemctl >/dev/null 2>&1; then
    systemctl unmask iwd.service 2>/dev/null && say "iwd unmasked (SA2UL is off in this kernel)" || true
fi

say "done — board will boot '$LABEL' on its own"
else
    say "done — reboot and pick '$LABEL' at the boot menu"
fi
