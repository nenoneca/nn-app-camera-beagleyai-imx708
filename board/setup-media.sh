#!/bin/bash
# BeagleY-AI: configure the IMX708 -> CSI capture path (run at boot, as root).
set -e
media-ctl -V '"imx708_wide_noir":0 [fmt:SRGGB10_1X10/2304x1296]'
media-ctl -V '"30102000.ticsi2rx":0 [fmt:SRGGB10_1X10/2304x1296]'
v4l2-ctl -d /dev/video3 --set-fmt-video=width=2304,height=1296,pixelformat=RG10
# Startup exposure; the tiovxisp 2A loop takes over from here.
v4l2-ctl -d /dev/v4l-subdev2 --set-ctrl exposure=1600,analogue_gain=400 || true
