#!/usr/bin/env bash
# stage-local-bundle.sh <image> <version> <artifact> [--promote]
#
# Put a LOCALLY built artifact into the bench hub's LocalDirSource so a device
# pulls it over the real OTA path, without a MinIO round-trip.
#
# nn-stage-hub already does this, but only for a build that is already in
# MinIO (it calls nn-release, which pulls from there).  When you have just
# built a bundle on your own machine and want to exercise hub delivery --
# catalog -> nn-appupd -> sha256 verify -> installer -> restart -- that detour
# through MinIO proves nothing extra.  The asset layout written here is
# exactly nn-release's: image.signed.bin + manifest.json.
#
# ".signed.bin" is nn-release's naming convention, not a signature: integrity
# for these images is the manifest's sha256, which is what nn-appupd and
# nn-sysupd check before handing anything to an installer.
#
# Hosts and credentials come from the ENVIRONMENT only, never literals:
#   ~/.config/nn/release.env (0600) exporting HUB, HUB_SSH, HUB_PASS
set -euo pipefail
IMAGE="${1:?usage: stage-local-bundle.sh <image> <version> <artifact> [--promote]}"
VERSION="${2:?version required}"
ART="${3:?artifact path required}"
PROMOTE=0
[ "${4:-}" = "--promote" ] && PROMOTE=1
[ -f "$ART" ] || { echo "stage-local-bundle: no such artifact: $ART" >&2; exit 2; }

_env=${NN_RELEASE_ENV:-$HOME/.config/nn/release.env}
# shellcheck source=/dev/null
[ -r "$_env" ] && . "$_env"
for v in HUB HUB_SSH HUB_PASS; do
    [ -n "${!v:-}" ] || { echo "stage-local-bundle: \$$v is not set — put it in $_env (0600)" >&2; exit 2; }
done
SOURCE="${NN_HUB_SOURCE:-bench-local}"
FWDIR="${NN_HUB_FW_DIR:-.nn-hub/firmware-local}"
API="http://$HUB:8769/api/v1"

case "$ART" in
    *.tar.xz) FORMAT=tar.xz ;;
    *.tar.gz|*.tgz) FORMAT=tar.gz ;;
    *.img.xz) FORMAT=img.xz ;;
    *) FORMAT=bin ;;
esac

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
REL="$STAGE/$IMAGE/$VERSION"; mkdir -p "$REL"
cp "$ART" "$REL/image.signed.bin"
SUM="$(sha256sum "$REL/image.signed.bin" | cut -d' ' -f1)"
SZ="$(stat -c %s "$REL/image.signed.bin")"
python3 - "$IMAGE" "$VERSION" "$SUM" "$SZ" "$FORMAT" > "$REL/manifest.json" <<'PYEOF'
import json, sys
img, ver, sha, sz, fmt = sys.argv[1:6]
json.dump({"schema": 1, "device_type": img, "version": ver, "sha256": sha,
           "size_bytes": int(sz), "mcuboot": {}, "format": fmt,
           "build_meta": {"source": "local:stage-local-bundle"}},
          sys.stdout, indent=1)
PYEOF

sshpass -p "$HUB_PASS" ssh -o StrictHostKeyChecking=no "$HUB_SSH" "mkdir -p '$FWDIR/$IMAGE/$VERSION'"
sshpass -p "$HUB_PASS" scp -q -o StrictHostKeyChecking=no "$REL"/* "$HUB_SSH:$FWDIR/$IMAGE/$VERSION/"
# the copy is what the device will download: verify it landed intact
HAVE="$(sshpass -p "$HUB_PASS" ssh -o StrictHostKeyChecking=no "$HUB_SSH" \
        "sha256sum '$FWDIR/$IMAGE/$VERSION/image.signed.bin' | cut -d' ' -f1")"
[ "$SUM" = "$HAVE" ] || { echo "stage-local-bundle: copy on the hub does not match (want $SUM, have $HAVE)" >&2; exit 4; }

curl -sf -m 120 -X POST "$API/firmware/sources/$SOURCE/sync" >/dev/null \
    || { echo "stage-local-bundle: sync of source $SOURCE failed" >&2; exit 5; }
curl -sf -m 15 "$API/firmware/catalog?device_type=$IMAGE" | grep -q "\"version\": *\"$VERSION\"" \
    || { echo "stage-local-bundle: $IMAGE $VERSION is not in the catalog after sync" >&2; exit 5; }
echo "stage-local-bundle: $IMAGE $VERSION staged in $SOURCE ($FORMAT, ${SZ} B, sha ${SUM:0:12}…)"

if [ "$PROMOTE" = 1 ]; then
    curl -sf -m 60 -X POST "$API/firmware/catalog/$IMAGE/$VERSION/promote" \
         -H 'Content-Type: application/json' -d '{}' >/dev/null \
        || { echo "stage-local-bundle: promote failed" >&2; exit 7; }
    echo "stage-local-bundle: $IMAGE $VERSION PROMOTED — devices of type $IMAGE pull it on their next tick"
fi
