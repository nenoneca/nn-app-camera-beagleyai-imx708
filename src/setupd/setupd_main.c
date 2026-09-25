/* SPDX-License-Identifier: Apache-2.0 */
/*
 * nn-setupd — BLE setup mode for the Linux (BeagleY) camera.
 *
 * Presents the same GATT contract as the ESP cameras (service e7f00001,
 * chars e7f00003..e7f00007) so the hub's existing wizard provisions this
 * board with no protocol change: DEVICE_PUBKEY read, CONFIG write, ECIES
 * WIFI write, STATUS notify.
 *
 * Runs ONLY while unprovisioned.  nn_prov reboots the board ~1.5 s after
 * a successful WIFI write, and on the next boot nn_prov_init() finds the
 * stored config and reports provisioned, so this exits immediately and
 * stops advertising -- matching the ESP behaviour of dropping BLE once
 * adopted, rather than leaving a provisioning surface open forever.
 */
#include "nn_prov/nn_prov.h"

#include <nn_osal/log.h>
NN_OSAL_LOG_MODULE(nn_setupd);
#include <nn_pal/wifi.h>

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static volatile sig_atomic_t s_stop;

static void on_signal(int sig) { (void)sig; s_stop = 1; }

static void wifi_event(nn_pal_wifi_event_t ev, const nn_pal_wifi_state_t *st,
                       void *user)
{
    (void)user;
    switch (ev) {
    case NN_PAL_WIFI_EV_IP_ASSIGNED:
        NN_LOG_INF("wifi: ip %s (rssi %d)", st->ipv4, st->rssi_dbm);
        break;
    case NN_PAL_WIFI_EV_CONNECTED:
        NN_LOG_INF("wifi: associated");
        break;
    case NN_PAL_WIFI_EV_DISCONNECTED:
        NN_LOG_WRN("wifi: disconnected");
        break;
    default:
        break;
    }
}

int main(void)
{
    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    setvbuf(stdout, NULL, _IOLBF, 0);      /* journal sees lines promptly */

    if (nn_pal_wifi_init(wifi_event, NULL) != 0)
        NN_LOG_WRN("wifi init failed — provisioning can still store creds");

    if (nn_prov_init() != ESP_OK) {
        NN_LOG_ERR("nn_prov_init failed");
        return 1;
    }

    if (nn_prov_is_provisioned()) {
        /* Nothing to do.  Exiting cleanly (not failing) keeps the unit
         * from restart-looping on an adopted camera. */
        NN_LOG_INF("already provisioned — setup mode not needed");
        return 0;
    }

    uint8_t pub[32];
    nn_prov_get_device_pubkey(pub);
    char hex[65];
    for (int i = 0; i < 32; i++) snprintf(hex + 2 * i, 3, "%02x", pub[i]);
    NN_LOG_INF("device X25519 pub: %s", hex);

    if (nn_prov_start() != ESP_OK) {
        NN_LOG_ERR("nn_prov_start failed (BLE advertise)");
        return 1;
    }
    NN_LOG_INF("BLE setup mode active — waiting for the hub wizard");

    /* nn_prov drives everything from the BLE callbacks; just stay alive.
     * The reboot after a successful WIFI write is what ends this process. */
    while (!s_stop) {
        char line[200];
        nn_prov_status_str(line, sizeof line);
        NN_LOG_DBG("%s", line);
        sleep(15);
    }
    NN_LOG_INF("stopping");
    return 0;
}
