# SPDX-License-Identifier: Apache-2.0
# nn-camera — single-program Linux camera for the BeagleY-AI + IMX708.
#
#   capture (GStreamer: V4L2 + WAVE5 H.264)  ─▶  nn record framing
#     ─▶ nn_sectun (X25519 + AES-GCM)  ─▶  hub video service (TCP)
#
# Shared code comes from the nn-modules submodule via the POSIX nn_osal
# backend — the same nn_crypto/nn_sectun sources the ESP cameras run.
cmake_minimum_required(VERSION 3.16)
project(nn-camera C)

set(NN_MODULES ${CMAKE_CURRENT_SOURCE_DIR}/nn-modules/modules/libs)

option(NN_STUB_CAPTURE "build without GStreamer (CI / uplink-only test)" OFF)
option(NN_BUILD_CAMERA "build the nn-camera binary" ON)
if(NOT NN_STUB_CAPTURE AND NN_BUILD_CAMERA)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(GST REQUIRED gstreamer-1.0 gstreamer-app-1.0)
endif()

if(NOT DEFINED NN_INFER_PAL)
    set(NN_INFER_PAL stub)
endif()

# the ipc PAL talks to nn-inferd over the nn_accel shared-memory pool
set(NN_PAL_EXTRA_SRC "")
if(NN_INFER_PAL STREQUAL "ipc")
    set(NN_PAL_EXTRA_SRC ${NN_MODULES}/nn_accel/src/shmpool.c)
endif()

# The image build wants nn-setupd alone (no GStreamer in that rootfs yet),
# so the camera target is optional.  Default ON: a plain `cmake .` still
# builds what it always built.
if(NN_BUILD_CAMERA)
    add_executable(nn-camera
        src/main.c
        src/uplink.c
        src/infer.c
        ${NN_MODULES}/nn_infer/src/pal/${NN_INFER_PAL}/pal_${NN_INFER_PAL}.c
        ${NN_PAL_EXTRA_SRC}
        ${NN_MODULES}/nn_infer/src/policy.c
        $<IF:$<BOOL:${NN_STUB_CAPTURE}>,src/capture_stub.c,src/capture_gst.c>
        ${NN_MODULES}/nn_osal/src/posix/thread.c
        ${NN_MODULES}/nn_osal/src/posix/sync.c
        ${NN_MODULES}/nn_osal/src/posix/time.c
        ${NN_MODULES}/nn_osal/src/posix/log.c
        ${NN_MODULES}/nn_osal/src/posix/system.c
        ${NN_MODULES}/nn_osal/src/posix/socket.c
        ${NN_MODULES}/nn_osal/src/posix/storage.c
        ${NN_MODULES}/nn_osal/src/posix/gpio.c
        ${NN_MODULES}/nn_osal/src/posix/buf.c
        ${NN_MODULES}/nn_crypto/src/nn_crypto.c
        ${NN_MODULES}/nn_sectun/src/nn_sectun.c
    )
    target_compile_definitions(nn-camera PRIVATE CONFIG_NN_OSAL_BACKEND_POSIX=1)
    target_compile_options(nn-camera PRIVATE -Wall -Wextra ${GST_CFLAGS})
    target_include_directories(nn-camera PRIVATE
        src
        ${NN_MODULES}/nn_osal/include
        ${NN_MODULES}/nn_infer/include
        ${NN_MODULES}/nn_accel/include
        ${NN_MODULES}/nn_crypto/include
        ${NN_MODULES}/nn_sectun/include
        ${GST_INCLUDE_DIRS})
    # PSA crypto: Debian's mbedtls ships psa/crypto.h in libmbedcrypto
    target_link_libraries(nn-camera ${GST_LIBRARIES} mbedcrypto pthread dl)
    if(NN_ORT_INCLUDE)
        target_include_directories(nn-camera PRIVATE ${NN_ORT_INCLUDE})
    endif()
    # the byai_ort PAL includes <onnxruntime_c_api.h>; the container's ORT
    # headers live under this nested path.  Baked in here so a fresh clone
    # builds without the magic -DCMAKE_C_FLAGS include that used to be passed
    # by hand (and forgotten).
    if(NN_INFER_PAL STREQUAL "byai_ort")
        target_include_directories(nn-camera PRIVATE
            /usr/include/onnxruntime/include/onnxruntime/core/session)
    endif()
    # extracted-package builds: -DNN_EXTRA_PREFIX=<dir with usr/include + usr/lib/...>
    if(NN_EXTRA_PREFIX)
        target_include_directories(nn-camera PRIVATE ${NN_EXTRA_PREFIX}/usr/include)
        target_link_directories(nn-camera PRIVATE
        ${NN_EXTRA_PREFIX}/usr/lib/x86_64-linux-gnu
        ${NN_EXTRA_PREFIX}/usr/lib/aarch64-linux-gnu
        ${NN_EXTRA_PREFIX}/usr/lib)   # plain usr/lib too, as nn-setupd has
    endif()
endif()

# ── nn-setupd — BLE setup mode ──────────────────────────────────────────
# Runs before the camera exists: presents the same GATT contract as the
# ESP cameras (service e7f00001) so the hub's existing wizard provisions
# this board with no protocol change, then applies Wi-Fi through iwd.
# Separate binary rather than a mode of nn-camera, because it must run on
# a freshly flashed card that has no network, no config and no camera
# pipeline — and must be gone once the device is adopted.
option(NN_BUILD_SETUPD "build nn-setupd (BLE setup mode)" ON)
if(NN_BUILD_SETUPD)
    find_package(PkgConfig REQUIRED)
    pkg_check_modules(SYSTEMD REQUIRED libsystemd)

    add_executable(nn-setupd
        src/setupd/setupd_main.c
        src/setupd/app_desc.c
        src/setupd/netstream_shim.c
        src/setupd/compat_str.c
        ${NN_MODULES}/nn_prov/src/nn_prov.c
        ${NN_MODULES}/nn_prov/src/nn_prov_ble.c
        ${NN_MODULES}/nn_prov/src/nn_prov_crypto.c
        ${NN_MODULES}/nn_pal/src/posix/ble.c
        ${NN_MODULES}/nn_pal/src/posix/wifi.c
        ${NN_MODULES}/nn_crypto/src/nn_crypto.c
        ${NN_MODULES}/nn_osal/src/posix/log.c
        ${NN_MODULES}/nn_osal/src/posix/storage.c
        ${NN_MODULES}/nn_osal/src/posix/sync.c
        ${NN_MODULES}/nn_osal/src/posix/system.c
        ${NN_MODULES}/nn_osal/src/posix/thread.c
        ${NN_MODULES}/nn_osal/src/posix/time.c
        ${NN_MODULES}/nn_osal/src/posix/socket.c
        ${NN_MODULES}/nn_osal/src/posix/buf.c
    )
    target_compile_definitions(nn-setupd PRIVATE
        CONFIG_NN_OSAL_BACKEND_POSIX=1
        CONFIG_NN_PAL_BACKEND_POSIX=1
    )
    target_include_directories(nn-setupd PRIVATE
        compat                       # esp_err.h / esp_app_desc.h stand-ins
        ${NN_MODULES}/nn_prov/include
        ${NN_MODULES}/nn_prov/src
        ${NN_MODULES}/nn_pal/include
        ${NN_MODULES}/nn_osal/include
        ${NN_MODULES}/nn_crypto/include
        ${NN_MODULES}/nn_netstream/include
        ${SYSTEMD_INCLUDE_DIRS}
    )
    target_link_libraries(nn-setupd ${SYSTEMD_LIBRARIES} mbedcrypto pthread m)
    # Needed for image builds: without an install rule the packaging step
    # copies the unit and NOT the binary, leaving a service that points at
    # a file which does not exist.
    include(GNUInstallDirs)
    install(TARGETS nn-setupd RUNTIME DESTINATION ${CMAKE_INSTALL_SBINDIR})
    target_link_directories(nn-setupd PRIVATE ${SYSTEMD_LIBRARY_DIRS})
    # same escape hatch as nn-camera, for building against an extracted
    # sysroot rather than host packages
    if(NN_EXTRA_PREFIX)
        target_include_directories(nn-setupd PRIVATE ${NN_EXTRA_PREFIX}/usr/include)
        target_link_directories(nn-setupd PRIVATE
            ${NN_EXTRA_PREFIX}/usr/lib/x86_64-linux-gnu
            ${NN_EXTRA_PREFIX}/usr/lib/aarch64-linux-gnu
            ${NN_EXTRA_PREFIX}/usr/lib)
    endif()
endif()
