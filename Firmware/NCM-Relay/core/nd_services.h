/* SPDX-License-Identifier: GPL-3.0-or-later */
#pragma once
#include "bridge_operations.h"
/* An integration seam, NOT an authentication implementation. Supplied solely
 * by a trusted in-process protocol backend after cryptographic verification.
 * Never deserialize these flags/ports from the ND1 diagnostic channel. */
typedef enum { ND_ROUTE_LOCKDOWN=1, ND_ROUTE_REMOTE_PAIRING=2 } nd_route;
typedef struct {
    nd_route route;
    nd_route identity_kind; // records from these routes are not interchangeable
    bool peer_verified, developer_mode, personalized_ddi;
    uint8_t server_ipv6[16]; // negotiated tunnel address, never NCM .2
    uint16_t rsd_port;      // negotiated, never a default
    bridge_rsd_dialer dialer;
} nd_authenticated_tunnel;
typedef struct { bridge_rsd rsd; bool ready; } nd_services;
bridge_status nd_services_open(nd_services *,const nd_authenticated_tunnel *,
    const uint8_t peer_uuid[16],uint8_t *scratch,size_t capacity,uint64_t deadline);
bridge_status nd_services_capture(nd_services *,const bridge_invocation *,uint8_t *scratch,
    size_t capacity,bridge_sink_fn,void *sink_context,uint64_t deadline,bridge_png_info *);
/* Interface only: media ownership/authentication/drain not implemented here.
 * Fails with UNSUPPORTED and sends no touch reports, even if RSD is ready. */
bridge_status nd_services_tap(nd_services *,uint16_t x,uint16_t y);
void nd_services_close(nd_services *);
