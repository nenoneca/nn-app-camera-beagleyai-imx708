# BeagleY-AI board support: IMX708 (RPi Camera Module 3, wide NoIR)

Out-of-tree port of the Raspberry Pi `imx708.c` (rpi-6.1.y) to the
BeagleY-AI kernel `6.1.83-ti-arm64-r72.1cdev`, plus the CSI-0 device-tree
overlay. First light 2026-08-06 (module ID 0x0382, wide NoIR).

## Port deltas vs raspberrypi/linux
1. `MEDIA_BUS_FMT_SENSOR_DATA` shimmed (RPi-only uapi macro).
2. **Embedded-metadata pad removed.** TI 6.1 backports the V4L2 streams
   API; its `s_stream` fallback (`v4l2_subdev_enable_streams_fallback`)
   rejects sensors with more than one source pad with `EOPNOTSUPP`
   ("Failed to start streams 0x1 on subdev"). Nothing on TI consumes the
   RPi embedded-data pad, so it is compiled out.

## Build (on the kernel build host)
    make -C <kernel-tree> M=$PWD/imx708-driver ARCH=arm64 \
         CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION="-ti-arm64-r72.1cdev" modules
Install to `/lib/modules/6.1.83-ti-arm64-r72.1cdev/extra/` + `depmod -a`.
Compile the overlay in the kernel tree (`make ti/k3-am67a-beagley-ai-csi0-imx708.dtbo`)
and add it to the `fdtoverlays` line in `/boot/firmware/extlinux/extlinux.conf`.

## Capture bring-up (RAW10, no ISP in this path)
    media-ctl -V '"imx708_wide_noir":0 [fmt:SRGGB10_1X10/2304x1296]'
    media-ctl -V '"30102000.ticsi2rx":0 [fmt:SRGGB10_1X10/2304x1296]'   # does NOT propagate on its own
    v4l2-ctl -d /dev/video3 --set-fmt-video=width=2304,height=1296,pixelformat=RG10
    v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl exposure=1800,analogue_gain=500
    v4l2-ctl -d /dev/video3 --stream-mmap=4 --stream-count=8 --stream-to=frames.raw
`/dev/video3..8` are the six ti-csi2rx DMA contexts; use video3.
`debayer.py` renders a quick-look PNG from the RG10 dump (half-res,
grey-world WB) — the sensor has no auto-anything here; 3A is the host's job.

## Open
- Live pipeline into nn-camera needs a debayer stage (the WAVE5 encoder
  eats NV12, not Bayer): GStreamer `bayer2rgb` (CPU), GPU shader, or
  libcamera softISP — to be chosen.
- DW9817 autofocus (i2c 0x0c) unported; fixed focus for now.
