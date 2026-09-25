#!/bin/sh
# cam_run.sh -- runs INSIDE the edgeai container: camera capture + ISP +
# H.264 + edge inference, uplinked to the hub.
#
# Everything this needs comes from three places, none of them this file:
#   * provisioning  : /var/lib/nn/kv (bound in from the host's nn-data) --
#                     hub host/port, stream key, device identity.  Written by
#                     nn-setupd during BLE setup; nn-camera reads it itself.
#                     No REPLACE_WITH_* placeholders, no env file.
#   * the app       : /opt/nn-app/app/current  (this bundle)
#   * the model     : /opt/nn-app/models/current -> <model dir>
#                     User-swappable: point the symlink at another model_zoo
#                     style directory (model/*.onnx + artifacts/ + param.yaml)
#                     and restart nn-camera.  The TI engine does not change.
#
# Only shell builtins and what the trimmed container actually has: no
# media-ctl, no v4l2-ctl (host tools), and busybox applets only by the names
# they are linked as.  A missing tool fails this before the camera starts.
#
# Nothing here is a hardcoded device node.  On this SoC v4l2 numbering follows
# probe order and MOVES BETWEEN BOOTS (capture was video0 one boot, video2 the
# next); a wrong node does not error, it streams zero frames.  Resolve by name.
set -u

APP=/opt/nn-app/app/current
MODEL=/opt/nn-app/models/current
SENS_NAME=imx708_wide_noir

die() { echo "cam_run: $*" >&2; exit 1; }

# ── resolve nodes by name ───────────────────────────────────────────────
CAPTURE=""; SENSDEV=""
for v in /sys/class/video4linux/*; do
    n=$(cat "$v/name" 2>/dev/null) || continue
    case "$n" in
        "30102000.ticsi2rx context 0") CAPTURE=/dev/${v##*/} ;;
        "$SENS_NAME")                  SENSDEV=/dev/${v##*/} ;;
    esac
done
[ -n "$CAPTURE" ] || die "no video node named '30102000.ticsi2rx context 0' -- CSI bridge down?"
[ -n "$SENSDEV" ] || die "no v4l subdev named '$SENS_NAME' -- sensor did not probe?"
echo "cam_run: capture $CAPTURE, sensor $SENSDEV"

# The media graph (pads, capture format, startup exposure) is set up by the
# HOST in nn-cam-setup before this runs: the graph is the host's kernel object
# and the host has media-ctl/v4l2-ctl; this container deliberately does not.

# ── the model: optional, but if present it must be a whole one ───────────
INFER=""
if [ -e "$MODEL" ]; then
    [ -d "$MODEL/artifacts" ] && ls "$MODEL"/model/*.onnx >/dev/null 2>&1 \
        || die "$MODEL is not a model dir (needs model/*.onnx + artifacts/)"
    INFER="$MODEL"
    echo "cam_run: inference model $MODEL"
else
    echo "cam_run: no model at $MODEL -- streaming only"
fi

# ── the detector self-test ───────────────────────────────────────────────
# A reference frame (raw RGB888, exactly NN_INFER_SRC_W x H) with a known
# answer, run through the real engine at startup.  The device emits a 'D'
# record every cycle even when it detected nothing, so a camera looking at a
# blank wall and a camera whose detector is dead are indistinguishable on the
# wire -- this is what tells them apart.  Optional: an operator who swapped in
# their own model can drop the file and the camera still runs.
# The reference frame must be in the model's own input format.
if [ -n "$INFER" ] && [ -f "$MODEL/INPUT_GRAY8" ]; then
    SELFTEST="$APP/selftest.gray"
else
    SELFTEST="$APP/selftest.rgb"
fi
[ -n "$INFER" ] && [ -f "$SELFTEST" ] || SELFTEST=""

# ── ISP tuning ───────────────────────────────────────────────────────────
# TI ships no IMX708 DCC (tiovxisp knows six sensors and IMX708 is not one),
# so the ISP ran IMX219 tuning on an IMX708 and produced a strongly magenta
# picture: measured R/G 1.51, B/G 1.72 where the sensor's own raw is
# ~neutral (1.06 / 0.88).  packaging/mk-imx708-dcc.py derives a corrected
# VISS file from TI's; with it the mid-tones and highlights come out neutral
# (R/G 1.00, B/G 1.03 at luma 110-160).  See that script for the measurements,
# the DCC layout and what is still wrong (shadow pedestal, and the white
# balance is fixed for one illuminant because TI's 2A never adapts here).
#
# Overridable so a differently-lit deployment can ship its own file, and
# absent the file we fall back to TI's imx219 tuning rather than not starting.
DCC=${NN_ISP_DCC:-$APP/dcc_viss_imx708.bin}
[ -f "$DCC" ] || DCC=/opt/imaging/imx219/linear/dcc_viss_10b_1920x1080.bin
echo "cam_run: ISP tuning $DCC"

# ── the pipeline ─────────────────────────────────────────────────────────
PIPE="v4l2src device=$CAPTURE io-mode=dmabuf ! video/x-bayer,format=rggb10,width=2304,height=1296 \
 ! tiovxisp sensor-name=SENSOR_SONY_IMX219_RPI dcc-isp-file=$DCC format-msb=9 \
   sink_0::dcc-2a-file=/opt/imaging/imx219/linear/dcc_2a_10b_1920x1080.bin sink_0::device=$SENSDEV \
 ! video/x-raw,format=NV12 ! tiovxmultiscaler name=msc \
 msc.src_0 ! video/x-raw,format=NV12,width=1920,height=1080 \
 ! v4l2h264enc extra-controls=controls,frame_level_rate_control_enable=1,video_bitrate=2000000,video_gop_size=11 \
 ! video/x-h264,stream-format=byte-stream,alignment=au ! h264parse config-interval=-1 \
 ! video/x-h264,stream-format=byte-stream,alignment=au ! appsink name=out max-buffers=8 drop=true sync=false"
# A model that declares INPUT_GRAY8 takes the ISP's luma plane directly: no
# tiovxdlcolorconvert, and the app copies Y instead of building interleaved
# RGB.  Anything else keeps the colour-convert branch.
if [ -n "$INFER" ]; then
    if [ -f "$MODEL/INPUT_GRAY8" ]; then
        echo "cam_run: model takes GRAY8 -- feeding the ISP luma plane, no colour convert"
        PIPE="$PIPE msc.src_1 ! video/x-raw,format=NV12,width=640,height=360 \
 ! appsink name=infer max-buffers=2 drop=true sync=false"
    else
        PIPE="$PIPE msc.src_1 ! video/x-raw,format=NV12,width=640,height=360 ! tiovxdlcolorconvert \
 ! video/x-raw,format=RGB ! appsink name=infer max-buffers=2 drop=true sync=false"
    fi
fi

# LD_PRELOAD: TI's libtivision_apps opens /dev/remoteproc0 by literal path,
# but remoteproc indices follow probe order; the shim resolves the C7x by
# NAME instead (rproc_byname.c).
# ...and, when the bundle carries it, the IMX219->IMX708 AE gain translation
# (imx708_gain_shim.c): without it the auto-exposure tops out at ~1.3x gain and
# a dim scene is simply black.
PRELOAD="$APP/librproc_byname.so"
[ -f "$APP/libimx708_gain.so" ] && PRELOAD="$PRELOAD:$APP/libimx708_gain.so"
exec env LD_PRELOAD="$PRELOAD" \
  GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0 \
  GST_PLUGIN_SCANNER=/usr/libexec/gstreamer-1.0/gst-plugin-scanner \
  NN_OSAL_KV_DIR=/var/lib/nn/kv \
  ${INFER:+NN_INFER_MODEL="$INFER"} NN_INFER_SRC_W=640 NN_INFER_SRC_H=360 \
  ${SELFTEST:+NN_INFER_SELFTEST="$SELFTEST"} \
  ${NN_INFER_TIDL_DEBUG:+NN_INFER_TIDL_DEBUG="$NN_INFER_TIDL_DEBUG"} \
  NN_CAM_PIPELINE="$PIPE" "$APP/nn-camera"
