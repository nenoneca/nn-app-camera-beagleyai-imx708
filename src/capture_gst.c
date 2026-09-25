/* SPDX-License-Identifier: Apache-2.0 */
/* Capture + encode — GStreamer (V4L2 IMX708 in, WAVE5 V4L2 M2M H.264 out).
 *
 * The default pipeline targets the BeagleY-AI: TI CSI-RX capture from the
 * IMX708 (our kernel driver, AE/AWB in-driver) into the WAVE5 hardware
 * encoder.  Every board plumbs media-ctl a little differently, so the WHOLE
 * pipeline string is overridable via NN_CAM_PIPELINE — it must end in an
 * appsink named "out" delivering byte-stream H.264 with config headers at
 * every IDR (h264parse config-interval=-1 does that).
 *
 * Timestamps: Linux has a real clock, so records carry true epoch ms — the
 * hub's capture-time badge shows wall-clock for this camera from day one. */
#include "capture_gst.h"
#include "infer.h"
#include <nn_osal/log.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

NN_OSAL_LOG_MODULE(capture);

/* frame_level_rate_control_enable defaults to 0 on WAVE5 — without it the
 * encoder ignores video_bitrate entirely and emits fixed QP 30 (~7 Mbps on
 * busy 720p content), which drowns constrained uplinks. */
#define DEFAULT_PIPELINE \
    "v4l2src device=%s io-mode=dmabuf ! " \
    "video/x-raw,width=%d,height=%d,framerate=30/1 ! " \
    "v4l2h264enc extra-controls=controls,frame_level_rate_control_enable=1," \
        "video_bitrate=%d,h264_i_frame_period=30 ! " \
    "video/x-h264,stream-format=byte-stream,alignment=au ! " \
    "h264parse config-interval=-1 ! " \
    "appsink name=out max-buffers=8 drop=true sync=false"

static capture_frame_cb s_cb;
static void            *s_user;
static GstElement      *s_pipe;
static unsigned long    s_frames;

/* Profiling: the inference buffer's age at the appsink, against the pipeline
 * clock.  Everything upstream of the app is inside it.
 *
 * TREAT THE ABSOLUTE VALUE WITH SUSPICION.  It reads ~346 ms and does NOT
 * respond to the two things that would move real queueing latency: doubling
 * the drain rate (2.5 -> 5 fps inference) moved it by 10 ms, and cutting the
 * appsink queue from 2 buffers to 1 moved it by 0.5 ms.  So it is not this
 * appsink's queue and not our consumption rate.  ~346 ms is about 3.6 frame
 * intervals at 10.5 fps, which fits an upstream v4l2 capture pool; it would
 * equally fit a constant offset between the buffer PTS timebase and the
 * pipeline clock, which would make it a measurement artefact rather than
 * latency.  Those two have not been told apart -- do that before quoting this
 * as pipeline latency (a second measurement point on the encode appsink, or
 * the negotiated v4l2 pool size, would settle it). */
static unsigned long long s_inf_lat_us, s_inf_lat_n;
/* Same measurement on the ENCODE appsink.  If both branches report the same
 * age, the number is systematic (a PTS/clock offset) and not latency. */
static unsigned long long s_out_lat_us, s_out_lat_n;

static void note_age(GstBuffer *b, unsigned long long *sum, unsigned long long *n)
{
    GstClockTime pts = GST_BUFFER_PTS(b);
    if (!GST_CLOCK_TIME_IS_VALID(pts) || !s_pipe) return;
    GstClock *clk = gst_element_get_clock(s_pipe);
    if (!clk) return;
    GstClockTime base = gst_element_get_base_time(s_pipe);
    GstClockTime now  = gst_clock_get_time(clk);
    if (now > base + pts) { *sum += (now - base - pts) / 1000; (*n)++; }
    gst_object_unref(clk);
}

void capture_infer_latency(unsigned long long *sum_us, unsigned long long *n)
{
    *sum_us = s_inf_lat_us; *n = s_inf_lat_n;
}

void capture_out_latency(unsigned long long *sum_us, unsigned long long *n)
{
    *sum_us = s_out_lat_us; *n = s_out_lat_n;
}

static uint64_t epoch_ms_now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    return (uint64_t)ts.tv_sec * 1000 + (uint64_t)ts.tv_nsec / 1000000;
}

static GstFlowReturn on_sample(GstAppSink *sink, gpointer user)
{
    (void)user;
    GstSample *s = gst_app_sink_pull_sample(sink);
    if (!s) return GST_FLOW_ERROR;
    GstBuffer *b = gst_sample_get_buffer(s);
    GstMapInfo m;
    if (b && gst_buffer_map(b, &m, GST_MAP_READ)) {
        note_age(b, &s_out_lat_us, &s_out_lat_n);
        bool key = !GST_BUFFER_FLAG_IS_SET(b, GST_BUFFER_FLAG_DELTA_UNIT);
        if (s_cb) s_cb(m.data, m.size, key, epoch_ms_now(), s_user);
        s_frames++;
        gst_buffer_unmap(b, &m);
    }
    gst_sample_unref(s);
    return GST_FLOW_OK;
}

static GstFlowReturn on_infer_sample(GstAppSink *sink, gpointer user)
{
    (void)user;
    GstSample *s = gst_app_sink_pull_sample(sink);
    if (!s) return GST_FLOW_ERROR;
    GstBuffer *b = gst_sample_get_buffer(s);
    GstMapInfo m;
    if (b && gst_buffer_map(b, &m, GST_MAP_READ)) {
        note_age(b, &s_inf_lat_us, &s_inf_lat_n);
        infer_submit(m.data, m.size, epoch_ms_now());
        gst_buffer_unmap(b, &m);
    }
    gst_sample_unref(s);
    return GST_FLOW_OK;
}

unsigned long capture_frames(void) { return s_frames; }

int capture_start(const char *device, int width, int height, int bitrate,
                  capture_frame_cb cb, void *user)
{
    s_cb = cb; s_user = user;
    gst_init(NULL, NULL);

    char desc[1024];
    const char *override = getenv("NN_CAM_PIPELINE");
    if (override && *override)
        snprintf(desc, sizeof desc, "%s", override);
    else
        snprintf(desc, sizeof desc, DEFAULT_PIPELINE,
                 device, width, height, bitrate);
    NN_LOG_INF("pipeline: %s", desc);

    GError *err = NULL;
    s_pipe = gst_parse_launch(desc, &err);
    if (!s_pipe) {
        NN_LOG_ERR("pipeline parse: %s", err ? err->message : "?");
        if (err) g_error_free(err);
        return -1;
    }
    GstElement *isink = gst_bin_get_by_name(GST_BIN(s_pipe), "infer");
    if (isink) {
        GstAppSinkCallbacks ic = { .new_sample = on_infer_sample };
        gst_app_sink_set_callbacks(GST_APP_SINK(isink), &ic, NULL, NULL);
        gst_object_unref(isink);
        NN_LOG_INF("infer branch attached (appsink \"infer\")");
    }
    GstElement *sink = gst_bin_get_by_name(GST_BIN(s_pipe), "out");
    if (!sink) {
        NN_LOG_ERR("pipeline has no appsink named \"out\"");
        capture_stop();                 /* see below: must not leak the pipeline */
        return -1;
    }
    GstAppSinkCallbacks cbs = { .new_sample = on_sample };
    gst_app_sink_set_callbacks(GST_APP_SINK(sink), &cbs, NULL, NULL);
    gst_object_unref(sink);

    if (gst_element_set_state(s_pipe, GST_STATE_PLAYING)
            == GST_STATE_CHANGE_FAILURE) {
        NN_LOG_ERR("pipeline refused to start (check media-ctl setup / "
                   "NN_CAM_PIPELINE)");
        /*
         * Tear the pipeline down before returning.  tiovxisp holds a TIOVX
         * context in memory shared with the C7x firmware, and that context
         * is released by the element's transition to GST_STATE_NULL -- NOT
         * by the process exiting.  Leaving it to exit leaks a context per
         * attempt, so a restart loop walks the shared descriptor pool to
         * exhaustion ("Exceeded max object descriptors"), after which
         * vxCreateContext fails and EVERY later start fails for a reason
         * unrelated to the first.  Only a reboot reclaims them.
         * Cost us cam4 at 1169 restarts.
         */
        capture_stop();
        return -1;
    }
    return 0;
}

void capture_stop(void)
{
    if (s_pipe) {
        gst_element_set_state(s_pipe, GST_STATE_NULL);
        gst_object_unref(s_pipe);
        s_pipe = NULL;
    }
}
