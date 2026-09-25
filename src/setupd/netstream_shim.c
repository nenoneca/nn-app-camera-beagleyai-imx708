/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Stage-A stand-in for nn_netstream.
 *
 * nn_prov calls into nn_netstream to hand over what provisioning
 * produced: the stream endpoint, the stream key, and the Wi-Fi
 * credentials.  The real nn_netstream is FreeRTOS stream buffers plus
 * sectun and is a large port in its own right, so for setup mode we only
 * need the three setters -- persist what we were given, and actually join
 * the network.  Stage B replaces this file with the real thing; the
 * persisted keys are deliberately the same ones nn_netstream uses
 * ("nnstream/..."), so the handover needs no migration.
 */
#include "nn_netstream/nn_netstream.h"

#include <nn_osal/log.h>
NN_OSAL_LOG_MODULE(netstream_shim);
#include <nn_osal/storage.h>
#include <nn_pal/wifi.h>

#include <stdio.h>
#include <string.h>

#define KV_PREFIX "nnstream"
#define KV_KEY(k) KV_PREFIX "/" k

static char     s_host[64];
static uint16_t s_port;
static uint8_t  s_stream_pub[32];

esp_err_t nn_netstream_set_wifi(const char *ssid, const char *pass)
{
    if (!ssid || !*ssid) return ESP_ERR_INVALID_ARG;

    nn_osal_kv_save(KV_KEY("ssid"), ssid, strlen(ssid));
    if (pass) nn_osal_kv_save(KV_KEY("pass"), pass, strlen(pass));

    /* Join now.  The PAL writes an iwd provisioning file, so this also
     * makes the credentials persist across reboots -- provisioning
     * happens once, rejoining happens every boot. */
    int rc = nn_pal_wifi_connect(ssid, pass);
    if (rc) {
        NN_LOG_ERR("wifi connect: %d", rc);
        return ESP_FAIL;
    }
    NN_LOG_INF("wifi applied: ssid='%s'", ssid);
    return ESP_OK;
}

esp_err_t nn_netstream_set_host(const char *ip, uint16_t port)
{
    if (ip && *ip) {
        snprintf(s_host, sizeof s_host, "%s", ip);
        nn_osal_kv_save(KV_KEY("host"), s_host, strlen(s_host));
    }
    if (port) {
        s_port = port;
        nn_osal_kv_save(KV_KEY("port"), &s_port, sizeof s_port);
    }
    NN_LOG_INF("stream endpoint: %s:%u", s_host, s_port);
    return ESP_OK;
}

void nn_netstream_set_stream_key(const uint8_t pub[32])
{
    if (!pub) return;
    memcpy(s_stream_pub, pub, 32);
    nn_osal_kv_save(KV_KEY("stream_pub"), s_stream_pub, 32);
    NN_LOG_INF("stream key stored");
}
