/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_PACKET_LINK_H
#define BRIDGE_PACKET_LINK_H
#include "bridge_cdtunnel.h"
/* Borrowed, single owner-task link. Network-core callbacks must never invoke
 * any member directly: enqueue copied packets and let the owner forward them.
 * readable only observes buffered raw/decrypted bytes; it does not guarantee a
 * complete record/packet. Once reading starts, the absolute operation deadline
 * bounds completion; no empty read/poll timeouts are used to resynchronize.
 */
typedef struct {
    bridge_cdtunnel *tunnel;
    void *context;
    bridge_status (*poll)(void *, uint64_t deadline_ms);
    bridge_status (*readable)(void *, bool *ready);
} bridge_packet_link;
#endif
