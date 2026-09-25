/* SPDX-License-Identifier: Apache-2.0 */
/* Linux stand-in for ESP-IDF's app descriptor.
 *
 * This is what the FW_NAME characteristic (e7f00007) reports, and the hub
 * wizard classifies a device by its PREFIX -- "nn-camera-byai" marks a
 * Linux camera, as opposed to an ESP one, even though both advertise the
 * same name ("nn-media-net") and speak the identical GATT contract.
 * Changing project_name here changes how the fleet is classified, so it
 * is a contract, not a label. */
#pragma once

typedef struct {
    const char *project_name;
    const char *version;
} esp_app_desc_t;

const esp_app_desc_t *esp_app_get_description(void);
