# Shared by build-image.sh and build-toolchain.sh -- sourced, not run.
#
# The pinned Buildroot, and the KEY that names a prebuilt cross toolchain.
# Both scripts must agree on these byte for byte: the image build refuses a
# toolchain whose key does not match, so anything defined twice would drift.

BR_TAG=2025.08
BR_URL=https://gitlab.com/buildroot.org/buildroot.git
TOOLCHAIN_DEFCONFIG=nn_byai_toolchain_defconfig

say() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

# fetch_buildroot <buildroot-dir> <br2-external-dir>
fetch_buildroot() {
    local br=$1 ext=$2
    if [ ! -d "$br/.git" ]; then
        say "fetching Buildroot $BR_TAG"
        git clone -q --depth 1 --branch "$BR_TAG" "$BR_URL" "$br"
    else
        say "Buildroot already present ($br)"
    fi
    # Backported upstream fix: u-boot 2026.01 ships COPYING as a symlink to
    # Licenses/gpl-2.0.txt, and Buildroot's pre-2013.10 compatibility hook then
    # copies it onto itself and fails the extract.  Idempotent.
    if ! grep -q 'Licenses/gpl-2.0.txt \]' "$br/boot/uboot/uboot.mk"; then
        say "applying uboot.mk backport"
        ( cd "$br" && git apply "$ext/br-patches/0001-uboot-dont-copy-COPYING-onto-itself.patch" )
    fi
}

# toolchain_key <br2-external-dir>
#
# Everything the prebuilt toolchain is a function of.  Change any of these and
# the key changes, the image build stops finding a toolchain, and CI builds a
# new one -- which is the point: a stale toolchain must never be picked up
# quietly.
#   - the Buildroot release (gcc, binutils, glibc versions and patches)
#   - the toolchain defconfig
#   - our patches to Buildroot itself
#   - the build container: the SDK's host binaries (gcc, as, ld) link against
#     the container's own libc, so a toolchain from another image may not run.
#     nnbuild passes the image id; outside nnbuild it is "unknown", which still
#     keys consistently on the one machine that built it.
#   - the host architecture
toolchain_key() {
    local ext=$1
    {
        echo "buildroot $BR_TAG"
        cat "$ext/configs/$TOOLCHAIN_DEFCONFIG"
        cat "$ext"/br-patches/*.patch
        echo "builder ${NN_BUILD_IMAGE_ID:-unknown}"
        uname -m
    } | sha256sum | cut -c1-16
}
