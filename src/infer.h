/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stdint.h>
#include <stddef.h>

/* Edge-inference glue: consumes RGB frames from the capture's "infer"
 * appsink branch, runs nn_infer on its own thread, rescales boxes to
 * stream space and ships 'D' records via the uplink.
 * frame geometry: src_w x src_h RGB888 (top-left of the model's padded
 * input); stream_w/h = the encoded video geometry boxes map onto. */
int  infer_start(const char *model_dir,
                 int src_w, int src_h, int stream_w, int stream_h);
/* capture thread hands frames here (copies; drops if busy) */
void infer_submit(const uint8_t *rgb, size_t len, uint64_t ts_ms);
int  infer_active(void);

/* Apply a pushed edge policy (JSON from the service).  Returns 0 or -errno.
 * Persisted so the camera keeps its rules across a restart even if the
 * service is down when it boots. */
int  infer_apply_config(const char *json, size_t len);
uint32_t infer_config_version(void);

/* Full engine status as JSON: model caps, self-test result and live counters.
 * Sent periodically so the hub can see how the engine is RUNNING, not just
 * that it exists -- the Debian build got this from nn-inferd's stats.json via
 * a separate reporter service, which went away with the python daemon. */
void infer_status_json(char *out, size_t n);
