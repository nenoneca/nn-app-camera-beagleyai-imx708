# nn-app-camera-beagleyai-imx708

Single-program Linux camera for the **BeagleY-AI** with the Raspberry Pi
**IMX708** (Camera Module 3) on CSI — the first non-ESP nn camera, built on
the same `nn-modules` sources the ESP fleet uses (POSIX `nn_osal` backend,
portable `nn_crypto`/`nn_sectun`).

    IMX708 (our kernel driver, AE/AWB in-driver)
      -> GStreamer v4l2src -> WAVE5 V4L2 M2M H.264 (hardware)
      -> nn record framing (byte-identical to the ESP cameras)
      -> nn_sectun (X25519 + AES-256-GCM) -> hub video service

## Build (on the BeagleY-AI)

    sudo apt install cmake pkg-config libgstreamer1.0-dev \
                     libgstreamer-plugins-base1.0-dev libmbedtls-dev
    git submodule update --init nn-modules
    cmake -B build && cmake --build build -j4

## Run

Configuration is environment-only (`/etc/nn-camera.env` + the shipped
systemd unit) — never in source:

    NN_HUB_HOST=orangepi6plus.local
    NN_STREAM_PUB=<service X25519 pubkey, 64 hex>
    # optional: NN_HUB_PORT, NN_CAM_DEVICE/WIDTH/HEIGHT/BITRATE,
    #           NN_CAM_PIPELINE (full GStreamer override, appsink "out"),
    #           NN_OSAL_KV_DIR

First run generates the device keypair (in `NN_OSAL_KV_DIR`) and logs the
public key — authorize it in the video service's `--keydir`.

Timestamps are true epoch ms (Linux clock), so the hub's capture-time badge
shows wall-clock for this camera immediately.
