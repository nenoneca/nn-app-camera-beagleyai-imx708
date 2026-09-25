/* SPDX-License-Identifier: Apache-2.0 */
/* Capture stub — builds nn-camera WITHOUT GStreamer (CI hosts, uplink-only
 * testing).  Produces no frames; the uplink still connects, handshakes and
 * accepts control records, which is exactly what an uplink E2E test needs. */
#include "capture_gst.h"
#include <nn_osal/log.h>
NN_OSAL_LOG_MODULE(capture);

static unsigned long s_frames;
unsigned long capture_frames(void) { return s_frames; }

int capture_start(const char *device, int width, int height, int bitrate,
                  capture_frame_cb cb, void *user)
{
    (void)device; (void)width; (void)height; (void)bitrate; (void)cb; (void)user;
    NN_LOG_WRN("capture STUB build — no frames will be produced");
    return 0;
}

void capture_stop(void) { }
