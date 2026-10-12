// SPDX-License-Identifier: Apache-2.0
#pragma once
#include "esp_err.h"
#include <stddef.h>
typedef unsigned nvs_handle_t;
#define NVS_READWRITE 1
esp_err_t nvs_open(const char *name,int mode,nvs_handle_t *handle);
esp_err_t nvs_get_blob(nvs_handle_t handle,const char *name,void *value,size_t *length);
esp_err_t nvs_set_blob(nvs_handle_t handle,const char *name,const void *value,size_t length);
esp_err_t nvs_commit(nvs_handle_t handle);
void nvs_close(nvs_handle_t handle);
