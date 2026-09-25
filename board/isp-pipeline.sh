#!/bin/bash
# HW pipeline (runs INSIDE the edgeai container via lxc-attach):
#   IMX708 RAW10 -> VPAC VISS (tiovxisp, imx219 DCC baseline) -> VPAC MSC
#   -> 1920x1080 NV12 -> WAVE5 H.264 -> byte-stream on localhost TCP.
# The container shares the host network namespace (lxc.net.0.type = none),
# so nn-camera on the host reads tcp://127.0.0.1:5599.
PORT="${NN_ISP_PORT:-5599}"
BITRATE="${NN_CAM_BITRATE:-4000000}"
exec gst-launch-1.0 -e \
  v4l2src device=/dev/video3 io-mode=dmabuf ! \
  "video/x-bayer,format=rggb10,width=2304,height=1296" ! \
  tiovxisp sensor-name=SENSOR_SONY_IMX219_RPI \
    dcc-isp-file=/opt/imaging/imx219/linear/dcc_viss_10b_1920x1080.bin \
    format-msb=9 \
    sink_0::dcc-2a-file=/opt/imaging/imx219/linear/dcc_2a_10b.bin \
    sink_0::device=/dev/v4l-subdev2 ! \
  video/x-raw,format=NV12 ! \
  tiovxmultiscaler ! "video/x-raw,format=NV12,width=1920,height=1080" ! \
  v4l2h264enc extra-controls=controls,frame_level_rate_control_enable=1,video_bitrate=$BITRATE,video_gop_size=30,h264_i_frame_period=30 ! \
  "video/x-h264,stream-format=byte-stream,alignment=au" ! \
  h264parse config-interval=-1 ! "video/x-h264,stream-format=byte-stream" ! \
  tcpserversink host=127.0.0.1 port=$PORT sync=false
