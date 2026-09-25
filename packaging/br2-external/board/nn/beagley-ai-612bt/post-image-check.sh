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

# Services must be ENABLED, not merely installed — checked HERE and not in
# post-build, because systemd's enable symlinks are created during image
# assembly in a staging copy, so TARGET_DIR does not have them yet.  The
# rootfs.tar is the first place the truth exists.
#
# Why it is worth a build failure: iwd is D-Bus ACTIVATED, so an un-enabled
# iwd.service does not error — it never starts on its own and then
# associates the moment any process first speaks to it over D-Bus.  On the
# bench that read as a radio taking 8-17 minutes to associate; it was
# waiting to be poked, and journalctl -u iwd was simply empty.  nn-setupd
# has the mirror failure: a fresh card has no other route onto the network,
# so present-but-not-enabled means it never advertises and no wizard ever
# sees it.
TAR="$BIN/rootfs.tar"
if [ -f "$TAR" ]; then
    for u in iwd nn-setupd bluetooth nn-cc33xx-ble nn-camera nn-npu; do
        # "if installed, must be enabled" — units this image does not ship
        # (nn-camera/nn-npu live in the container bundle) are skipped.
        tar tf "$TAR" 2>/dev/null | grep -qE "systemd/system/$u\.service$" || continue
        if tar tf "$TAR" 2>/dev/null | grep -qE "\.target\.wants/$u\.service$"; then
            echo "  enabled: $u.service"
        else
            echo "FATAL: $u.service is installed but NOT enabled — it would never" >&2
            echo "       start on its own." >&2
            exit 1
        fi
    done
fi

# --- Guards added after E2E run 1 (2026-09-14) ---------------------------
# Each of these shipped in a GREEN build and was found only on hardware.
# Buildroot exports BUILD_DIR and BR2_CONFIG to post-image scripts.

# T0-BOOT-01: the boot container carries every firmware payload.  An optional
# binman entry that packs EMPTY is a signed stub with no payload (~1.7 KB, a
# TI x509 certificate and nothing else).  OP-TEE shipped exactly like that and
# the R5 SPL then failed authentication on the board.
DI=$(ls "$BUILD_DIR"/uboot-*/tools/dumpimage 2>/dev/null | head -1)
if [ -f "$BIN/tispl.bin" ]; then
    [ -x "$DI" ] || { echo "FATAL: no dumpimage to inspect tispl.bin" >&2; exit 1; }
    echo "tispl.bin images:"
    "$DI" -l "$BIN/tispl.bin" | awk '
        /^ Image [0-9]+ \(/ { name = $3 }
        /Data Size:/        { size = $3; printf "  %-10s %9d B\n", name, size
                              if (size < 4096) bad = bad " " name }
        END { if (bad != "") { print "FATAL: empty payload in tispl.bin:" bad > "/dev/stderr"; exit 1 } }'
    if grep -q '^BR2_TARGET_OPTEE_OS=y' "$BR2_CONFIG"; then
        tee_sz=$("$DI" -l "$BIN/tispl.bin" | awk '/^ Image [0-9]+ \(tee\)/{f=1} f && /Data Size:/{print $3; exit}')
        if [ -z "$tee_sz" ] || [ "$tee_sz" -lt 65536 ]; then
            echo "FATAL: OP-TEE is enabled but the packed tee entry is ${tee_sz:-absent} B." >&2
            echo "       Pass the raw tee-pager_v2.bin to U-Boot, never tee.elf." >&2
            exit 1
        fi
    fi
fi

# T0-BOOT-02: every module the image loads at boot is in the module index.
# The kernel compressed modules with xz while kmod (host and target) had no
# xz support, so depmod indexed nothing: modules.dep was EMPTY against 2,967
# modules, no driver ever loaded, and both radios were silently missing.
# Merged /usr: /lib is a symlink, so the index lives under ./usr/lib/modules.
# A modules-load.d entry may name a module that is BUILT IN (systemd just
# logs "is builtin"), so an entry is fine if it is in modules.dep OR in
# modules.builtin; module names may differ only by '-' vs '_'.
if [ -f "$TAR" ]; then
    DEP=$(tar tf "$TAR" | grep -E '^\./(usr/)?lib/modules/[^/]+/modules\.dep$' | head -1)
    [ -n "$DEP" ] || { echo "FATAL: no modules.dep in the rootfs" >&2; exit 1; }
    BLT="${DEP%modules.dep}modules.builtin"
    n=$(tar xOf "$TAR" "$DEP" | grep -c . || true)
    nko=$(tar tf "$TAR" | grep -cE '^\./(usr/)?lib/modules/.*\.ko(\.[a-z]+)?$' || true)
    echo "module index: $n entries for $nko module files"
    if [ "$n" -eq 0 ] || [ "$n" -lt "$nko" ]; then
        echo "FATAL: depmod indexed $n of $nko modules — kmod cannot read the" >&2
        echo "       module format (compressed modules without matching kmod support)." >&2
        exit 1
    fi
    IDX=$(mktemp)
    { tar xOf "$TAR" "$DEP"; tar xOf "$TAR" "$BLT" 2>/dev/null; } | tr '-' '_' > "$IDX"
    for conf in $(tar tf "$TAR" | grep -E '^\./(etc|usr/lib)/modules-load\.d/.+\.conf$'); do
        for m in $(tar xOf "$TAR" "$conf" | sed 's/#.*//' | tr -s ' \t' '\n' | sed '/^$/d' | tr '-' '_'); do
            grep -qE "/${m}\.ko(\.[a-z]+)?(:|$)" "$IDX" || {
                rm -f "$IDX"
                echo "FATAL: $m is in ${conf#./} but neither indexed nor built in" >&2; exit 1; }
        done
    done
    rm -f "$IDX"
fi

# The watchdog systemd pets must be able to recover a hang.  softdog built in
# registers first as watchdog0 and takes that job from the RTI hardware;
# a panic then hung the board for over half an hour.
KCFG=$(ls "$BUILD_DIR"/linux-*/.config 2>/dev/null | head -1)
if [ -f "$KCFG" ]; then
    if grep -q '^CONFIG_SOFT_WATCHDOG=y' "$KCFG"; then
        echo "FATAL: CONFIG_SOFT_WATCHDOG=y — it becomes watchdog0 and systemd pets" >&2
        echo "       it instead of the K3 RTI hardware watchdog." >&2
        exit 1
    fi
    if grep -q '^CONFIG_PANIC_TIMEOUT=0$' "$KCFG"; then
        echo "FATAL: CONFIG_PANIC_TIMEOUT=0 — a panic would halt the board forever." >&2
        exit 1
    fi
    # A hang must become a panic (and so a reboot) wherever the kernel can see
    # it; the RTI is only the backstop for what it cannot (every CPU frozen).
    # The detectors alone only log: without their *_PANIC options a stuck CPU
    # or a task wedged in D state prints a warning and the board stays hung.
    for opt in K3_RTI_WATCHDOG PANIC_ON_OOPS BOOTPARAM_SOFTLOCKUP_PANIC \
               HARDLOCKUP_DETECTOR BOOTPARAM_HARDLOCKUP_PANIC BOOTPARAM_HUNG_TASK_PANIC; do
        grep -q "^CONFIG_$opt=y" "$KCFG" || {
            echo "FATAL: CONFIG_$opt is not =y — that class of hang would not reboot the board." >&2
            exit 1; }
    done
fi
# ...and something must pet the RTI, or it never arms: systemd, via a
# non-zero RuntimeWatchdogSec in the image.
WDCONF=$(tar -xOf "$BIN/rootfs.tar" --wildcards './etc/systemd/system.conf.d/*.conf' 2>/dev/null |
         sed -n 's/^RuntimeWatchdogSec=//p' | tail -1)
case "$WDCONF" in
    ''|0|off|infinity)
        echo "FATAL: RuntimeWatchdogSec='$WDCONF' in system.conf.d — nothing arms the hardware watchdog." >&2
        exit 1 ;;
    *)  echo "hardware watchdog: RuntimeWatchdogSec=$WDCONF" ;;
esac
# The stall detector that fires first must panic too (post-build step 10).
tar -xOf "$BIN/rootfs.tar" ./etc/sysctl.d/10-nn-hang.conf 2>/dev/null \
    | grep -qx 'kernel.panic_on_rcu_stall=1' || {
    echo "FATAL: kernel.panic_on_rcu_stall=1 missing — an RCU stall would only warn." >&2
    exit 1; }
# The uplink watchdog is a timer, which the service loop above does not cover:
# installed but not enabled, a camera that loses Wi-Fi stays lost.
tar tf "$BIN/rootfs.tar" | grep -qE '\.target\.wants/nn-netwatch\.timer$' || {
    echo "FATAL: nn-netwatch.timer is not enabled — a lost uplink would never be recovered." >&2
    exit 1; }
echo "  enabled: nn-netwatch.timer; kernel.panic_on_rcu_stall=1"

# --- Layout ab-v1 (whole-system A/B OTA) ----------------------------------
# A wrong layout does not fail at build or at boot; it fails at the first OTA
# in the field, when there is no card reader in reach.  Check every piece the
# agent and U-Boot's nn_boot rely on.
UCFG=$(ls "$BUILD_DIR"/uboot-*/.config 2>/dev/null | head -1)
[ -f "$UCFG" ] || { echo "FATAL: no U-Boot .config to check" >&2; exit 1; }
for want in CONFIG_ENV_IS_IN_MMC=y CONFIG_ENV_REDUNDANT=y CONFIG_ENV_MMC_DEVICE_INDEX=1 \
            CONFIG_ENV_OFFSET=0x100000 CONFIG_ENV_OFFSET_REDUND=0x140000 CONFIG_ENV_SIZE=0x40000 \
            CONFIG_BOOTCOUNT_LIMIT=y CONFIG_BOOTCOUNT_ENV=y CONFIG_BOOTCOUNT_BOOTLIMIT=3 \
            'CONFIG_BOOTCOMMAND="run nn_boot"' 'CONFIG_BOOTCOUNT_ALTBOOTCMD="run nn_rollback_boot"' CONFIG_CMD_SYSBOOT=y; do
    grep -qxF "$want" "$UCFG" || {
        echo "FATAL: U-Boot .config lacks $want -- fragment symbol renamed or not applied?" >&2; exit 1; }
done
grep -qx 'CONFIG_ENV_IS_NOWHERE=y' "$UCFG" && { echo "FATAL: U-Boot env is still NOWHERE" >&2; exit 1; }
# Design layer 3: the RTI is armed on trial boots only -- the driver and the
# command must be in, and AUTOSTART (default y) must be off or every boot
# would run with U-Boot's watchdog and its timeout.
for want in CONFIG_WDT=y CONFIG_WDT_K3_RTI=y CONFIG_CMD_WDT=y; do
    grep -qxF "$want" "$UCFG" || { echo "FATAL: U-Boot .config lacks $want (trial watchdog)" >&2; exit 1; }
done
grep -qx 'CONFIG_WATCHDOG_AUTOSTART=y' "$UCFG" && { echo "FATAL: WATCHDOG_AUTOSTART=y -- U-Boot would arm the RTI on every boot" >&2; exit 1; }
# ...and U-Boot may bind ONLY main_rti0: initr_watchdog probes every watchdog
# node, and probing the per-core RTIs main_rti1..3 left cores 1-3 unable to
# come online -- the board ran single-core (2026-09-16).
UDTB=$(ls "$BUILD_DIR"/uboot-*/dts/upstream/src/arm64/ti/k3-am67a-beagley-ai.dtb 2>/dev/null | head -1)
[ -f "$UDTB" ] || { echo "FATAL: U-Boot's k3-am67a-beagley-ai.dtb not found" >&2; exit 1; }
for n in e010000 e020000 e030000 e0f0000; do
    [ "$("$HOST_DIR/bin/fdtget" "$UDTB" /bus@f0000/watchdog@$n status 2>/dev/null)" = disabled ] || {
        echo "FATAL: U-Boot DT has watchdog@$n enabled -- probing it stops a CPU from coming online" >&2; exit 1; }
done

# The card: MBR signature, the four partitions, env pair clear of p1, and an
# env with a valid CRC holding the slot logic at both offsets.
python3 - "$BIN/sdcard.img" "$UCFG" <<'PY' || exit 1
import struct, sys, zlib, re
img, ucfg = sys.argv[1:3]
cfg = open(ucfg).read()
def hexcfg(name): return int(re.search(r'^CONFIG_%s=(0x[0-9a-fA-F]+)$' % name, cfg, re.M).group(1), 16)
env_off, env_red, env_size = hexcfg("ENV_OFFSET"), hexcfg("ENV_OFFSET_REDUND"), hexcfg("ENV_SIZE")
with open(img, "rb") as f:
    mbr = f.read(512)
    def fail(msg): print("FATAL: " + msg, file=sys.stderr); sys.exit(1)
    if mbr[510:512] != b"\x55\xaa": fail("sdcard.img has no MBR")
    sig = struct.unpack_from("<I", mbr, 440)[0]
    if sig != 0x6e6e6279: fail("MBR disk signature is 0x%08x, not 0x6e6e6279 (PARTUUIDs would change)" % sig)
    parts = []
    for i in range(4):
        e = mbr[446 + 16 * i: 462 + 16 * i]
        parts.append((e[0], e[4], struct.unpack_from("<I", e, 8)[0], struct.unpack_from("<I", e, 12)[0]))
    boot, ra, rb, data = parts
    if boot[1] != 0x0c or boot[0] != 0x80: fail("p1 is not a bootable FAT32-LBA partition: %r" % (boot,))
    for n, p in (("rootfs_a", ra), ("rootfs_b", rb), ("nn-data", data)):
        if p[1] != 0x83 or p[3] == 0: fail("%s is not a Linux partition: %r" % (n, p))
    if ra[3] != rb[3]: fail("the two root slots differ in size: %d vs %d sectors" % (ra[3], rb[3]))
    if max(env_off, env_red) + env_size > boot[2] * 512:
        fail("U-Boot env (ends 0x%x) overlaps p1 (starts 0x%x)" % (max(env_off, env_red) + env_size, boot[2] * 512))
    for off in (env_off, env_red):
        f.seek(off); blob = f.read(env_size)
        crc, data_ = struct.unpack_from("<I", blob, 0)[0], blob[5:]   # redundant format: crc, flag, data
        if zlib.crc32(data_) & 0xffffffff != crc: fail("env at 0x%x has a bad CRC" % off)
        env = dict(kv.split(b"=", 1) for kv in data_.split(b"\0") if b"=" in kv)
        keys = [kv.split(b"=", 1)[0] for kv in data_.split(b"\0") if b"=" in kv]
        # only the keys the slot logic lives on: TI's own env already repeats
        # some (loadaddr), and there the last one wins by design
        ours = (b"bootcmd", b"altbootcmd", b"bootlimit", b"bootcount", b"upgrade_available",
                b"nn_slot", b"nn_slot_try", b"nn_boot", b"nn_rollback_boot", b"nn_rollback")
        dup = sorted({k for k in keys if k in ours and keys.count(k) > 1})
        if dup: fail("env at 0x%x defines %s more than once" % (off, b", ".join(dup).decode()))
        for k, v in ((b"bootcmd", b"run nn_boot"), (b"nn_slot", b"a"),
                     (b"altbootcmd", b"run nn_rollback_boot")):
            if env.get(k) != v: fail("env at 0x%x: %s=%r" % (off, k.decode(), env.get(k)))
        if b"wdt start ${nn_trial_wdt_ms}" not in env.get(b"nn_boot", b""): fail("nn_boot does not arm the trial watchdog")
        for k in (b"nn_boot", b"nn_rollback_boot", b"nn_conf_addr", b"nn_trial_wdt", b"nn_trial_wdt_ms"):
            if k not in env: fail("env at 0x%x has no %s" % (off, k.decode()))
        # scriptaddr is 0x80000000 = TF-A's load address here: sysboot there
        # aborts and the board reset-loops (image N, 2026-09-15)
        if b"scriptaddr" in env[b"nn_boot"]: fail("nn_boot loads extlinux.conf at ${scriptaddr}")
        if int(env[b"nn_conf_addr"], 16) < 0x81000000: fail("nn_conf_addr %s is inside the TF-A region" % env[b"nn_conf_addr"].decode())
print("  layout ab-v1: MBR 6e6e6279, p1 @%d MiB, slots %d MiB, env x2 CRC ok" % (boot[2] // 2048, ra[3] // 2048))
PY

# The system in slot a: its own kernel, dtb and boot entry; identity; tools.
tar -tf "$TAR" > "$BIN/.rootfs.lst"
for f in ./boot/Image ./boot/ti/k3-am67a-beagley-ai.dtb ./boot/extlinux/extlinux.conf \
         ./etc/nn-layout ./etc/nn-system-version ./etc/fw_env.config ./usr/sbin/nn-sysupd \
         ./usr/sbin/nn-growdata ./usr/lib/systemd/system/nn-data-init.service; do
    grep -qxF "$f" "$BIN/.rootfs.lst" || { echo "FATAL: rootfs lacks $f" >&2; exit 1; }
done
for tool in e2fsck resize2fs sfdisk blkid blockdev findmnt ionice partx fw_printenv fw_setenv xz curl; do
    grep -qE "^\./(usr/)?s?bin/$tool\$" "$BIN/.rootfs.lst" || {
        echo "FATAL: rootfs lacks $tool -- the OTA agent (or nn-growdata) needs it" >&2; exit 1; }
done
for u in nn-sysupd.timer nn-growdata.service; do
    grep -qE "\.target\.wants/$u\$" "$BIN/.rootfs.lst" || { echo "FATAL: $u is not enabled" >&2; exit 1; }
done
rm -f "$BIN/.rootfs.lst"
tar -xOf "$TAR" ./etc/nn-layout | grep -qx ab-v1 || { echo "FATAL: /etc/nn-layout is not ab-v1" >&2; exit 1; }
tar -xOf "$TAR" ./boot/extlinux/extlinux.conf | grep -q 'root=PARTUUID=6e6e6279-02 ' \
    || { echo "FATAL: extlinux.conf does not boot slot a by PARTUUID" >&2; exit 1; }
[ "$(tar -xOf "$TAR" ./etc/machine-id | wc -c)" -eq 0 ] \
    || { echo "FATAL: /etc/machine-id is not empty -- every card would share one id" >&2; exit 1; }
tar -xOf "$TAR" ./etc/fstab | grep -q '^LABEL=nn-data ' || { echo "FATAL: fstab does not mount nn-data" >&2; exit 1; }
# The boot FAT is the boot chain only, plus the version the agent gates on.
MDIR=$(ls "$HOST_DIR"/bin/mdir 2>/dev/null | head -1)
if [ -x "$MDIR" ]; then
    FATLS=$(MTOOLS_SKIP_CHECK=1 "$MDIR" -b -i "$BIN/boot.vfat" ::/ 2>/dev/null)
    echo "$FATLS" | grep -qi 'nn-boot-chain' || { echo "FATAL: boot.vfat has no nn-boot-chain" >&2; exit 1; }
    echo "$FATLS" | grep -qiE '/(image|extlinux)$' && { echo "FATAL: boot.vfat still carries a kernel or extlinux" >&2; exit 1; }
fi
# Design layers 1, 2 and 4: a trial that never reaches the agent must still
# end in a reboot the boot count sees.
EXT=$(tar -xOf "$TAR" ./boot/extlinux/extlinux.conf)
for want in ' init=/sbin/init' ' watchdog.open_timeout=120'; do
    echo "$EXT" | grep -q -- "$want" || { echo "FATAL: extlinux.conf lacks$want" >&2; exit 1; }
done
tar -tf "$TAR" | grep -qE '\.target\.wants/nn-trial-guard\.timer$' || { echo "FATAL: nn-trial-guard.timer not enabled" >&2; exit 1; }
tar -tvf "$TAR" ./etc/systemd/system/systemd-networkd-wait-online.service 2>/dev/null | grep -q -- '-> /dev/null' \
    || { echo "FATAL: systemd-networkd-wait-online is not masked -- every network-online unit waits 2 min for eth0" >&2; exit 1; }
tar -tf "$TAR" | grep -qE 'network-online\.target\.wants/nn-wait-uplink\.service$' || { echo "FATAL: nn-wait-uplink not enabled" >&2; exit 1; }
echo "  system: kernel+dtb+extlinux in /boot, nn-sysupd + tools, nn-data in fstab, machine-id empty"
[ "$(tar -xOf "$TAR" ./etc/nn-sysupd/expect-cpus 2>/dev/null)" = 4 ] \
    || { echo "FATAL: /etc/nn-sysupd/expect-cpus is not 4 -- a trial that lost cores would confirm" >&2; exit 1; }
echo "  trial safety: init=/sbin/init, watchdog.open_timeout=120, nn-trial-guard, wait-online -> nn-wait-uplink, expect-cpus=4"

# --- Camera stack (2026-09-16) -------------------------------------------
# The failure this guards against is specific and silent.  An overlay that
# names a label the base dtb does not export is not an error anyone sees:
# U-Boot prints one line, skips the overlay and boots normally, and the
# board comes up with no sensor, no /dev/video for the CSI bridge, and a
# camera app that sits at frames=0 looking like a network problem.  That is
# how the ov5647 overlay failed on this board, and our IMX708 overlay was
# carrying the same two labels (main_i2c2_pins_default, csi0_gpio_pins_default)
# -- which exist in TI's device tree but NOT in the BeagleBoard.org one we
# build.  So: actually apply the overlay here, with the same libfdt U-Boot
# uses, and fail the build if it does not take.
DTBO=./boot/ti/k3-am67a-beagley-ai-csi0-imx708.dtbo
VDTBO=./boot/ti/k3-am67a-beagley-ai-vision-apps.dtbo
tar -tf "$TAR" > "$BIN/.camchk.lst"
for o in "$DTBO" "$VDTBO"; do
    grep -qxF "$o" "$BIN/.camchk.lst" || { echo "FATAL: rootfs lacks $o" >&2; exit 1; }
done
echo "$EXT" | grep -q "fdtoverlays .*/boot/ti/k3-am67a-beagley-ai-csi0-imx708.dtbo" \
    || { echo "FATAL: extlinux.conf does not apply the IMX708 overlay" >&2; exit 1; }
echo "$EXT" | grep -q "fdtoverlays .*/boot/ti/k3-am67a-beagley-ai-vision-apps.dtbo" \
    || { echo "FATAL: extlinux.conf does not apply the vision-apps overlay -- the RTOS" >&2
         echo "       firmware would fail to load ('bad phdr da 0xb1100000')." >&2; exit 1; }

FDTOVERLAY=$(command -v "$HOST_DIR/bin/fdtoverlay" || command -v fdtoverlay || true)
DTC=$(command -v "$HOST_DIR/bin/dtc" || command -v dtc || true)
if [ -n "$FDTOVERLAY" ] && [ -n "$DTC" ]; then
    CAMTMP="$BIN/.camchk"
    rm -rf "$CAMTMP"; mkdir -p "$CAMTMP"
    tar -xOf "$TAR" ./boot/ti/k3-am67a-beagley-ai.dtb > "$CAMTMP/base.dtb"
    tar -xOf "$TAR" "$DTBO" > "$CAMTMP/imx708.dtbo"
    tar -xOf "$TAR" "$VDTBO" > "$CAMTMP/vision-apps.dtbo"
    # -@ must have reached dtc, or there is nothing for the overlay to bind to.
    "$DTC" -I dtb -O dts "$CAMTMP/base.dtb" 2>/dev/null | grep -q '__symbols__' \
        || { echo "FATAL: base dtb has no __symbols__ -- BR2_LINUX_KERNEL_DTB_OVERLAY_SUPPORT is off," >&2
             echo "       so U-Boot can resolve no label and every overlay is silently skipped." >&2
             rm -rf "$CAMTMP"; exit 1; }
    # The sensor must NOT already be there: otherwise a no-op overlay passes
    # the check below without ever having applied.
    "$DTC" -I dtb -O dts "$CAMTMP/base.dtb" 2>/dev/null | grep -q 'sony,imx708' \
        && { echo "FATAL: base dtb already has the sensor -- this check proves nothing" >&2
             rm -rf "$CAMTMP"; exit 1; }
    # Apply BOTH, in the order extlinux.conf names them -- the same thing
    # U-Boot does, one after the other onto the same working fdt.
    "$FDTOVERLAY" -i "$CAMTMP/base.dtb" -o "$CAMTMP/merged.dtb" \
         "$CAMTMP/imx708.dtbo" "$CAMTMP/vision-apps.dtbo" 2>"$CAMTMP/err" \
        || { echo "FATAL: the camera overlays do not apply to this dtb:" >&2
             sed 's/^/       /' "$CAMTMP/err" >&2
             echo "       U-Boot would skip them and the board would boot with no camera." >&2
             rm -rf "$CAMTMP"; exit 1; }
    "$DTC" -I dtb -O dts "$CAMTMP/merged.dtb" 2>/dev/null > "$CAMTMP/merged.dts"
    grep -q 'sony,imx708' "$CAMTMP/merged.dts" \
        || { echo "FATAL: overlay applied but the merged dtb has no sony,imx708 node" >&2
             rm -rf "$CAMTMP"; exit 1; }
    for want in 'inclk' 'reset-gpios' 'link-frequencies'; do
        grep -q "$want" "$CAMTMP/merged.dts" \
            || { echo "FATAL: merged dtb lacks $want on the sensor" >&2; rm -rf "$CAMTMP"; exit 1; }
    done
    # The vision-apps memory map.  Without it the shipped RTOS firmware does
    # not load -- "bad phdr da 0xb1100000 mem 0x8c / Failed to load program
    # segments: -22" -- because its ELF segments are linked at addresses the
    # default ti-ipc carveouts do not reserve.  Checking the exact address the
    # firmware asks for is the check that would have caught it.
    "$DTC" -I dtb -O dts "$CAMTMP/base.dtb" 2>/dev/null | grep -q 'vision-apps' \
        && { echo "FATAL: base dtb already has the vision-apps map -- this proves nothing" >&2
             rm -rf "$CAMTMP"; exit 1; }
    grep -qE 'reg = <0x0*0 0xb1100000 ' "$CAMTMP/merged.dts" \
        || { echo "FATAL: no reserved region at 0xb1100000 -- j722s-c71_1-fw would fail to load" >&2
             rm -rf "$CAMTMP"; exit 1; }
    grep -qE 'reg = <0x0*0 0xad100000 ' "$CAMTMP/merged.dts" \
        || { echo "FATAL: no reserved region at 0xad100000 -- j722s-c71_0-fw would fail to load" >&2
             rm -rf "$CAMTMP"; exit 1; }
    # ...and the defaults they replace must actually be off, or the addresses
    # are claimed twice and the kernel keeps the first.
    ndis=$(awk '/reserved-memory \{/,/^\t\};/' "$CAMTMP/merged.dts" | grep -c 'status = "disabled"')
    [ "${ndis:-0}" -eq 9 ] \
        || { echo "FATAL: $ndis of the 9 default ti-ipc carveouts are disabled" >&2
             rm -rf "$CAMTMP"; exit 1; }
    # The remoteproc firmware we ship must be named what the device tree asks
    # for.  remoteproc takes firmware-name straight from the DT, so a rename
    # on either side is not an error at boot -- the core simply never starts,
    # and the ISP the camera depends on is quietly absent.
    for fw in j722s-main-r5f0_0-fw j722s-c71_0-fw j722s-c71_1-fw; do
        grep -q "firmware-name = \"$fw\"" "$CAMTMP/merged.dts" \
            || { echo "FATAL: no device-tree node asks for $fw -- shipping it is pointless" >&2
                 rm -rf "$CAMTMP"; exit 1; }
        # Merged /usr: /lib is a symlink, so the files are under ./usr/lib.
        grep -qE "^\./(usr/)?lib/firmware/$fw\$" "$BIN/.camchk.lst" \
            || { echo "FATAL: the device tree asks for $fw but the rootfs does not have it" >&2
                 rm -rf "$CAMTMP"; exit 1; }
    done
    rm -rf "$CAMTMP"
    echo "  camera dt: overlay applies to the base dtb, sensor node present"
    echo "  camera fw: R5F + 2x C7x firmware present under the names the dtb asks for"
else
    echo "FATAL: no fdtoverlay/dtc on the host -- cannot prove the overlay applies" >&2
    exit 1
fi

# The drivers the capture path is made of.  Each is a module here, so a
# config that quietly dropped one shows up as a missing .ko, not as a boot
# failure -- and then as frames=0 at runtime.
for ko in imx708 cdns-csi2rx j721e-csi2rx wave5; do
    grep -qE "/$ko\.ko(\.[a-z]+)?\$" "$BIN/.camchk.lst" \
        || { echo "FATAL: rootfs lacks the $ko module -- the camera path is incomplete" >&2; exit 1; }
done
# WAVE5 refuses to probe without its firmware, so an image without it has an
# encoder that never appears rather than one that encodes badly.
grep -qE '^\./(usr/)?lib/firmware/cnm/wave521c_k3_codec_fw\.bin$' "$BIN/.camchk.lst" \
    || { echo "FATAL: rootfs lacks cnm/wave521c_k3_codec_fw.bin -- the H.264 encoder will not probe" >&2; exit 1; }
# media-ctl/v4l2-ctl: cam_run.sh sets every pad by hand and cannot without
# them.  nn-camcheck: the bring-up check belongs on the board, since every
# question it asks has a failure mode that is silent at runtime.
for tool in media-ctl v4l2-ctl nn-camcheck nn-edgeai-install nn-edgeai-start nn-app-install nn-cam-setup nn-provisioned nn-camera-stopped nn-rproc-ready nn-appupd lxc-start lxc-attach; do
    grep -qE "^\./(usr/)?s?bin/$tool\$" "$BIN/.camchk.lst" \
        || { echo "FATAL: rootfs lacks $tool -- the camera stack cannot be set up or diagnosed" >&2; exit 1; }
done
# The TIOVX firmware above and the container's libtivision_apps are a matched
# pair; record which SDK, so the bundle side can check rather than assume.
TIVER=$(tar -xOf "$TAR" ./etc/nn-ti-vision-apps-version 2>/dev/null | tr -d '[:space:]')
[ -n "$TIVER" ] || { echo "FATAL: /etc/nn-ti-vision-apps-version is missing or empty --" >&2
                     echo "       nothing could tell a mismatched container bundle from a good one." >&2
                     exit 1; }
grep -qxF './usr/share/nn/edgeai-lxc.conf' "$BIN/.camchk.lst" \
    || { echo "FATAL: rootfs lacks the edgeai LXC config" >&2; exit 1; }
# The container unit must be enabled but must NOT fail on a camera that has no
# container installed yet -- hence ConditionPathExists rather than leaving it
# disabled.  A unit that fails at every boot trains people to ignore units.
grep -qE '\.target\.wants/nn-edgeai\.service$' "$BIN/.camchk.lst" \
    || { echo "FATAL: nn-edgeai.service is not enabled" >&2; exit 1; }
tar -xOf "$TAR" ./usr/lib/systemd/system/nn-edgeai.service 2>/dev/null \
    | grep -q '^ConditionPathExists=/opt/nn-app/edgeai/rootfs$' \
    || { echo "FATAL: nn-edgeai.service has no ConditionPathExists -- it would fail" >&2
         echo "       at every boot on a camera with no container installed." >&2; exit 1; }
rm -f "$BIN/.camchk.lst"
echo "  camera: imx708 + csi2rx + wave5 modules, cnm firmware, media-ctl/v4l2-ctl, TI SDK $TIVER"
# The lifecycle's last link: setup mode ending provisioned must start the
# camera, or a BLE-provisioned board stays silent until a power cycle.
tar -xOf "$TAR" ./etc/systemd/system/nn-setupd.service.d/30-start-camera.conf 2>/dev/null \
    | grep -q 'start nn-camera.service' \
    || { echo "FATAL: nn-setupd does not start nn-camera after provisioning" >&2; exit 1; }
tar -xOf "$TAR" ./usr/lib/systemd/system/nn-camera.service 2>/dev/null | grep -q '^ExecCondition=/usr/sbin/nn-provisioned$' \
    || { echo "FATAL: nn-camera.service lacks ExecCondition -- an unprovisioned board would burn its StartLimit" >&2; exit 1; }
echo "  container: nn-edgeai-install/start + LXC config, unit enabled and condition-guarded"
tar -xOf "$TAR" ./usr/lib/systemd/system/nn-edgeai.service 2>/dev/null | grep -q '^Requires=.*nn-rproc-ready.service' \
    || { echo "FATAL: nn-edgeai does not require nn-rproc-ready -- the camera could start into" >&2
         echo "       TIOVX's wait-forever when the RTOS core bring-up stalls (seen 2 boots in 10)." >&2; exit 1; }
echo "  lifecycle: unprovisioned -> setup mode -> provisioned -> camera starts"
# tar directly, not .camchk.lst: that list is removed a few lines above, and
# grepping a file that is not there reads as "not enabled" -- it failed this
# build on an image that had the timer.
tar -tf "$TAR" | grep -qE '\.target\.wants/nn-appupd\.timer$' \
    || { echo "FATAL: nn-appupd.timer is not enabled -- the container and app would only ever" >&2
         echo "       arrive from a hand-run HTTP server, never from the hub." >&2; exit 1; }
echo "  rtos gate: camera stack requires the TIOVX endpoint on all three cores"
echo "  delivery: nn-appupd pulls byai_platform + byai_camera from the hub"
echo "post-image guards: OK"
