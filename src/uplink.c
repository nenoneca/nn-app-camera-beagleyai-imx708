/* SPDX-License-Identifier: Apache-2.0 */
/* Encrypted record uplink — Linux (POSIX sockets + portable nn_sectun).
 *
 * A background thread owns the connection lifecycle: resolve (getaddrinfo, so
 * mDNS ".local" names work through nss-mdns) → TCP connect → nn_sectun
 * handshake against the service's X25519 stream key → then it BLOCKS in
 * nn_sectun_recv dispatching server→device control records.  Producers call
 * uplink_send_video() from the capture thread; sends are serialized by a
 * mutex (the ESP app learned this the hard way: interleaved writers desync
 * the host record parser permanently). */
#include "uplink.h"
#include <nn_sectun/nn_sectun.h>
#include <nn_osal/log.h>
#include <nn_osal/time.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <pthread.h>
#include <unistd.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/tcp.h>

NN_OSAL_LOG_MODULE(uplink);

#define FRAG_MAX 16384u   /* per-record payload cap, matches the ESP app */

static char            s_host[128];
static uint16_t        s_port;
static uint8_t         s_pub[32];
static uplink_ctrl_cb  s_ctrl_cb;
static void           *s_ctrl_user;

static nn_sectun_t     s_tun;
static int             s_fd = -1;
static volatile bool   s_up;
static pthread_mutex_t s_tx = PTHREAD_MUTEX_INITIALIZER;
static uint16_t        s_seq;
static char            s_status_json[256];
static unsigned long   s_tx_bytes, s_frames, s_drops;

static int dial(void)
{
    char ps[8];
    snprintf(ps, sizeof ps, "%u", s_port);
    struct addrinfo hints = { .ai_family = AF_UNSPEC, .ai_socktype = SOCK_STREAM };
    struct addrinfo *res = NULL;
    if (getaddrinfo(s_host, ps, &hints, &res) != 0 || !res) {
        NN_LOG_WRN("resolve %s failed", s_host);
        return -1;
    }
    int fd = -1;
    for (struct addrinfo *ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        struct timeval to = { .tv_sec = 10 };
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &to, sizeof to);
        int one = 1;
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd;
}

/* control records from the service's adaptive controller (video_service
 * StreamAdapt._send): [0xC7][cmd u8][value u32 BE] — cmd 1=bitrate 2=gop
 * 3=fps-div 4=force-IDR */
#define CTRL_MAGIC 0xC7u
#define CFG_MAGIC  0xC3u          /* JSON config push (service → device) */

static uplink_cfg_cb s_cfg_cb;
static void         *s_cfg_user;

void uplink_set_cfg_cb(uplink_cfg_cb cb, void *user)
{ s_cfg_cb = cb; s_cfg_user = user; }

/* {"v":N,...} — pull the version out without a JSON parser so the ack can
 * always name a version, even when the body is rejected. */
static uint32_t cfg_version_of(const char *j, size_t n)
{
    for (size_t i = 0; i + 4 < n; i++)
        if (j[i] == '"' && j[i+1] == 'v' && j[i+2] == '"' && j[i+3] == ':') {
            uint32_t v = 0;
            for (size_t k = i + 4; k < n && j[k] >= '0' && j[k] <= '9'; k++)
                v = v * 10 + (uint32_t)(j[k] - '0');
            return v;
        }
    return 0;
}

static void dispatch_cfg(const uint8_t *msg, size_t n)
{
    const char *json = (const char *)msg + 1;
    size_t len = n - 1;
    uint32_t v = cfg_version_of(json, len);
    if (!s_cfg_cb) { uplink_send_cfg_ack(v, false, "no handler"); return; }
    int rc = s_cfg_cb(json, len, s_cfg_user);
    uplink_send_cfg_ack(v, rc == 0, rc == 0 ? NULL : "apply failed");
    NN_LOG_INF("config v%u %s", v, rc == 0 ? "applied" : "REJECTED");
}

static void dispatch_ctrl(const uint8_t *msg, size_t n)
{
    if (n >= 2 && msg[0] == CFG_MAGIC) { dispatch_cfg(msg, n); return; }
    if (n < 6 || msg[0] != CTRL_MAGIC || !s_ctrl_cb) return;
    uint32_t val = ((uint32_t)msg[2] << 24) | ((uint32_t)msg[3] << 16) |
                   ((uint32_t)msg[4] << 8)  |  (uint32_t)msg[5];
    s_ctrl_cb(msg[1], val, s_ctrl_user);
}

static void *net_thread(void *arg)
{
    (void)arg;
    for (;;) {
        int fd = dial();
        if (fd < 0) { sleep(3); continue; }
        if (nn_sectun_client_handshake(&s_tun, fd, s_pub) != 0) {
            NN_LOG_WRN("sectun handshake failed (is this camera's pubkey "
                       "authorized in the service --keydir?)");
            close(fd); sleep(3); continue;
        }
        pthread_mutex_lock(&s_tx);
        s_fd = fd; s_up = true;
        pthread_mutex_unlock(&s_tx);
        NN_LOG_INF("uplink up: %s:%u (encrypted)", s_host, s_port);
        if (s_status_json[0])
            uplink_send_status(s_status_json);

        static uint8_t msg[2048]; size_t n;
        while (nn_sectun_recv(&s_tun, msg, sizeof msg, &n) == 0)
            dispatch_ctrl(msg, n);

        pthread_mutex_lock(&s_tx);
        s_up = false; s_fd = -1;
        pthread_mutex_unlock(&s_tx);
        close(fd);
        NN_LOG_WRN("uplink lost — reconnecting");
        sleep(2);
    }
    return NULL;
}

/* Send raw bytes through the tunnel in ≤(4096-overhead) plaintext slices.
 * Caller holds s_tx.  Returns 0 or -1 (connection considered dead). */
static int tun_write(const uint8_t *p, size_t len)
{
    const size_t MAXP = NN_SECTUN_RECORD_MAX - NN_SECTUN_OVERHEAD;
    while (len) {
        size_t n = len < MAXP ? len : MAXP;
        if (nn_sectun_send(&s_tun, p, n) != 0) return -1;
        p += n; len -= n;
        s_tx_bytes += n;
    }
    return 0;
}

static int send_record(uint8_t type, uint8_t flags, uint16_t seq,
                       uint64_t ts_ms, const uint8_t *payload, size_t len)
{
    uint8_t h[16];
    h[0] = type; h[1] = flags;
    h[2] = (uint8_t)(seq & 0xFF); h[3] = (uint8_t)(seq >> 8);
    for (int i = 0; i < 8; i++) h[4 + i] = (uint8_t)((ts_ms >> (8 * i)) & 0xFF);
    h[12] = (uint8_t)(len & 0xFF);         h[13] = (uint8_t)((len >> 8) & 0xFF);
    h[14] = (uint8_t)((len >> 16) & 0xFF); h[15] = (uint8_t)((len >> 24) & 0xFF);
    if (tun_write(h, sizeof h)) return -1;
    return len ? tun_write(payload, len) : 0;
}

void uplink_send_video(const uint8_t *au, size_t len, bool key, uint64_t ts_ms)
{
    pthread_mutex_lock(&s_tx);
    if (!s_up) { s_drops++; pthread_mutex_unlock(&s_tx); return; }
    uint16_t seq = s_seq++;
    size_t nfrag = (len + FRAG_MAX - 1) / FRAG_MAX;
    for (size_t f = 0; f < nfrag; f++) {
        size_t off  = f * FRAG_MAX;
        size_t plen = len - off < FRAG_MAX ? len - off : FRAG_MAX;
        uint8_t flags = (uint8_t)((key ? VID_KEY : 0) |
                                  (f == 0 ? VID_START : 0) |
                                  (f == nfrag - 1 ? VID_END : 0));
        if (send_record(NN_REC_VIDEO, flags, seq, ts_ms, au + off, plen)) {
            s_up = false;      /* net_thread notices via its recv and redials */
            break;
        }
    }
    s_frames++;
    pthread_mutex_unlock(&s_tx);
}

bool uplink_connected(void) { return s_up; }

void uplink_send_status(const char *json)
{
    size_t n = strlen(json);
    pthread_mutex_lock(&s_tx);
    if (s_up)
        send_record(NN_REC_STATUS, 0, s_seq++, 0, (const uint8_t *)json, n);
    pthread_mutex_unlock(&s_tx);
}

void uplink_send_detect(const uplink_det_t *dets, unsigned count,
                        uint64_t ts_ms)
{
    if (count > 32) count = 32;
    uint8_t pl[4 + 32 * 12];
    pl[0] = 0; pl[1] = (uint8_t)count; pl[2] = 0; pl[3] = 0;
    for (unsigned i = 0; i < count; i++) {
        const uint16_t v[6] = { dets[i].x, dets[i].y, dets[i].w, dets[i].h,
                                dets[i].class_id, dets[i].conf_x1000 };
        for (int j = 0; j < 6; j++) {
            pl[4 + i * 12 + j * 2]     = (uint8_t)(v[j] & 0xFF);
            pl[4 + i * 12 + j * 2 + 1] = (uint8_t)(v[j] >> 8);
        }
    }
    pthread_mutex_lock(&s_tx);
    if (s_up)
        send_record(NN_REC_DETECT, 0, s_seq++, ts_ms, pl, 4 + count * 12);
    pthread_mutex_unlock(&s_tx);
}

void uplink_send_cfg_ack(uint32_t version, bool applied, const char *err)
{
    char j[128];
    int n = snprintf(j, sizeof j, "{\"v\":%u,\"applied\":%s%s%s%s}",
                     version, applied ? "true" : "false",
                     err ? ",\"err\":\"" : "", err ? err : "",
                     err ? "\"" : "");
    pthread_mutex_lock(&s_tx);
    if (s_up)
        send_record(NN_REC_CFGACK, 0, s_seq++, 0, (const uint8_t *)j, (size_t)n);
    pthread_mutex_unlock(&s_tx);
}

void uplink_send_heartbeat(uint32_t up_s, uint32_t fps_x10, uint32_t drops,
                           uint32_t cfg_version)
{
    char j[128];
    int n = snprintf(j, sizeof j,
                     "{\"up_s\":%u,\"fps\":%u.%u,\"drops\":%u,\"v\":%u}",
                     up_s, fps_x10 / 10, fps_x10 % 10, drops, cfg_version);
    pthread_mutex_lock(&s_tx);
    if (s_up)
        send_record(NN_REC_HEART, 0, s_seq++, 0, (const uint8_t *)j, (size_t)n);
    pthread_mutex_unlock(&s_tx);
}

void uplink_stats(char *out, size_t cap)
{
    snprintf(out, cap, "up=%d host=%s:%u frames=%lu tx=%lukB drops=%lu",
             s_up ? 1 : 0, s_host, s_port, s_frames, s_tx_bytes / 1024, s_drops);
}

void uplink_set_status_json(const char *json)
{
    snprintf(s_status_json, sizeof s_status_json, "%s", json ? json : "");
}

int uplink_start(const char *host, uint16_t port, const uint8_t stream_pub[32],
                 uplink_ctrl_cb ctrl_cb, void *user)
{
    snprintf(s_host, sizeof s_host, "%s", host);
    s_port = port;
    memcpy(s_pub, stream_pub, 32);
    s_ctrl_cb = ctrl_cb; s_ctrl_user = user;
    pthread_t th;
    if (pthread_create(&th, NULL, net_thread, NULL) != 0) return -errno;
    pthread_detach(th);
    return 0;
}
