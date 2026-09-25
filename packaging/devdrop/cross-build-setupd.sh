#!/bin/bash
# Cross-build nn-setupd for the Debian Trixie (glibc 2.41) byai card.
#
# Built with the host's aarch64 cross-gcc (glibc 2.35 headers) rather than
# in a Debian build root: glibc is BACKWARD compatible, so a binary linked
# against 2.35 runs on 2.41.  The reverse would not hold, which is why
# Buildroot's toolchain is unusable here -- its libc is not Debian's.
# libsystemd is linked against the TARGET's own .so so we bind to its
# SONAME rather than the host's.  --allow-shlib-undefined is required
# because that .so itself needs glibc 2.36/2.38/2.39 symbols and libcap,
# none of which exist in the 2.35 cross sysroot; they resolve on the
# target at runtime.  It relaxes checking only for symbols a SHARED
# library needs -- our own objects are still fully resolved.
set -e
D="$(cd "$(dirname "$0")" && pwd)"
M="${M:?set M to nn-modules/modules/libs}"
CC=aarch64-linux-gnu-gcc
OUT="$D/out"; mkdir -p "$OUT"

INC="-I$D/compat -I$M/nn_prov/include -I$M/nn_prov/src -I$M/nn_pal/include
     -I$M/nn_osal/include -I$M/nn_crypto/include -I$M/nn_netstream/include
     -I$D/mbedtls-3.6.5/include"

SRC="$D/src/main.c $D/src/app_desc.c $D/src/netstream_shim.c $D/src/compat_str.c
     $M/nn_prov/src/nn_prov.c $M/nn_prov/src/nn_prov_ble.c
     $M/nn_prov/src/nn_prov_crypto.c
     $M/nn_pal/src/posix/ble.c $M/nn_pal/src/posix/wifi.c
     $M/nn_crypto/src/nn_crypto.c
     $M/nn_osal/src/posix/log.c $M/nn_osal/src/posix/storage.c
     $M/nn_osal/src/posix/sync.c $M/nn_osal/src/posix/system.c
     $M/nn_osal/src/posix/thread.c $M/nn_osal/src/posix/time.c
     $M/nn_osal/src/posix/socket.c $M/nn_osal/src/posix/buf.c"

$CC -O2 -g -std=gnu11 -Wall -Wextra \
    -DCONFIG_NN_OSAL_BACKEND_POSIX=1 -DCONFIG_NN_PAL_BACKEND_POSIX=1 \
    $INC $SRC \
    -L"$D/sysroot/usr/lib" -Wl,-rpath-link,"$D/sysroot/usr/lib" \
    -Wl,--allow-shlib-undefined \
    "$D/mbedtls-3.6.5/library/libmbedcrypto.a" \
    -lsystemd -lpthread -lm \
    -o "$OUT/nn-setupd"
echo "built $OUT/nn-setupd"
aarch64-linux-gnu-readelf -d "$OUT/nn-setupd" | grep -E "NEEDED|SONAME" | sed 's/^/  /'
