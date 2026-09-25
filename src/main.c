/* SPDX-License-Identifier: Apache-2.0 */
/* nn-camera — single-program Linux camera (BeagleY-AI + IMX708).
 *
 * The Linux sibling of nn-app-media's app_main: capture → H.264 → encrypted
 * record uplink to the hub video service, built on the SAME nn-modules
 * sources (nn_osal POSIX backend, nn_crypto, nn_sectun).
 *
 * NO configuration lives in source (see feedback_no_secrets_in_source):
 *   NN_HUB_HOST     video service host (mDNS names fine)     [required]
 *   NN_HUB_PORT     stream port                              [default 8890]
 *   NN_STREAM_PUB   service X25519 pubkey, 64 hex chars      [required]
 *   NN_CAM_DEVICE   V4L2 capture node                        [default /dev/video0]
 *   NN_CAM_WIDTH/HEIGHT/BITRATE                              [1920/1080/6000000]
 *   NN_CAM_PIPELINE full GStreamer override (appsink "out")  [optional]
 *   NN_OSAL_KV_DIR  key store (device identity keypair)      [default /var/lib/nn/kv]
 * Ship them via a systemd EnvironmentFile (see nn-camera.service).
 *
 * On first run nn_crypto generates the device keypair into the KV store and
 * prints the public key — authorize it in the video service's --keydir. */
#include "uplink.h"
#include "capture_gst.h"
#include "infer.h"
/* nn_infer_deinit() is called on the shutdown path; without this the compiler
 * only had an implicit declaration (assumed int(), pre-existing since the
 * graceful-shutdown commit).  It links today, but an implicit decl is a
 * latent ABI bug, not a style nit. */
#include <nn_infer/nn_infer.h>
#include <nn_crypto/nn_crypto.h>
#include <nn_osal/storage.h>
#include <nn_osal/time.h>
#include <nn_osal/log.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>

NN_OSAL_LOG_MODULE(nn_camera);

static int hex32(const char *s, uint8_t out[32])
{
    if (!s || strlen(s) != 64) return -1;
    for (int i = 0; i < 32; i++)
        if (sscanf(s + 2 * i, "%2hhx", &out[i]) != 1) return -1;
    return 0;
}

static void on_frame(const uint8_t *au, size_t len, bool key,
                     uint64_t ts_ms, void *user)
{
    (void)user;
    uplink_send_video(au, len, key, ts_ms);
}

static int on_cfg(const char *json, size_t len, void *user)
{
    (void)user;
    return infer_apply_config(json, len);
}

#define CTRL_CMD_REBOOT 20u   /* operator reboot from the hub webapp */
#define CTRL_CMD_CLEAR  21u   /* unregister: clear user data on next start */

/* Arm "clear on next start": a flag file beside the KV store.  The wipe
 * itself runs at startup (see main) so it cannot race the running
 * pipeline; identity lives in the KV dir, so the wipe mints a fresh
 * keypair on restart and the camera is effectively unprovisioned until
 * the operator authorizes the new key. */
static void arm_clear_user_data(void)
{
    const char *kv = getenv("NN_OSAL_KV_DIR");
    char path[256];
    snprintf(path, sizeof path, "%s/clear_on_start", kv ? kv : "/var/lib/nn/kv");
    FILE *f = fopen(path, "w");
    if (f) { fputc('1', f); fclose(f); }
}

static volatile sig_atomic_t s_stop;

static void on_ctrl(uint8_t cmd, uint32_t val, void *user)
{
    (void)user;
    if (cmd == CTRL_CMD_CLEAR) {
        NN_LOG_INF("server ctrl: CLEAR_USER_DATA — arming wipe + restart");
        arm_clear_user_data();
        s_stop = 2;            /* restart via exit 42, wipe runs at start */
        return;
    }
    if (cmd == CTRL_CMD_REBOOT) {
        /* Same clean unwind as SIGINT: main() releases the TIDL session on
         * the way out (killing the process dirty wedges the C7x until a
         * board reboot) and systemd's Restart= brings the camera back. */
        NN_LOG_INF("server ctrl: REBOOT requested — clean restart");
        s_stop = 2;   /* distinct from SIGINT: main exits NONZERO so
                       * systemd's Restart=on-failure brings us back.
                       * A clean 0 here left the camera down (found the
                       * hard way: operator reboot = camera off). */
        return;
    }
    /* The service's adaptive controller (cmd 1 = bitrate, 2 = gop).  Live
     * encoder retuning lands with the next capture iteration; log for now. */
    NN_LOG_INF("server ctrl: cmd=%u val=%u", cmd, (unsigned)val);
}

static void on_signal(int sig) { (void)sig; s_stop = 1; }

/*
 * Provisioned stream endpoint + key, as written into the kv store by
 * nn_prov during BLE provisioning (same "nnstream/" keys nn_netstream
 * uses, so this does not depend on which of them wrote them).
 *
 * Values are RAW, not text: host without a NUL, port as a native u16,
 * stream_pub as 32 bytes -- whereas NN_STREAM_PUB is 64 hex chars.
 */
static char     s_kv_host[128];
static uint16_t s_kv_port;
static uint8_t  s_kv_pub[32];
static bool     s_kv_have_pub;

static int stream_kv_cb(const char *key, const uint8_t *val, size_t len,
                        void *user)
{
    (void)user;
    if (!strcmp(key, "host")) {
        if (len && len < sizeof s_kv_host) {
            memcpy(s_kv_host, val, len);
            s_kv_host[len] = '\0';
        }
    } else if (!strcmp(key, "port")) {
        if (len == sizeof s_kv_port) memcpy(&s_kv_port, val, len);
    } else if (!strcmp(key, "stream_pub")) {
        if (len == 32) { memcpy(s_kv_pub, val, 32); s_kv_have_pub = true; }
    }
    return 0;
}

int main(void)
{
    /* A send() on a connection the peer already closed must surface as an
     * error for the reconnect logic — not kill the process. */
    signal(SIGPIPE, SIG_IGN);
    /* SIGINT/SIGTERM must unwind cleanly: killing this process outright
     * leaves the C7x/TIDL session dirty and EVERY later start fails with
     * "Create state function failed" until the board is rebooted. */
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);

    const char *dev = getenv("NN_CAM_DEVICE") ? getenv("NN_CAM_DEVICE") : "/dev/video0";
    int w  = getenv("NN_CAM_WIDTH")   ? atoi(getenv("NN_CAM_WIDTH"))   : 1920;
    int h  = getenv("NN_CAM_HEIGHT")  ? atoi(getenv("NN_CAM_HEIGHT"))  : 1080;
    int br = getenv("NN_CAM_BITRATE") ? atoi(getenv("NN_CAM_BITRATE")) : 6000000;

    {   /* unregister step 2: wipe the KV store if the clear flag is
         * armed.  Runs BEFORE kv/crypto init so a fresh identity is
         * minted this very start.  rm inside the dir only — the dir
         * itself is a bind-mount target. */
        const char *kv = getenv("NN_OSAL_KV_DIR");
        char flag[256];
        snprintf(flag, sizeof flag, "%s/clear_on_start",
                 kv ? kv : "/var/lib/nn/kv");
        if (access(flag, F_OK) == 0) {
            char cmdln[320];
            snprintf(cmdln, sizeof cmdln, "rm -rf -- \"%s\"/* 2>/dev/null",
                     kv ? kv : "/var/lib/nn/kv");
            int rc = system(cmdln);
            fprintf(stderr, "nn-camera: user data CLEARED (rc=%d) — "
                            "new identity will be minted\n", rc);
        }
    }
    if (nn_osal_kv_init() != 0) { NN_LOG_ERR("kv init failed"); return 1; }

    /* Endpoint + stream key: environment WINS, provisioning is the
     * fallback.  A hand-written /etc/nn-camera.env therefore still
     * overrides a provisioned value, which is what you want on a bench
     * board; a provisioned camera needs no env file at all.  Resolved
     * here rather than at the top of main() because it has to come after
     * the clear-on-start wipe and kv init above. */
    nn_osal_kv_register("nnstream", stream_kv_cb, NULL);
    nn_osal_kv_load_all();

    const char *host = getenv("NN_HUB_HOST");
    if (!host || !*host) host = s_kv_host[0] ? s_kv_host : NULL;

    uint8_t pub[32];
    bool have_pub = false;
    const char *pubh = getenv("NN_STREAM_PUB");
    if (pubh && *pubh && hex32(pubh, pub) == 0) {
        have_pub = true;
    } else if (s_kv_have_pub) {
        memcpy(pub, s_kv_pub, sizeof pub);
        have_pub = true;
    }

    /* Only refuse when NEITHER source has it. */
    if (!host || !have_pub) {
        fprintf(stderr,
            "nn-camera: need a hub endpoint and stream key — set NN_HUB_HOST "
            "and NN_STREAM_PUB (64 hex), or provision the camera\n");
        return 64;
    }

    uint16_t port = getenv("NN_HUB_PORT") ? (uint16_t)atoi(getenv("NN_HUB_PORT"))
                                          : (s_kv_port ? s_kv_port : 8890);
    NN_LOG_INF("uplink target %s:%u (%s)", host, port,
               getenv("NN_HUB_HOST") ? "from environment" : "from provisioning");
    if (nn_crypto_init()  != 0) { NN_LOG_ERR("crypto init failed"); return 1; }
    uint8_t devpub[32];
    nn_crypto_device_pub(devpub);
    char hex[65];
    for (int i = 0; i < 32; i++) sprintf(hex + 2 * i, "%02x", devpub[i]);
    NN_LOG_INF("device pubkey: %s (authorize in the service --keydir)", hex);

    /* Edge inference (nn_infer): NN_INFER_MODEL = model artifact dir.
     * NN_INFER_SRC_WxH = geometry of the pipeline's "infer" appsink branch
     * (content region, top-left of the model's padded input). */
    const char *model = getenv("NN_INFER_MODEL");
    if (model && *model) {
        int iw = getenv("NN_INFER_SRC_W") ? atoi(getenv("NN_INFER_SRC_W")) : 640;
        int ih = getenv("NN_INFER_SRC_H") ? atoi(getenv("NN_INFER_SRC_H")) : 360;
        if (infer_start(model, iw, ih, w, h) != 0) {
            NN_LOG_ERR("edge inference unavailable — streaming only");
            /* tell the hub WHY there is no edge engine, instead of looking
             * like a camera that never had one */
            uplink_set_status_json(
                "{\"infer_error\":\"init failed (see camera log)\"}");
        }
    }

    uplink_set_cfg_cb(on_cfg, NULL);
    if (uplink_start(host, port, pub, on_ctrl, NULL) != 0) return 1;
    if (capture_start(dev, w, h, br, on_frame, NULL) != 0) return 1;
    NN_LOG_INF("nn-camera up: %s %dx%d -> %s:%u", dev, w, h, host, port);

    char st[160];
    unsigned long last = 0;
    uint64_t t0 = nn_osal_uptime_ms();
    /* HEARTBEAT PERIOD IS A CONTRACT WITH THE HUB, not a local choice.  The
     * video service confirms a CLEAR (unregister) by watching this cadence:
     * it treats a device silent for more than 6.5 s as already-down BEFORE
     * sending, and as having-obeyed AFTER.  The fleet's cadence is 5 s.  This
     * loop ran at 10 s, so roughly a third of the time a perfectly healthy
     * camera read as "already silent" and its unregister was refused with
     * 409 -- while the camera had in fact wiped itself (E2E, 2026-09-17).
     * The log line stays at every other beat to keep the journal quiet. */
    enum { HB_PERIOD_S = 5 };
    unsigned beat = 0;
    while (!s_stop) {
        for (int i = 0; i < HB_PERIOD_S && !s_stop; i++) sleep(1);
        if (s_stop) break;
        unsigned long f = capture_frames();
        uplink_stats(st, sizeof st);
        double fps = (f - last) / (double)HB_PERIOD_S;
        if ((beat++ & 1) == 0) NN_LOG_INF("%s cap=%.1ffps", st, fps);
        /* liveness independent of video flow: the service marks a camera
         * present from this, not from frames arriving. */
        uplink_send_heartbeat((uint32_t)((nn_osal_uptime_ms() - t0) / 1000),
                              (uint32_t)(fps * 10), 0, infer_config_version());
        /* Engine telemetry every other beat (10 s).  Cheap, and it is the
         * only way the hub learns inference rate/latency now that the
         * separate stats reporter is gone with the python daemon. */
        if ((beat & 1) == 0 && infer_active()) {
            char ij[448];
            infer_status_json(ij, sizeof ij);
            if (ij[1]) uplink_send_status(ij);   /* skip the empty "{}" */
        }
        last = f;
    }

    NN_LOG_INF("shutting down");
    capture_stop();          /* stop feeding frames first */
    nn_infer_deinit();       /* release the TIDL session cleanly */
    /* 0 = operator stop (SIGINT/SIGTERM: stay down);
     * 42 = ctrl-channel reboot request (systemd restarts us). */
    return s_stop == 2 ? 42 : 0;
}
