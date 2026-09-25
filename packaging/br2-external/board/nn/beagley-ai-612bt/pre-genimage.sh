#!/bin/sh
# Post-image step that runs BEFORE genimage: the three inputs genimage.cfg
# (layout ab-v1) needs that no package produces.
# $1 = BINARIES_DIR (Buildroot passes it first; any extra args are ignored).
# Buildroot exports BUILD_DIR, HOST_DIR and BR2_CONFIG to post-image scripts.
set -e
BIN="$1"

# 1. The boot-chain version, in the boot FAT as /nn-boot-chain.  The OTA agent
#    compares an artifact's requires.boot_chain_min against it: the boot chain
#    is never updated over the air, so a system that needs a newer one must be
#    refused rather than bricked.
UBOOT_VER=$(sed -n 's/^BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE="\(.*\)"$/\1/p' "$BR2_CONFIG")
[ -n "$UBOOT_VER" ] || { echo "FATAL: no BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE in $BR2_CONFIG" >&2; exit 1; }
printf '%s\n' "$UBOOT_VER" > "$BIN/nn-boot-chain"

# 2. A valid U-Boot environment, written into the card at both env offsets.
#    Built from the env this U-Boot was compiled with (u-boot-initial-env,
#    which carries the nn_boot/altbootcmd slot logic), so the card never
#    starts with a CRC-invalid env: fw_setenv on a bad-CRC env would fall
#    back to its own generic defaults and write an env with no nn_boot in it.
ENV_TXT=$(ls "$BUILD_DIR"/uboot-*/u-boot-initial-env 2>/dev/null | head -1)
[ -s "$ENV_TXT" ] || { echo "FATAL: no u-boot-initial-env (BR2_TARGET_UBOOT_INITIAL_ENV)" >&2; exit 1; }
grep -q '^nn_boot=' "$ENV_TXT" || { echo "FATAL: u-boot-initial-env has no nn_boot -- env patch not applied?" >&2; exit 1; }
grep -qx 'bootcmd=run nn_boot' "$ENV_TXT" || { echo "FATAL: bootcmd is not 'run nn_boot' -- U-Boot fragment not applied?" >&2; exit 1; }
"$HOST_DIR/bin/mkenvimage" -r -s 0x40000 -o "$BIN/uboot-env.bin" "$ENV_TXT"

# 3. nn-data: an empty ext4, labeled.  Its directories are created at boot by
#    nn-data-init (owned by root, whatever user ran this build), and
#    nn-growdata stretches it to the end of the card on first boot.
rm -f "$BIN/nn-data.ext4"
"$HOST_DIR/sbin/mke2fs" -q -t ext4 -L nn-data -F "$BIN/nn-data.ext4" 256M
