#!/bin/sh
#
# Unattended bring-up capture.
#
# The console has cost several power-cycles: typed lines drop or duplicate
# bytes at speed, a logout can leave the getty dead, and Enter during
# U-Boot's countdown parks the board at the menu.  None of that is
# necessary to get these results — the board can run the sequence itself
# and leave the answers in a file.  Nobody has to type anything.
#
# Order is deliberate: each step's failure is attributable on its own.
set +e
OUT=/var/log/nn-bringup.txt
# The FILE is the deliverable, not the console.  Writing to a serial console
# that nobody is draining -- or that has been flow-controlled off by a stray
# ^S from a probe -- BLOCKS the writer forever, which would hang the capture
# on its first line and look exactly like a wedged board.  systemd still
# copies our stdout into the journal, so nothing is lost.
log() { echo "$@" >> "$OUT"; }

# Section headers also go to /dev/kmsg -- NOT to stdout.
#
# systemd opening /dev/console for a unit's stdout BLOCKS FOREVER on this
# rig: the Pi Debug Probe wires only TX/RX/GND, so DCD is never asserted
# and a non-CLOCAL tty open waits for carrier that never comes.  The unit
# forks and never execs; you get a service stuck in "(pture.sh)", no
# output and no file, which looks exactly like a hung script.  It is the
# open() that blocks, not the write.
#
# /dev/kmsg has no such problem: it is the kernel ring buffer, so the text
# reaches dmesg and is printed to the console by printk, with nothing to
# open and nothing to wait on.
hdr() {
    echo "$@" >> "$OUT"
    echo "$@" > /dev/kmsg 2>/dev/null || true
}
# Every command is bounded.  A capture that hangs on one step tells us
# nothing and, worse, hides the steps after it.
run() {
    log ""
    log "### $*"
    timeout 30 "$@" 2>&1 | sed 's/^/    /' >> "$OUT"
}

: > "$OUT"
hdr "=== nn bring-up capture $(date -u '+%Y-%m-%dT%H:%M:%SZ') ==="

log ""
hdr "--- 1. kernel identity + SA2UL out of the picture"
run uname -r
run sh -c 'echo "sa2ul entries in /proc/crypto: $(grep -ci sa2ul /proc/crypto)"'
run sh -c 'cat /proc/cmdline'

log ""
hdr "--- 2. iwd ALONE (proves the SA2UL fix independently of anything else)"
OOPS_BEFORE=$(dmesg | grep -ci "Oops\|Unable to handle kernel")
run systemctl unmask iwd.service
# enable, not just start: iwd is D-Bus activated, so an un-enabled unit
# never comes up on its own at the NEXT boot and then looks like a radio
# that associates only when poked.
run systemctl enable iwd.service
run systemctl --no-block start iwd.service
sleep 5
run systemctl is-active iwd.service
OOPS_AFTER=$(dmesg | grep -ci "Oops\|Unable to handle kernel")
hdr "    Oops count before=$OOPS_BEFORE after=$OOPS_AFTER  (equal => SA2UL fix holds)"

log ""
hdr "--- 3. nn-setupd (the BlueZ registration fix)"
run systemctl --no-block start nn-setupd.service
sleep 6
run systemctl is-active nn-setupd.service
run journalctl -u nn-setupd -b --no-pager -n 40

log ""
hdr "--- 4. controller state"
run btmgmt info
run hciconfig -a

log ""
hdr "--- 5. is it actually advertising?"
( btmon -t > /tmp/btmon.txt 2>&1 & echo $! > /tmp/btmon.pid )
sleep 6
kill "$(cat /tmp/btmon.pid)" 2>/dev/null
run sh -c 'tail -60 /tmp/btmon.txt'

log ""
hdr "--- 6. failures, if any"
run systemctl --failed --no-pager
run sh -c 'dmesg | grep -iE "btti|cc33|hci|Oops" | tail -30'

log ""
# Disable ourselves here rather than in ExecStartPost: calling back into
# systemd from a unit the boot transaction is still waiting on can deadlock.
timeout 20 systemctl disable nn-bringup-capture.service >/dev/null 2>&1 || true
log ""
hdr "=== capture complete -> $OUT ==="
