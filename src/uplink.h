/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>

/* Encrypted record uplink to the hub video service — the Linux counterpart of
 * nn_netstream's uplink half.  Network management belongs to the OS here, so
 * this is only: TCP connect → nn_sectun handshake → framed records.  The wire
 * format is byte-identical to the ESP cameras' (video_service RecordParser):
 *   [type u8][flags u8][seq u16 LE][ts_ms u64 LE][len u32 LE][payload] */

#define NN_REC_VIDEO  0x56u  /* 'V' */
#define NN_REC_AUDIO  0x41u  /* 'A' */
#define NN_REC_STATUS 0x53u  /* 'S' */
#define NN_REC_DETECT 0x44u  /* 'D' — edge inference (nn_infer DESIGN.md) */
#define NN_REC_CFGACK 0x4Bu  /* 'K' — ack of a pushed config */
#define NN_REC_HEART  0x48u  /* 'H' — heartbeat */

#define VID_KEY    0x01u
#define VID_START  0x02u
#define VID_END    0x04u

/* server → device control callback (cmd/val pairs, e.g. bitrate/gop) */
typedef void (*uplink_ctrl_cb)(uint8_t cmd, uint32_t val, void *user);

/* server → device JSON config (0xC3): policy + media-sink settings.  The
 * callback owns validation; return 0 when applied, -errno otherwise (the
 * reason is echoed back to the service in the ack). */
typedef int (*uplink_cfg_cb)(const char *json, size_t len, void *user);
void uplink_set_cfg_cb(uplink_cfg_cb cb, void *user);

/* Ack a config version (sent automatically by the cfg dispatcher). */
void uplink_send_cfg_ack(uint32_t version, bool applied, const char *err);

/* Heartbeat: liveness independent of video flow (a camera can be connected
 * and not streaming). */
void uplink_send_heartbeat(uint32_t up_s, uint32_t fps_x10, uint32_t drops,
                           uint32_t cfg_version);

int  uplink_start(const char *host, uint16_t port,
                  const uint8_t stream_pub[32],
                  uplink_ctrl_cb ctrl_cb, void *user);
bool uplink_connected(void);

/* Send one H.264 access unit, fragmented into records like the ESP app does.
 * ts_ms is the capture wall-clock (epoch ms).  Thread-safe. */
void uplink_send_video(const uint8_t *au, size_t len, bool key, uint64_t ts_ms);

void uplink_stats(char *out, size_t cap);

/* Send one JSON status record ('S') — used right after connect to advertise
 * capabilities ({"infer": {...}}).  Thread-safe. */
void uplink_send_status(const char *json);

/* Status JSON re-sent automatically on every (re)connect. */
void uplink_set_status_json(const char *json);

/* Send one detect record ('D'): [ver=0][count][rsvd u16] +
 * count x {u16 x,y,w,h,class_id,conf_x1000} LE — coords in STREAM space. */
typedef struct { uint16_t x, y, w, h, class_id, conf_x1000; } uplink_det_t;
void uplink_send_detect(const uplink_det_t *dets, unsigned count,
                        uint64_t ts_ms);
