/* SPDX-License-Identifier: Apache-2.0 */
#include "esp_app_desc.h"

#ifndef NN_APP_VERSION
#define NN_APP_VERSION "0.1.0"
#endif

/* Reported over BLE as FW_NAME: "nn-camera-byai <version>".
 * The hub matches on the "nn-camera-byai" prefix. */
static const esp_app_desc_t s_desc = {
    .project_name = "nn-camera-byai",
    .version      = NN_APP_VERSION,
};

const esp_app_desc_t *esp_app_get_description(void) { return &s_desc; }
