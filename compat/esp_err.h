/* SPDX-License-Identifier: Apache-2.0 */
/* Minimal esp_err_t for the Linux build of nn_prov.
 *
 * nn_prov's public API still returns esp_err_t.  Rather than churn a
 * header shared with every ESP camera just to build on Linux, provide the
 * handful of codes it actually uses.  Values match ESP-IDF so a code
 * logged on Linux means the same thing as on a camera. */
#pragma once
#include <stdint.h>

typedef int esp_err_t;

#define ESP_OK                  0
#define ESP_FAIL                -1
#define ESP_ERR_NO_MEM          0x101
#define ESP_ERR_INVALID_ARG     0x102
#define ESP_ERR_INVALID_STATE   0x103
#define ESP_ERR_INVALID_SIZE    0x104
#define ESP_ERR_NOT_FOUND       0x105
#define ESP_ERR_TIMEOUT         0x107
