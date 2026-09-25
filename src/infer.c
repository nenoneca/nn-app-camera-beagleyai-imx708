/* SPDX-License-Identifier: Apache-2.0 */
#include "infer.h"
#include "uplink.h"
#include "capture_gst.h"
#include <nn_infer/nn_infer.h>
#include <nn_infer/policy.h>
#include <nn_osal/storage.h>
#include <nn_osal/time.h>
#include <nn_osal/log.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <time.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

NN_OSAL_LOG_MODULE(infer);

static nn_infer_caps_t s_caps;
static int s_src_w, s_src_h, s_stream_w, s_stream_h;
static int s_active;

/* Per-class policy, indexed by model class id (the wire carries ids, so no
 * name lookup is needed on the device — the hub resolves names). */
#define INFER_MAX_CLASSES 96
static nn_infer_class_state_t s_pol[INFER_MAX_CLASSES];
static bool     s_pol_on[INFER_MAX_CLASSES];
static uint32_t s_cfg_ver;
/* Inference rate cap (policy "fps", 1..15): the pipeline may hand us 30
 * frames a second; running TIDL on all of them burns the C7x for nothing
 * and shrinks the time window `agg` actually covers. */
static uint32_t s_min_period_ms = 200;      /* 5 fps default */
static uint64_t s_last_infer_ms;
static pthread_mutex_t s_pol_mx = PTHREAD_MUTEX_INITIALIZER;

/* Engine telemetry.  The Debian build reported per-camera inference stats to
 * the hub from nn-inferd's stats.json via a second service
 * (nn-inferd-report.service -> POST /api/v1/inferd/stats).  Retiring the
 * python daemon for in-process TIDL took the numbers with it: this build
 * counted nothing at all, so the hub could see THAT a camera infers but never
 * how often, how fast, or how much it was dropping.
 *
 * Counted here instead and published in the status record the service already
 * parses -- no second daemon, no second socket, and it cannot disagree with
 * the engine because it IS the engine.
 *
 * Plain longs on purpose: these are telemetry, a torn read costs one wrong
 * sample in a 10 s report and is not worth a lock on the inference path. */
static unsigned long s_runs;        /* completed inferences               */
static unsigned long s_fails;       /* nn_infer_run returned non-zero     */
static unsigned long s_drop_busy;   /* frame arrived while one was in flight */
static unsigned long s_drop_rate;   /* frame refused by the fps cap       */
static unsigned long s_drop_inflight;/* engine still holds the last frame  */
static unsigned long s_offered;     /* frames the pipeline handed us       */
static uint64_t      s_last_sub_ms; /* previous submit, for the credit     */
static long          s_credit_ms;   /* leaky bucket, see infer_submit      */
static unsigned long s_last_ms;     /* duration of the last inference     */
static double        s_ewma_ms;     /* smoothed, so one slow run is visible
                                       without swamping the average       */
static char s_caps_json[224];       /* composed once at start             */

/* Per-stage profile, microseconds, accumulated.  ms/ms_avg above time
 * nn_infer_run only; these cover the whole path from the appsink to a 'D'
 * record so the cost can be attributed instead of guessed. */
static unsigned long long s_us_pack, s_us_queue, s_us_run, s_us_post, s_prof_n;

static uint64_t us_now(void)
{
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000000 + (uint64_t)t.tv_nsec / 1000;
}
static char s_selftest_json[96];    /* "" when no self-test ran           */

static pthread_mutex_t s_mx = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  s_cv = PTHREAD_COND_INITIALIZER;
static uint8_t        *s_pending;      /* model-input-sized frame, owned here */
static uint64_t        s_pending_ts;
static uint64_t        s_pending_us;      /* when infer_submit accepted it */
static int             s_have;

static void *infer_thread(void *arg)
{
    (void)arg;
    const size_t fsz = (size_t)s_caps.width * s_caps.height *
                       (s_caps.format == NN_INFER_FMT_GRAY8 ? 1 : 3);
    /* Second half of the ping-pong pair.  Pre-filled with the pad value once,
     * like s_pending, because pack_input() no longer rewrites the padding. */
    uint8_t *work = malloc(fsz);
    if (work) memset(work, 114, fsz);
    for (;;) {
        pthread_mutex_lock(&s_mx);
        while (!s_have) pthread_cond_wait(&s_cv, &s_mx);
        /* SWAP, never copy.  This used to memcpy the whole model input --
         * 640x640x3 = 1.2 MB of identical bytes -- on every single inference,
         * purely so the producer could refill while the engine ran.  Two
         * buffers and a pointer exchange give exactly the same guarantee for
         * nothing: the producer fills one while the engine reads the other,
         * and they trade under the lock that already serialises them. */
        uint8_t *swap = work;
        work = s_pending;
        s_pending = swap;
        uint64_t ts = s_pending_ts;
        uint64_t t_queued = s_pending_us;
        s_have = 0;
        pthread_mutex_unlock(&s_mx);
        uint64_t t_pick = us_now();

        nn_infer_input_t in = { .buf = nn_osal_buf_mem(work, fsz), .ts_ms = ts };
        nn_infer_result_t out;
        uint64_t t_begin = nn_osal_uptime_ms();
        uint64_t u_begin = us_now();
        if (nn_infer_run(&in, &out) != 0) { s_fails++; continue; }
        uint64_t u_ran = us_now();
        s_last_ms = (unsigned long)(nn_osal_uptime_ms() - t_begin);
        s_runs++;
        s_ewma_ms = s_ewma_ms ? (s_ewma_ms * 0.9 + s_last_ms * 0.1) : s_last_ms;

        /* model space → stream space: content occupies src_w x src_h at the
         * top-left (corner-anchored pad); scale = stream_w / src_w */
        float sx = (float)s_stream_w / (float)s_src_w;
        float sy = (float)s_stream_h / (float)s_src_h;
        /* Policy: feed EVERY configured class this frame (absent = 0) so the
         * aggregate decays and the stop threshold can fire; then report the
         * frame's detections plus which classes are in capture state. */
        uint16_t best[INFER_MAX_CLASSES] = {0};
        for (int i = 0; i < out.count; i++)
            if (out.det[i].class_id < INFER_MAX_CLASSES &&
                out.det[i].conf_x1000 > best[out.det[i].class_id])
                best[out.det[i].class_id] = out.det[i].conf_x1000;
        pthread_mutex_lock(&s_pol_mx);
        for (int c = 0; c < INFER_MAX_CLASSES; c++) {
            if (!s_pol_on[c]) continue;
            bool changed = false;
            nn_infer_policy_feed(&s_pol[c], best[c], &changed);
            if (changed)
                NN_LOG_INF("class %d -> %s", c,
                           nn_infer_policy_detected(&s_pol[c]) ? "DETECT" : "clear");
        }
        pthread_mutex_unlock(&s_pol_mx);

        uplink_det_t d[NN_INFER_MAX_DET];
        unsigned n = 0;
        for (int i = 0; i < out.count; i++) {
            const nn_infer_det_t *t = &out.det[i];
            if (t->x >= s_src_w || t->y >= s_src_h) continue;   /* pad noise */
            d[n].x = (uint16_t)(t->x * sx);
            d[n].y = (uint16_t)(t->y * sy);
            d[n].w = (uint16_t)(t->w * sx);
            d[n].h = (uint16_t)(t->h * sy);
            d[n].class_id = t->class_id;
            d[n].conf_x1000 = t->conf_x1000;
            n++;
        }
        uplink_send_detect(d, n, ts);
        s_us_queue += t_pick - t_queued;
        s_us_run   += u_ran - u_begin;
        s_us_post  += us_now() - u_ran;
        s_prof_n++;
    }
    return NULL;
}

/* Place src rows top-left of the model's padded input and pad the rest with
 * 114 (param.yaml: resize_with_pad [true, corner], pad_color 114).
 *
 * BGR swap for the model happens in the PAL's NCHW pass — it treats channel 0
 * as B; we feed RGB here so swap indices there.  To keep the PAL simple it
 * expects BGR888: swap R/B while copying.
 *
 * Shared by the live path and infer_start()'s self-test ON PURPOSE: a
 * self-test that packed its input even slightly differently from the live
 * path would prove the engine works on an input the camera never produces. */
static void pack_input(uint8_t *dst, const uint8_t *rgb, size_t len)
{
    if (s_caps.format == NN_INFER_FMT_GRAY8) {
        /* The model takes a single luma plane, so the ISP's Y plane IS the
         * tensor: no colour convert upstream, no interleave, no channel swap.
         * NV12 puts Y first and contiguous, and the model's row stride equals
         * the source width here, so the content is ONE memcpy -- 230 KB
         * instead of touching 1.38 MB with a per-pixel swap, and the PAL then
         * hands this buffer to ORT untouched.
         * The pad rows below src_h were filled with 114 once at allocation. */
        const size_t row = (size_t)s_src_w;              /* 1 byte per pixel */
        size_t rows = len / row;
        if (rows > (size_t)s_src_h) rows = (size_t)s_src_h;
        if ((size_t)s_caps.width == row) {
            memcpy(dst, rgb, rows * row);                /* strides match */
        } else {
            for (size_t y = 0; y < rows; y++)
                memcpy(dst + y * s_caps.width, rgb + y * row, row);
        }
        for (size_t y = rows; y < (size_t)s_src_h; y++)  /* short frame */
            memset(dst + y * s_caps.width, 114, row);
        return;
    }

    const size_t row   = (size_t)s_src_w * 3;
    const size_t dstep = (size_t)s_caps.width * 3;
    /* The pad is CONSTANT: rows below src_h, and the columns right of src_w,
     * are 114 for the life of the buffer.  Both buffers are filled with 114
     * once at allocation, so re-running memset over the whole 1.2 MB input on
     * every frame was rewriting ~0.5 MB of bytes that already held that value.
     * Only the content region is written here. */
    int y = 0;
    for (; y < s_src_h && (size_t)(y + 1) * row <= len; y++) {
        const uint8_t *src = rgb + (size_t)y * row;
        uint8_t *d = dst + (size_t)y * dstep;
        int x = 0;
#if defined(__aarch64__)
        /* The scalar loop below cost 16.4 ms per frame -- 18% of the whole
         * inference path -- moving 1.38 MB at only ~84 MB/s, because a
         * three-byte stride defeats the vectoriser.  NEON has the exact
         * instruction for this: vld3q_u8 deinterleaves RGBRGB... into three
         * planes, so swapping R and B is just exchanging two registers
         * before vst3q_u8 puts them back.  16 pixels per iteration. */
        for (; x + 16 <= s_src_w; x += 16) {
            uint8x16x3_t v = vld3q_u8(src + (size_t)x * 3);
            uint8x16_t t = v.val[0];
            v.val[0] = v.val[2];
            v.val[2] = t;
            vst3q_u8(d + (size_t)x * 3, v);
        }
#endif
        for (; x < s_src_w; x++) {          /* tail, and non-aarch64 */
            d[x * 3]     = src[x * 3 + 2];
            d[x * 3 + 1] = src[x * 3 + 1];
            d[x * 3 + 2] = src[x * 3];
        }
    }
    /* A SHORT frame must not leave the previous frame's pixels in the rows it
     * did not fill: with the blanket memset gone, those rows would otherwise
     * still hold content from two frames ago (the buffers ping-pong). */
    for (; y < s_src_h; y++)
        memset(dst + (size_t)y * dstep, 114, row);
}

void infer_submit(const uint8_t *rgb, size_t len, uint64_t ts_ms)
{
    if (!s_active) return;
    s_offered++;
    uint64_t now = nn_osal_uptime_ms();

    /* Rate limiting by CREDIT, not by a minimum interval.
     *
     * This used to be `if (now - last < period) drop`, which cannot deliver
     * the configured rate unless the source is an exact multiple of it.  The
     * infer branch hands us ~7.5 fps (133 ms apart) and the 5 fps policy is a
     * 200 ms period: accept at 0, 133 is "too soon" so it is dropped, 266 is
     * accepted -- one per 266 ms, a 3.76 fps CEILING, measured at 2.5 fps
     * once jitter and engine occupancy are included.  Reaching 5 fps from
     * 7.5 fps requires taking two frames of every three (133/133/267 ms),
     * which a hard minimum-interval gate forbids by construction.
     *
     * A bucket that earns `elapsed` and spends `period` per accepted frame
     * holds the AVERAGE rate instead, so the configured fps is what comes
     * out.  Credit is capped at two periods so a stall cannot bank enough to
     * dump a burst into the engine afterwards, and is spent only when a frame
     * is really accepted -- never for one the engine was too busy to take. */
    long elapsed = s_last_sub_ms ? (long)(now - s_last_sub_ms) : (long)s_min_period_ms;
    s_last_sub_ms = now;
    s_credit_ms += elapsed;
    if (s_credit_ms > 2 * (long)s_min_period_ms)
        s_credit_ms = 2 * (long)s_min_period_ms;
    if (s_credit_ms < (long)s_min_period_ms) { s_drop_rate++; return; }

    if (pthread_mutex_trylock(&s_mx) != 0) { s_drop_busy++; return; }  /* busy */
    if (!s_have) {
        uint64_t t0 = us_now();
        pack_input(s_pending, rgb, len);
        s_us_pack += us_now() - t0;
        s_pending_ts = ts_ms;
        s_pending_us = us_now();
        s_credit_ms -= (long)s_min_period_ms;   /* spent only on acceptance */
        s_last_infer_ms = now;
        s_have = 1;
        pthread_cond_signal(&s_cv);
    } else {
        /* The engine still holds the previous frame.  This path was silent:
         * it counted as neither a rate drop nor a busy drop, so frames
         * vanished from the accounting entirely. */
        s_drop_inflight++;
    }
    pthread_mutex_unlock(&s_mx);
}

uint32_t infer_config_version(void) { return s_cfg_ver; }

/* The whole engine status in one document: what the model is, what the
 * self-test found, and how the engine is actually running.
 *
 * Composed in ONE place because the service replaces cam_settings wholesale
 * with each status record -- emitting only the live stats periodically would
 * silently drop the caps and the self-test result from the hub's view, which
 * is the endpoint a test now relies on. */
void infer_status_json(char *out, size_t n)
{
    /* Gate on the caps having been composed, NOT on s_active: infer_start
     * publishes the first status before the worker thread exists, and if
     * pthread_create then fails the engine is not active and must not be
     * reported as such. */
    if (!s_caps_json[0]) { snprintf(out, n, "{}"); return; }

    /* Mean microseconds per inference for each stage of the path, so the
     * 74 ms can be attributed rather than guessed:
     *   pts_age  raw PTS-to-clock delta at each appsink.  NOT latency: the
     *            infer and encode branches read within 0.7% of each other
     *            (406.7 vs 409.5 ms) despite doing completely different work,
     *            and the value moved 346 -> 407 ms across restarts.  Two
     *            unrelated branches agreeing, and drift across runs, mean a
     *            common-mode PTS/base-time offset, not per-branch delay.
     *            Kept only because a DIVERGENCE between the two would be a
     *            real per-branch backlog; never quote the absolute value.
     *   pack   corner-pad + BGR swap into the model input (capture thread)
     *   queue  accepted -> picked up by the inference thread
     *   run    nn_infer_run: ORT/TIDL marshalling + the C7x itself
     *   post   box rescale, policy, 'D' record
     * Everything but `isp` is serial on one frame; `isp` is pipeline latency. */
    char prof[192] = "";
    unsigned long long lat_us = 0, lat_n = 0, olat_us = 0, olat_n = 0;
    capture_infer_latency(&lat_us, &lat_n);
    capture_out_latency(&olat_us, &olat_n);
    if (s_prof_n)
        snprintf(prof, sizeof prof,
                 ",\"prof_us\":{\"pts_age\":%llu,\"pts_age_enc\":%llu,\"pack\":%llu,"
                 "\"queue\":%llu,\"run\":%llu,\"post\":%llu,\"n\":%llu}",
                 lat_n ? lat_us / lat_n : 0ULL,
                 olat_n ? olat_us / olat_n : 0ULL,
                 s_us_pack / s_prof_n, s_us_queue / s_prof_n,
                 s_us_run / s_prof_n, s_us_post / s_prof_n, s_prof_n);
    snprintf(out, n,
             "{%s%s%s,\"instats\":{\"runs\":%lu,\"fails\":%lu,"
             "\"drop_busy\":%lu,\"drop_rate\":%lu,\"drop_inflight\":%lu,"
             "\"offered\":%lu,\"ms\":%lu,\"ms_avg\":%.1f,"
             "\"fps_cap\":%u}%s}",
             s_caps_json,
             s_selftest_json[0] ? "," : "", s_selftest_json,
             s_runs, s_fails, s_drop_busy, s_drop_rate, s_drop_inflight,
             s_offered, s_last_ms, s_ewma_ms,
             s_min_period_ms ? (unsigned)(1000 / s_min_period_ms) : 0,
             prof);
}

/* Minimal scanner for {"v":N,"classes":{"<id|name>":{"capture":b,"agg":N,
 * "start":f,"stop":f},...}} — a full JSON parser is not worth the flash on
 * the MCU sibling of this app, and the producer is our own service. */
static bool jnum(const char *j, size_t n, size_t at, const char *key, double *out)
{
    size_t kl = strlen(key);
    for (size_t i = at; i + kl + 3 < n; i++) {
        if (j[i] != '"' || strncmp(j + i + 1, key, kl) || j[i + 1 + kl] != '"')
            continue;
        size_t k = i + 2 + kl;
        while (k < n && (j[k] == ':' || j[k] == ' ')) k++;
        if (k < n && (j[k] == 't' || j[k] == 'f')) { *out = j[k] == 't'; return true; }
        char buf[32]; size_t b = 0;
        while (k < n && b < sizeof buf - 1 &&
               ((j[k] >= '0' && j[k] <= '9') || j[k] == '.' || j[k] == '-'))
            buf[b++] = j[k++];
        if (!b) return false;
        buf[b] = 0; *out = atof(buf); return true;
    }
    return false;
}

int infer_apply_config(const char *json, size_t len)
{
    if (!json || !len) return -EINVAL;
    double v = 0, fps = 5;
    jnum(json, len, 0, "v", &v);
    if (jnum(json, len, 0, "fps", &fps)) {
        if (fps < 1) fps = 1;
        if (fps > 15) fps = 15;
    }

    nn_infer_class_state_t np[INFER_MAX_CLASSES];
    bool on[INFER_MAX_CLASSES] = {false};
    memset(np, 0, sizeof np);

    const char *cls = strstr(json, "\"classes\"");
    if (cls) {
        const char *p = cls;
        while ((p = strchr(p + 1, '"')) != NULL) {
            /* key: either a numeric class id or a name we can't resolve —
             * ids are what the wire uses, names are skipped (the hub sends
             * ids to devices). */
            if (p[1] < '0' || p[1] > '9') { p = strchr(p + 1, '"'); if (!p) break; continue; }
            int id = atoi(p + 1);
            const char *obj = strchr(p, '{');
            if (!obj || id < 0 || id >= INFER_MAX_CLASSES) break;
            size_t off = (size_t)(obj - json);
            double cap = 1, agg = 5, st = 0.6, sp = 0.4;
            jnum(json, len, off, "capture", &cap);
            jnum(json, len, off, "agg", &agg);
            jnum(json, len, off, "start", &st);
            jnum(json, len, off, "stop", &sp);
            if (cap) {
                nn_infer_class_policy_t cfg = {
                    .capture = true, .agg = (uint8_t)agg,
                    .start_x1000 = (uint16_t)(st * 1000 + 0.5),
                    .stop_x1000 = (uint16_t)(sp * 1000 + 0.5) };
                nn_infer_policy_set(&np[id], &cfg);
                on[id] = true;
            }
            const char *end = strchr(obj, '}');
            if (!end) break;
            p = end;
        }
    }
    pthread_mutex_lock(&s_pol_mx);
    memcpy(s_pol, np, sizeof s_pol);
    memcpy(s_pol_on, on, sizeof s_pol_on);
    s_cfg_ver = (uint32_t)v;
    s_min_period_ms = (uint32_t)(1000.0 / fps + 0.5);
    pthread_mutex_unlock(&s_pol_mx);

    /* persist so the rules survive a restart with the service down */
    /* keys are "namespace/key" (nn_osal POSIX/NVS both) — a flat key is
     * -EINVAL, which would silently lose the config across a restart */
    int krc = nn_osal_kv_save("infer/cfg", json, len > 1024 ? 1024 : len);
    if (krc) NN_LOG_WRN("policy not persisted: %d", krc);
    NN_LOG_INF("edge policy v%u applied (max %d fps, %u ms period)",
               s_cfg_ver, (int)fps, s_min_period_ms);
    return 0;
}

int infer_active(void) { return s_active; }

/* Run a known reference frame through the REAL engine and report what came
 * back, as compact JSON for the status the hub already collects.
 *
 * Why this exists: "inference is up" was being inferred from records arriving,
 * and the device emits a 'D' record every cycle even when it found nothing
 * (count=0).  A camera pointed at a blank wall and a camera whose detector is
 * silently broken produce byte-identical uplink traffic, so every check we had
 * passed in both cases.  A reference frame with a known answer is the only
 * thing on a running camera that tells the two apart.
 *
 * Called from infer_start BEFORE the worker thread exists, so it cannot race
 * the live path for the engine.
 *
 * The file is raw RGB888, exactly src_w x src_h -- no decoder, so the check
 * cannot fail for a reason that has nothing to do with inference. */
static void selftest_run(const char *path, char *out, size_t outsz)
{
    const int bpp = (s_caps.format == NN_INFER_FMT_GRAY8) ? 1 : 3;
    const size_t want = (size_t)s_src_w * s_src_h * bpp;
    const size_t need = (size_t)s_caps.width * s_caps.height * bpp;
    uint8_t *rgb = NULL, *buf = NULL;
    FILE *f = fopen(path, "rb");
    if (!f) { snprintf(out, outsz, "\"selftest\":\"no file\""); return; }
    rgb = malloc(want);
    size_t got = rgb ? fread(rgb, 1, want, f) : 0;
    fclose(f);
    if (got != want) {
        snprintf(out, outsz, "\"selftest\":\"bad size\"");
        NN_LOG_ERR("selftest: %s is %zu B, expected %zu (%dx%d %s)",
                   path, got, want, s_src_w, s_src_h,
                   bpp == 1 ? "GRAY8" : "RGB888");
        free(rgb); return;
    }
    buf = malloc(need);
    if (!buf) { free(rgb); snprintf(out, outsz, "\"selftest\":\"no mem\""); return; }
    /* pack_input() no longer writes the pad (the live buffers are filled with
     * 114 once at allocation), so this one-off buffer must be initialised
     * here -- otherwise the self-test would run against malloc garbage in the
     * padded region and stop being reproducible. */
    memset(buf, 114, need);
    pack_input(buf, rgb, want);

    nn_infer_input_t in = { .buf = nn_osal_buf_mem(buf, need), .ts_ms = 0 };
    nn_infer_result_t res;
    if (nn_infer_run(&in, &res) != 0) {
        snprintf(out, outsz, "\"selftest\":\"run failed\"");
        NN_LOG_ERR("selftest: nn_infer_run failed");
        free(buf); free(rgb); return;
    }
    int top = -1;
    for (int i = 0; i < res.count; i++)
        if (top < 0 || res.det[i].conf_x1000 > res.det[top].conf_x1000) top = i;
    if (top < 0) {
        snprintf(out, outsz, "\"selftest\":{\"n\":0}");
        NN_LOG_ERR("selftest: the reference frame produced NO detections — "
                   "the engine is loaded but is not detecting");
    } else {
        snprintf(out, outsz, "\"selftest\":{\"n\":%d,\"cls\":%u,\"conf\":%u}",
                 res.count, res.det[top].class_id, res.det[top].conf_x1000);
        NN_LOG_INF("selftest: %d detection(s), best class %u @ %.3f",
                   res.count, res.det[top].class_id,
                   res.det[top].conf_x1000 / 1000.0);
    }
    free(buf); free(rgb);
}

int infer_start(const char *model_dir,
                int src_w, int src_h, int stream_w, int stream_h)
{
    if (nn_infer_init(model_dir) != 0) return -1;
    nn_infer_query_caps(&s_caps);
    s_src_w = src_w; s_src_h = src_h;
    s_stream_w = stream_w; s_stream_h = stream_h;
    size_t fsz = (size_t)s_caps.width * s_caps.height *
                 (s_caps.format == NN_INFER_FMT_GRAY8 ? 1 : 3);
    s_pending = malloc(fsz);
    if (!s_pending) return -1;
    memset(s_pending, 114, fsz);        /* pad written once, not per frame */

    /* Self-test before the worker thread exists (no race for the engine). */
    const char *stp = getenv("NN_INFER_SELFTEST");
    if (stp && *stp) selftest_run(stp, s_selftest_json, sizeof s_selftest_json);

    snprintf(s_caps_json, sizeof s_caps_json,
             "\"infer\":{\"model\":\"%s\",\"classes\":%u,\"fps\":%u,"
             "\"w\":%u,\"h\":%u,\"sw\":%d,\"sh\":%d}",
             s_caps.model, s_caps.nclasses, s_caps.fps,
             s_caps.width, s_caps.height, stream_w, stream_h);
    char st[448];
    infer_status_json(st, sizeof st);
    uplink_set_status_json(st);
    pthread_t th;
    if (pthread_create(&th, NULL, infer_thread, NULL) != 0) return -1;
    pthread_detach(th);
    s_active = 1;
    NN_LOG_INF("edge inference up: %s %ux%u (src %dx%d -> stream %dx%d)",
               s_caps.model, s_caps.width, s_caps.height,
               src_w, src_h, stream_w, stream_h);
    return 0;
}
