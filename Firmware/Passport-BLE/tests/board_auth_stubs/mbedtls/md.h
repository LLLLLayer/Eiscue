// SPDX-License-Identifier: Apache-2.0
#pragma once
#include <stddef.h>
typedef struct {int type;} mbedtls_md_info_t;
#define MBEDTLS_MD_SHA256 1
const mbedtls_md_info_t *mbedtls_md_info_from_type(int type);
int mbedtls_md_hmac(const mbedtls_md_info_t *info,const unsigned char *key,size_t key_length,
    const unsigned char *input,size_t input_length,unsigned char *output);
