/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/* One H.264 access unit from the encoder.  ts_ms is epoch milliseconds. */
typedef void (*capture_frame_cb)(const uint8_t *au, size_t len, bool key,
                                 uint64_t ts_ms, void *user);

int  capture_start(const char *device, int width, int height, int bitrate,
                   capture_frame_cb cb, void *user);
void capture_stop(void);
unsigned long capture_frames(void);

/* Accumulated sensor->infer-appsink latency (ISP + multiscaler + colour
 * convert), and the number of samples it covers. */
void capture_infer_latency(unsigned long long *sum_us, unsigned long long *n);
/* The same buffer-age measurement on the ENCODE appsink, as a control. */
void capture_out_latency(unsigned long long *sum_us, unsigned long long *n);
