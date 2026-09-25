#!/bin/sh
# $1 = TARGET_DIR.  Runs after every package has installed, so anything we
# write here wins over what a package shipped.
set -e
T="$1"
D="$(dirname "$0")"

# 0. extlinux.conf into the ROOTFS, not the boot FAT (layout ab-v1): each root
#    slot carries its own kernel (BR2_LINUX_KERNEL_INSTALL_TARGET puts Image
#    and ti/*.dtb in /boot), device trees and boot entry, so one OTA artifact
#    is one coherent system.  U-Boot's nn_boot runs sysboot on the slot's
#    partition.  root= names slot a; the OTA agent rewrites that token in the
#    copy it writes to slot b (U-Boot's extlinux parser expands no ${}).
install -m 0644 -D "$D/extlinux.conf" "$T/boot/extlinux/extlinux.conf"

# 1. cc33xx firmware — the MATCHED 1.0.2.10 pair (fw 1.7.0.323 / conf 1282).
#    cc33xx_fw.bin and cc33xx-conf.bin are a matched set: booting fw 1.7.0.323
#    against the older 1353-byte conf gives "FW is stuck, triggering recovery"
#    -> "download INI params failed: -5" -> the radio dies outright, not just
#    BLE.  Buildroot's own ti-k3-boot-firmware package also drops a
#    cc33xx_fw.bin (a THIRD release) into ti-connectivity, so copy ours last.
#
#    This set is PROVEN for BLE on 6.12 (E2E run 1, 2026-09-14): hci0 came up
#    and advertised with conf 1282.  BeagleBoard's stock cc33xx-ble-up.sh
#    claims the 1282 conf "disables flow control, BLE will not work" and
#    swaps in its 1353 set whenever conf != 1353 -- that claim is wrong for
#    this stack, and the swap block is deliberately NOT carried below.
mkdir -p "$T/lib/firmware/ti-connectivity"
cp -f "$D/fw/cc33xx_fw.bin" "$D/fw/cc33xx-conf.bin" \
      "$D/fw/cc33xx_2nd_loader.bin" "$T/lib/firmware/ti-connectivity/"

# 2. Keep generic btsdio away from the cc33xx.  On 6.12 the BT moved to SDIO
#    and stock kernels have CONFIG_BT_TI unset, so btsdio claims the device,
#    HCI reset times out (Opcode 0x0c03 failed: -110) and hci0 stays DOWN.
#    We build btti_sdio; this makes sure it is the one that binds.
mkdir -p "$T/etc/modprobe.d"
cat > "$T/etc/modprobe.d/nn-cc33xx-bt.conf" <<'EOM'
# cc33xx BT must bind to TI's btti_sdio, never the generic btsdio.
blacklist btsdio
EOM

# 3. Load btti_sdio at boot.  Honest note, from E2E run 1: on this board the
#    controller does NOT come up over SDIO.  hciconfig reports "Bus: UART";
#    it is btti_uart (autoloaded from the DT node serial@2860000/bluetooth,
#    compatible ti,cc33xx-bt) that reaches STATE_HW_READY, and btti_sdio loads
#    with 0 users ("sdio device tree data not available" -- harmless).  It is
#    kept because it costs nothing and some cc33xx releases may use it; the
#    step that actually matters is 8 below.
mkdir -p "$T/etc/modules-load.d"
echo "btti_sdio" > "$T/etc/modules-load.d/nn-bt.conf"

# 4. btmgmt.  bluez lists it in noinst_PROGRAMS (Makefile.tools), so upstream
#    BUILDS it and deliberately never installs it -- no Buildroot option can
#    ship it, and --enable-tools alone leaves you without it.  It is the one
#    command that reports the controller's supported settings ("advertising"),
#    i.e. the check for whether this board can be a BLE peripheral at all, so
#    a diagnostic image without it is close to useless.  Copy it by hand.
BTMGMT="$(ls -d "$BUILD_DIR"/bluez5_utils-*/tools/btmgmt 2>/dev/null | head -1)"
if [ -n "$BTMGMT" ] && [ -x "$BTMGMT" ]; then
    install -m 0755 -D "$BTMGMT" "$T/usr/bin/btmgmt"
else
    echo "post-build WARNING: btmgmt not found in $BUILD_DIR" >&2
fi

# 5. Magic SysRq.  With a single boot entry and no automatic fallback, the
#    console is the only way back into a wedged board; SysRq (BREAK+b over
#    the serial console) reboots it without a power-cycle, which matters
#    when the board is not physically to hand.
mkdir -p "$T/etc/sysctl.d"
cat > "$T/etc/sysctl.d/99-nn-sysrq.conf" <<'EOM'
kernel.sysrq=1
EOM
chmod 0644 "$T/etc/sysctl.d/99-nn-sysrq.conf"

# 6. Hardware watchdog.  CONFIG_K3_RTI_WATCHDOG is builtin, so let systemd
#    own /dev/watchdog and pet it; if the kernel or systemd itself wedges,
#    the RTI block reboots the board with nobody present.
#
#    That only holds because linux.config now has CONFIG_SOFT_WATCHDOG OFF.
#    With softdog built in it registers FIRST, becomes watchdog0, and systemd
#    pets IT while all five RTI blocks sit inactive -- and a software timer
#    cannot recover a panic or a hard hang.  E2E run 1 proved it: a sysrq-c
#    panic left the board hung for over half an hour.  CONFIG_PANIC_TIMEOUT=10
#    is the other half: the kernel reboots itself 10 s after any panic, and
#    the RTI covers the lockups that never reach panic().
#
#    Be clear about what this does and does not cover: systemd keeps
#    petting the watchdog while an ordinary process hangs, so this does
#    NOT rescue a wedged getty/login -- only a hard hang.  Network access
#    is the answer for the former.
mkdir -p "$T/etc/systemd/system.conf.d"
cat > "$T/etc/systemd/system.conf.d/10-nn-watchdog.conf" <<'EOM'
[Manager]
# Hardware watchdog: reboot if systemd stops petting it for this long.
RuntimeWatchdogSec=60
# And if a reboot itself hangs, let the hardware finish the job.
RebootWatchdogSec=120
EOM
chmod 0644 "$T/etc/systemd/system.conf.d/10-nn-watchdog.conf"

# 7. iwd MUST do network configuration itself.
#
#    Buildroot's iwd package already ships EnableNetworkConfiguration=true,
#    so this is a guard rather than a fix -- but it guards the nastiest
#    failure we have seen.  With it off (Debian's stock main.conf has it
#    commented out) the board authenticates and associates perfectly and
#    then has no IPv4 address, only link-local.  Every BLE provisioning
#    step reports success, the wizard completes, and the camera is simply
#    unreachable forever.  Nothing in the flow says anything is wrong.
#
#    systemd-networkd here only has an eth0.network, so wlan0 is unmanaged
#    by it and iwd owning wlan0 config is unambiguous -- no two-DHCP-client
#    fight.
CONF="$T/etc/iwd/main.conf"
if ! grep -qE '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=[[:space:]]*true' "$CONF" 2>/dev/null; then
    echo "post-build: iwd EnableNetworkConfiguration was NOT true — forcing it" >&2
    mkdir -p "$T/etc/iwd"
    printf '[General]\nEnableNetworkConfiguration=true\n\n[Network]\nNameResolvingService=systemd\n' > "$CONF"
    chmod 0644 "$CONF"
fi
grep -qE '^[[:space:]]*EnableNetworkConfiguration[[:space:]]*=[[:space:]]*true' "$CONF" || {
    echo "post-build: FATAL - iwd would not configure the network; a provisioned camera would be unreachable" >&2
    exit 1
}

# 8. Turn the cc33xx's Bluetooth half on.  Nothing else does, and without it
#    there is NO hci index: btti_uart powers the chip to STATE_HW_ON and waits
#    for an HCI wake-up frame that never comes, nn-setupd never advertises,
#    and a fresh card is unreachable -- no Wi-Fi yet, no BLE, no way in.
#    The cc33xx driver exposes a debugfs switch under its phy; writing 1 to it
#    is what moves btti to STATE_HW_READY and registers hci0.  On the Debian
#    card this was BeagleBoard's stock cc33xx-ble.service; the image never
#    had it.  E2E run 1 found this by hand-writing the knob on the board.
#    The knob only appears once the Wi-Fi side has its firmware up, several
#    seconds after the driver probes, hence the wait.  Power is left alone:
#    whether the radio is on is setup mode's decision (step 9).
cat > "$T/usr/sbin/nn-cc33xx-ble-enable" <<'EOM'
#!/bin/sh
# Enable the cc33xx BLE controller (hci0).  See post-build.sh step 8.
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug
i=0
while [ $i -lt 30 ]; do
    BLE=$(find /sys/kernel/debug/ieee80211 -path '*cc33xx*' -name ble_enable 2>/dev/null | head -1)
    [ -n "$BLE" ] && break
    i=$((i + 1)); sleep 1
done
if [ -z "$BLE" ]; then
    echo "nn-cc33xx-ble-enable: no cc33xx ble_enable knob after 30 s -- no Wi-Fi firmware up?" >&2
    exit 1
fi
echo 1 > "$BLE" && echo "nn-cc33xx-ble-enable: wrote 1 to $BLE after ${i}s"
EOM
chmod 0755 "$T/usr/sbin/nn-cc33xx-ble-enable"
mkdir -p "$T/usr/lib/systemd/system" "$T/usr/lib/systemd/system/multi-user.target.wants"
cat > "$T/usr/lib/systemd/system/nn-cc33xx-ble.service" <<'EOM'
[Unit]
Description=Enable the cc33xx Bluetooth controller (hci0)
After=systemd-modules-load.service
Before=bluetooth.service nn-setupd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nn-cc33xx-ble-enable

[Install]
WantedBy=multi-user.target
EOM
ln -sf ../nn-cc33xx-ble.service \
    "$T/usr/lib/systemd/system/multi-user.target.wants/nn-cc33xx-ble.service"

# 9. Bluetooth only in setup mode.  The standing rule is that the radio is
#    for provisioning and is off once the device is provisioned; E2E run 1
#    found hci0 still powered after "already provisioned".  This is the
#    drop-in that did it on cam4, with one tightening: the marker is nnprov/
#    done == 1, which is exactly nn_prov's own test (s_provisioned =
#    val[0] == 1), rather than "nnprov/name is non-empty".  ExecStopPost runs
#    on EVERY exit, including the immediate exit 0 on "already provisioned";
#    ExecStartPre powers the radio back on so an unregister -> reboot ->
#    unprovisioned cycle advertises again without anyone remembering to.
#    bluetoothctl (MGMT) power off rather than rfkill: on this combo chip a
#    shared-firmware reset could take Wi-Fi down with it.  No '$' in the
#    command -- systemd would expand it.
mkdir -p "$T/etc/systemd/system/nn-setupd.service.d"
cat > "$T/etc/systemd/system/nn-setupd.service.d/20-ble-setup-only.conf" <<'EOM'
[Service]
ExecStartPre=-/usr/bin/bluetoothctl power on
ExecStopPost=-/bin/sh -c 'od -An -tu1 -N1 /var/lib/nn/kv/nnprov/done 2>/dev/null | grep -qw 1 && /usr/bin/bluetoothctl power off'
EOM
chmod 0644 "$T/etc/systemd/system/nn-setupd.service.d/20-ble-setup-only.conf"

# 9b. ...and when setup mode ENDS with the board provisioned, start the camera.
#     nn-camera.service is only pulled in at boot, where an unprovisioned board
#     rightly skips it (ExecCondition).  nn_prov does not reboot this board
#     after a successful provision -- it joins Wi-Fi in place -- so without
#     this the wizard reports "done, adopted slot cam3" and the camera then
#     sits provisioned, online and silent until someone power-cycles it.  Found
#     by the lifecycle E2E, 2026-09-17: BLE provisioning took 8 s and nothing
#     streamed for the next four minutes.  --no-block: never hold up the unit
#     that is stopping.  On a boot that was already provisioned this start is
#     a harmless no-op (the unit is already queued or running).
cat > "$T/etc/systemd/system/nn-setupd.service.d/30-start-camera.conf" <<'EOM'
[Service]
ExecStopPost=-/bin/sh -c '/usr/sbin/nn-provisioned && /usr/bin/systemctl --no-block start nn-camera.service'
EOM
chmod 0644 "$T/etc/systemd/system/nn-setupd.service.d/30-start-camera.conf"

# 10. An RCU stall panics too.  The lockup detectors in linux.config panic on
#     a soft or hard lockup, but E2E run 2's soft-lockup test showed the RCU
#     stall detector sees a stuck CPU first (21 s) and only warns; the
#     soft-lockup panic followed at 47 s.  There is no Kconfig for this one,
#     so it is a sysctl, applied by systemd-sysctl early in boot.
cat > "$T/etc/sysctl.d/10-nn-hang.conf" <<'EOM'
kernel.panic_on_rcu_stall=1
EOM
chmod 0644 "$T/etc/sysctl.d/10-nn-hang.conf"

# 11. Uplink watchdog.  Everything above recovers a HUNG board; this recovers
#     a live board that lost its network -- the case a headless camera meets
#     most, and one the hardware watchdog never sees (systemd keeps petting
#     it).  Policy agreed with the operator, 2026-09-15: once provisioned, no
#     answer from the default gateway for 10 min -> restart iwd; for 20 min ->
#     reboot.  Each consecutive reboot for the same reason doubles the wait
#     (20, 40, 80 ... capped at 6 h), so a long router outage cannot become a
#     reboot every 20 minutes for days; the count clears the moment the
#     gateway answers.  Setup mode is never an outage: an unprovisioned board
#     has no network to keep, so the check does nothing until nnprov/done == 1.
#     ARP as well as ICMP: some routers drop ping, none can drop ARP and still
#     route.  Thresholds can be overridden in /etc/nn/netwatch.conf.
cat > "$T/usr/sbin/nn-netwatch" <<'EOM'
#!/bin/sh
# Uplink watchdog, run once a minute by nn-netwatch.timer.  See post-build.sh
# step 11 for the policy and why.
RESTART_AFTER=${NN_NETWATCH_RESTART_AFTER:-600}
REBOOT_AFTER=${NN_NETWATCH_REBOOT_AFTER:-1200}
REBOOT_MAX=${NN_NETWATCH_REBOOT_MAX:-21600}
RUN=/run/nn-netwatch
KEEP=/var/lib/nn/netwatch
# stdout only: the unit's stdout already reaches the journal as nn-netwatch,
# and logging through logger as well printed every line twice (E2E run 3)
log() { echo "$*"; }

if [ "$(od -An -tu1 -N1 /var/lib/nn/kv/nnprov/done 2>/dev/null | tr -d ' ')" != 1 ]; then
    rm -rf "$RUN"; exit 0                      # setup mode: nothing to keep
fi
mkdir -p "$RUN" "$KEEP"
now=$(cut -d. -f1 /proc/uptime)

reachable() {
    set -- $(ip -4 route show default 2>/dev/null | awk '
        { for (i = 1; i < NF; i++) { if ($i == "via") g = $(i+1); if ($i == "dev") d = $(i+1) } }
        END { print g, d }')
    [ -n "${1:-}" ] || return 1               # no default route: no uplink
    ping -c1 -W2 "$1" >/dev/null 2>&1 && return 0
    [ -n "${2:-}" ] && arping -c1 -w2 -I "$2" "$1" >/dev/null 2>&1
}

if reachable; then
    [ -f "$RUN/down_since" ] && log "uplink back after $(( now - $(cat "$RUN/down_since") ))s"
    rm -f "$RUN/down_since" "$RUN/restarted" "$KEEP/reboots"
    exit 0
fi

if [ ! -f "$RUN/down_since" ]; then
    echo "$now" > "$RUN/down_since"
    log "uplink lost: no default gateway answering"
fi
down=$(( now - $(cat "$RUN/down_since") ))

reboots=$(cat "$KEEP/reboots" 2>/dev/null || echo 0)
limit=$REBOOT_AFTER; i=0
while [ "$i" -lt "$reboots" ] && [ "$limit" -lt "$REBOOT_MAX" ]; do
    limit=$(( limit * 2 )); i=$(( i + 1 ))
done
[ "$limit" -gt "$REBOOT_MAX" ] && limit=$REBOOT_MAX

if [ "$down" -ge "$limit" ]; then
    echo $(( reboots + 1 )) > "$KEEP/reboots"; sync
    log "uplink down ${down}s (limit ${limit}s, reboot $(( reboots + 1 )) in a row): rebooting"
    systemctl reboot
elif [ "$down" -ge "$RESTART_AFTER" ] && [ ! -f "$RUN/restarted" ]; then
    touch "$RUN/restarted"
    log "uplink down ${down}s: restarting iwd"
    systemctl restart iwd
fi
EOM
chmod 0755 "$T/usr/sbin/nn-netwatch"
cat > "$T/usr/lib/systemd/system/nn-netwatch.service" <<'EOM'
[Unit]
Description=nn uplink watchdog (restart Wi-Fi, then reboot, when a provisioned camera loses its network)
After=iwd.service

[Service]
Type=oneshot
EnvironmentFile=-/etc/nn/netwatch.conf
ExecStart=/usr/sbin/nn-netwatch
EOM
cat > "$T/usr/lib/systemd/system/nn-netwatch.timer" <<'EOM'
[Unit]
Description=Check the camera's uplink once a minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOM
mkdir -p "$T/usr/lib/systemd/system/timers.target.wants"
ln -sf ../nn-netwatch.timer "$T/usr/lib/systemd/system/timers.target.wants/nn-netwatch.timer"

# 12. Layout ab-v1: what must survive a slot swap lives on nn-data (p4),
#     bound over the rootfs paths.  Lose any of these on an OTA and the
#     camera is back in setup mode (provisioning KV, device key, Wi-Fi PSK),
#     has lost its OTA state, or its logs.  /etc/machine-id is NOT one of them:
#     systemd reads it before fstab is mounted, so it ships empty and the OTA
#     agent copies it into each new slot instead.
#     nn-data-init creates the bind sources on the (possibly fresh) partition
#     before any bind is attempted -- they are root-owned because it runs on
#     the board, not in the build.  nn-growdata stretches p4 over the rest of
#     the card once: genimage needs a fixed size, cards do not have one.
mkdir -p "$T/data" "$T/boot-fat" "$T/var/lib/nn-ota" "$T/var/lib/nn-gw" "$T/opt/nn-app" "$T/var/log/journal"
if ! grep -q 'nn layout ab-v1' "$T/etc/fstab"; then
    cat >> "$T/etc/fstab" <<'EOM'
# nn layout ab-v1 -- see post-build.sh step 12
PARTUUID=6e6e6279-01  /boot-fat         vfat  ro,nofail  0 0
LABEL=nn-data         /data             ext4  defaults   0 2
/data/var/lib/nn      /var/lib/nn       none  bind,x-systemd.requires=nn-data-init.service  0 0
/data/var/lib/iwd     /var/lib/iwd      none  bind,x-systemd.requires=nn-data-init.service  0 0
/data/var/lib/nn-ota  /var/lib/nn-ota   none  bind,x-systemd.requires=nn-data-init.service  0 0
/data/var/lib/nn-gw   /var/lib/nn-gw    none  bind,x-systemd.requires=nn-data-init.service  0 0
/data/opt/nn-app      /opt/nn-app       none  bind,x-systemd.requires=nn-data-init.service  0 0
/data/var/log/journal /var/log/journal  none  bind,x-systemd.requires=nn-data-init.service  0 0
EOM
fi
cat > "$T/usr/lib/systemd/system/nn-data-init.service" <<'EOM'
[Unit]
Description=Create the nn-data bind sources (layout ab-v1)
DefaultDependencies=no
RequiresMountsFor=/data
Before=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'mkdir -p /data/var/lib/nn /data/var/lib/iwd /data/var/lib/nn-ota /data/var/lib/nn-gw /data/opt/nn-app /data/var/log/journal && chmod 0700 /data/var/lib/iwd /data/var/lib/nn-gw'
EOM
cat > "$T/usr/sbin/nn-growdata" <<'EOM'
#!/bin/sh
# Grow nn-data (p4) to the end of the card, once.  See post-build.sh step 12.
set -e
[ -e /data/.nn-grown ] && exit 0
part=$(readlink -f /dev/disk/by-partuuid/6e6e6279-04)
disk=/dev/$(basename "$(readlink -f "/sys/class/block/$(basename "$part")/..")")
end=$(( $(cat "/sys/class/block/$(basename "$part")/start") + $(cat "/sys/class/block/$(basename "$part")/size") ))
total=$(cat "/sys/class/block/$(basename "$disk")/size")
# grow only if at least 64 MiB (131072 sectors) is unused after p4
if [ $(( total - end )) -gt 131072 ]; then
    echo "growing $part to the end of $disk ($(( (total - end) / 2048 )) MiB free)"
    echo ', +' | sfdisk --force --no-reread -N 4 "$disk"
    partx -u -n 4 "$disk"
    resize2fs "$part"
fi
touch /data/.nn-grown
EOM
chmod 0755 "$T/usr/sbin/nn-growdata"
cat > "$T/usr/lib/systemd/system/nn-growdata.service" <<'EOM'
[Unit]
Description=Grow nn-data to the end of the card (first boot, layout ab-v1)
RequiresMountsFor=/data
ConditionPathExists=!/data/.nn-grown

[Service]
Type=oneshot
ExecStart=/usr/sbin/nn-growdata

[Install]
WantedBy=multi-user.target
EOM
ln -sf ../nn-growdata.service "$T/usr/lib/systemd/system/multi-user.target.wants/nn-growdata.service"

# 13. Layout identity for the OTA agent, and where it finds the U-Boot env.
#     NN_IMAGE_VERSION comes from build-image.sh; an image without it would
#     not know what it is, so that is a build failure, not a default.
[ -n "${NN_IMAGE_VERSION:-}" ] || { echo "post-build: FATAL - NN_IMAGE_VERSION not set (run via build-image.sh)" >&2; exit 1; }
echo ab-v1 > "$T/etc/nn-layout"
echo "$NN_IMAGE_VERSION" > "$T/etc/nn-system-version"
cat > "$T/etc/fw_env.config" <<'EOM'
# U-Boot env, redundant pair on the SD card's user area (layout ab-v1).
# device       offset    size
/dev/mmcblk1   0x100000  0x40000
/dev/mmcblk1   0x140000  0x40000
EOM
: > "$T/etc/machine-id"

# 14. Trial deadline (layout ab-v1, design layer 4).  U-Boot's boot count only
#     advances when the trial slot reboots, and the hardware watchdog only
#     fires when nothing pets it -- a trial system that boots fine but whose
#     agent never confirms (agent missing or broken in the new image, health
#     never decidable) would sit on an unconfirmed trial forever.  Kept apart
#     from nn-sysupd on purpose: its whole value is independence from a broken
#     agent.  20 min after boot, on a trial (upgrade_available=1) whose version
#     the agent has not recorded as confirmed, log why and reboot; each reboot
#     counts, and U-Boot rolls back after bootlimit.
cat > "$T/usr/sbin/nn-trial-guard" <<'EOM'
#!/bin/sh
# Reboot an unconfirmed trial slot.  See post-build.sh step 14.
[ "$(fw_printenv -n upgrade_available 2>/dev/null)" = 1 ] || exit 0
running=$(cat /etc/nn-system-version 2>/dev/null)
confirmed=$(cat /var/lib/nn-ota/sys/confirmed 2>/dev/null)
[ -n "$running" ] && [ "$confirmed" = "$running" ] && exit 0
echo "trial of ${running:-?} (slot $(fw_printenv -n nn_slot_try 2>/dev/null)) not confirmed 20 min after boot" \
     "-- rebooting so U-Boot counts it (bootcount $(fw_printenv -n bootcount 2>/dev/null), bootlimit $(fw_printenv -n bootlimit 2>/dev/null))"
sync
systemctl reboot
EOM
chmod 0755 "$T/usr/sbin/nn-trial-guard"
cat > "$T/usr/lib/systemd/system/nn-trial-guard.service" <<'EOM'
[Unit]
Description=Reboot a trial slot the OTA agent has not confirmed (layout ab-v1)

[Service]
Type=oneshot
ExecStart=/usr/sbin/nn-trial-guard
EOM
cat > "$T/usr/lib/systemd/system/nn-trial-guard.timer" <<'EOM'
[Unit]
Description=Trial-slot deadline, 20 min after boot

[Timer]
OnBootSec=20min

[Install]
WantedBy=timers.target
EOM
ln -sf ../nn-trial-guard.timer "$T/usr/lib/systemd/system/timers.target.wants/nn-trial-guard.timer"

# 15. network-online means the Wi-Fi uplink.  systemd-networkd-wait-online
#     waits for eth0 (BR2_SYSTEM_DHCP, no cable on a camera) and for "at least
#     one link online" among the links networkd manages -- and wlan0 is iwd's,
#     not networkd's -- so it always ran into its 2-minute timeout, holding
#     every network-online unit (the OTA agent's first tick included) until
#     then (E2E, 2026-09-16).  Mask it; nn-wait-uplink waits up to 60 s for a
#     default route instead and never fails the boot.
ln -sf /dev/null "$T/etc/systemd/system/systemd-networkd-wait-online.service"
cat > "$T/usr/lib/systemd/system/nn-wait-uplink.service" <<'EOM'
[Unit]
Description=Wait up to 60 s for the Wi-Fi uplink's default route
DefaultDependencies=no
After=iwd.service systemd-networkd.service
Before=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'i=0; while [ $i -lt 60 ]; do ip -4 route show default | grep -q . && exit 0; sleep 1; i=$((i+1)); done; echo "no default route after 60 s -- continuing"'

[Install]
WantedBy=network-online.target
EOM
mkdir -p "$T/usr/lib/systemd/system/network-online.target.wants"
ln -sf ../nn-wait-uplink.service "$T/usr/lib/systemd/system/network-online.target.wants/nn-wait-uplink.service"

# 16. What a healthy trial looks like, for nn-sysupd's health gate.  A U-Boot
#     change once left cores 1-3 offline ("failed to come online") and the
#     single-core trial still confirmed -- the gate had nothing to compare to.
#     This board has four A53 cores; fewer online fails the trial.
mkdir -p "$T/etc/nn-sysupd"
echo 4 > "$T/etc/nn-sysupd/expect-cpus"

# 17. TI vision-apps RTOS firmware.  The camera path does not end at the
#     kernel: the VPAC ISP that debayers the sensor's raw output is driven
#     from the main R5F, and the DL accelerators are the two C7x DSPs.  The
#     host kernel's remoteproc loads all three from /lib/firmware, under the
#     exact names this board's device tree asks for (firmware-name =
#     "j722s-main-r5f0_0-fw", "j722s-c71_0-fw", "j722s-c71_1-fw") -- so they
#     belong to the IMAGE, not to the container that uses them: a container
#     cannot load remoteproc firmware.
#
#     They are a matched pair with the container's TIOVX userspace.  Mixing
#     SDK releases does not degrade gracefully; the shared object-descriptor
#     table desynchronises and the pipeline wedges until a power cycle (not
#     even a reboot clears it).  So the SDK version goes in the image where
#     the bundle side can check it instead of assuming.
cp -f "$D/fw/ti/j722s-main-r5f0_0-fw" "$D/fw/ti/j722s-c71_0-fw" \
      "$D/fw/ti/j722s-c71_1-fw" "$T/lib/firmware/"
install -m 0644 "$D/fw/ti/VERSION" "$T/etc/nn-ti-vision-apps-version"

# 18. The camera bring-up check, in the image rather than scp'd to a board.
#     Every question it asks has a silent failure mode -- an overlay U-Boot
#     skipped, a sensor that never ACKed, a capture graph left at the default
#     UYVY/640x480 that streams ZERO frames without an error -- so the answers
#     are worth having on every board, not just the one on the bench.
install -m 0755 "$D/nn-camcheck" "$T/usr/sbin/nn-camcheck"

# 19. The TI edgeai container: installer, LXC config and unit.
#     The container itself is NOT in the image -- it lives on nn-data, so a
#     system OTA does not re-push it and a model swap needs no system OTA at
#     all.  What the image carries is the machinery to install and start one,
#     plus the version the container must match.
#
#     ConditionPathExists, not an enable-time decision: a camera with no
#     container installed yet should skip this unit silently at boot, not fail
#     it.  A failed unit at boot is noise that trains people to ignore units.
#     /opt/nn is where the camera app will live; the container binds it in.
#     It must EXIST on the host or the bind fails the container start outright
#     -- lxc's "optional" did not save us, it still tried the mount.
mkdir -p "$T/opt/nn"
# The RTOS readiness gate (see nn-rproc-ready): the camera stack Requires= it,
# so nothing ever starts into TIOVX's wait-forever on a stalled core bring-up.
install -m 0755 "$D/nn-rproc-ready" "$T/usr/sbin/nn-rproc-ready"
cat > "$T/usr/lib/systemd/system/nn-rproc-ready.service" <<'EOM'
[Unit]
Description=Wait for the TI RTOS cores' TIOVX endpoint (self-heals a stalled bring-up)
After=nn-data-init.service systemd-modules-load.service
Requires=nn-data-init.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nn-rproc-ready
TimeoutStartSec=120
EOM
install -m 0755 "$D/nn-edgeai-install" "$T/usr/sbin/nn-edgeai-install"
install -m 0755 "$D/nn-edgeai-start"   "$T/usr/sbin/nn-edgeai-start"
install -m 0644 -D "$D/edgeai-lxc.conf" "$T/usr/share/nn/edgeai-lxc.conf"
cat > "$T/usr/lib/systemd/system/nn-edgeai.service" <<'EOM'
[Unit]
Description=TI edgeai container (TIOVX userspace for the camera pipeline)
ConditionPathExists=/opt/nn-app/edgeai/rootfs
After=nn-data-init.service nn-rproc-ready.service
Requires=nn-data-init.service nn-rproc-ready.service

[Service]
Type=simple
ExecStart=/usr/sbin/nn-edgeai-start
# -k: kill, do not ask.  The container's init is a bare `sleep`, which ignores
# the SIGPWR lxc-stop sends for a graceful shutdown, so without -k every
# reboot sat in "A stop job is running for TI edgeai..." until a timeout.
# There is nothing in there to shut down gracefully: the camera app is reaped
# by nn-camera.service (SIGINT first, so TIDL is released) before this runs.
ExecStop=/usr/bin/lxc-stop -k -n edgeai -P /run/nn-edgeai
TimeoutStopSec=15
Restart=on-failure
RestartSec=10
# The container start is cheap but the ISP behind it is not: a restart loop
# against a wedged TIOVX is how the object-descriptor table gets exhausted,
# and that survives reboots.
StartLimitBurst=5
StartLimitIntervalSec=300

[Install]
WantedBy=multi-user.target
EOM
mkdir -p "$T/usr/lib/systemd/system/multi-user.target.wants"
ln -sf ../nn-edgeai.service "$T/usr/lib/systemd/system/multi-user.target.wants/nn-edgeai.service"

# 20. The camera app and its model live on nn-data too (app/current,
#     models/current), installed by nn-app-install; nn-camera.service runs
#     the app inside the edgeai container and, like nn-edgeai.service, is
#     condition-guarded so a camera with no app yet does not fail a unit at
#     every boot.  The model is a separate unit on purpose: swapping a
#     detector must not need a container or a system update.
install -m 0755 "$D/nn-app-install"    "$T/usr/sbin/nn-app-install"
#     ...and the puller that makes those two installers reachable from the hub
#     instead of from whatever HTTP server an operator happens to run.  A
#     timer, not a boot-time oneshot: the layers are not needed to boot, and a
#     camera that comes up before the hub does must not miss them.
install -m 0755 "$D/nn-appupd"         "$T/usr/sbin/nn-appupd"
cat > "$T/usr/lib/systemd/system/nn-appupd.service" <<'EOM'
[Unit]
Description=Pull the edgeai container and camera app from the hub
ConditionPathIsMountPoint=/opt/nn-app
After=network-online.target nn-data-init.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/sbin/nn-appupd
TimeoutStartSec=900
EOM
cat > "$T/usr/lib/systemd/system/nn-appupd.timer" <<'EOM'
[Unit]
Description=Check the hub for a new edgeai container or camera app

[Timer]
OnBootSec=3min
OnUnitActiveSec=15min
AccuracySec=30s

[Install]
WantedBy=timers.target
EOM
mkdir -p "$T/usr/lib/systemd/system/timers.target.wants"
ln -sf ../nn-appupd.timer "$T/usr/lib/systemd/system/timers.target.wants/nn-appupd.timer"
install -m 0755 "$D/nn-cam-setup"      "$T/usr/sbin/nn-cam-setup"
install -m 0755 "$D/nn-provisioned"    "$T/usr/sbin/nn-provisioned"
install -m 0755 "$D/nn-camera-stopped" "$T/usr/sbin/nn-camera-stopped"
install -m 0644 "$D/nn-camera.service" "$T/usr/lib/systemd/system/nn-camera.service"
ln -sf ../nn-camera.service "$T/usr/lib/systemd/system/multi-user.target.wants/nn-camera.service"
