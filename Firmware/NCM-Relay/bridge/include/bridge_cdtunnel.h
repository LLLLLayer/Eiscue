/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_CDTUNNEL_H
#define BRIDGE_CDTUNNEL_H
#include "bridge_core.h"

/* Already-open com.apple.internal.devicecompute.CoreDeviceProxy byte stream.
 * This is the TCP/service CDTunnel variant, not QUIC, pairing, TCP/IP, or RSD.
 * All calls must be serialized; callbacks must not reenter this API. Context
 * fields are exposed for static allocation/read-only inspection, not mutation.
 * Input/output buffers must not overlap the context or each other.
 */
#define BRIDGE_CDTUNNEL_REQUESTED_MTU 16000u
#define BRIDGE_CDTUNNEL_MIN_MTU 1280u
#define BRIDGE_CDTUNNEL_MAX_MTU 16000u
#define BRIDGE_CDTUNNEL_MAX_JSON 1024u
#define BRIDGE_CDTUNNEL_IPV6_HEADER_SIZE 40u
#define BRIDGE_CDTUNNEL_ADDRESS_CAPACITY 46u

typedef enum {
    BRIDGE_CDTUNNEL_NEW, BRIDGE_CDTUNNEL_HANDSHAKING,
    BRIDGE_CDTUNNEL_READY, BRIDGE_CDTUNNEL_FAILED
} bridge_cdtunnel_state;
typedef struct {
    uint8_t client_address[16], server_address[16], netmask[16];
    char client_address_text[BRIDGE_CDTUNNEL_ADDRESS_CAPACITY];
    char server_address_text[BRIDGE_CDTUNNEL_ADDRESS_CAPACITY];
    uint16_t mtu, server_rsd_port;
    bool has_netmask;
    uint8_t prefix_length; /* valid only when has_netmask */
} bridge_cdtunnel_parameters;
typedef struct {
    bridge_io io;
    bridge_cdtunnel_state state;
    bridge_status error;
    uint16_t requested_mtu;
    bridge_cdtunnel_parameters parameters; /* valid only in READY */
} bridge_cdtunnel;

/* Copies the bridge_io interface, but borrows its context: caller owns the
 * already-open service, context lifetime, and eventual close. requested_mtu must be
 * 1280..16000; 16000 matches the pinned upstream TCP tunnel request. A lower
 * explicitly chosen MTU is supported; a peer MTU above the request is rejected.
 * Initialize only on a fresh/open service stream, NEVER to resync a used stream.
 */
bridge_status bridge_cdtunnel_init(bridge_cdtunnel *, const bridge_io *, uint16_t requested_mtu);
/* Sends CDTunnel + BE16 + JSON, then reads and validates one response. No heap.
 * Provide 1024 bytes of caller scratch to support the full bounded JSON profile;
 * smaller scratch is legal, but a larger response fails terminally with LIMIT.
 * Accepts only the documented schema (optional contiguous IPv6 netmask).
 * Unknown keys are UNSUPPORTED, duplicates/malformed JSON fail closed.
 * Negotiated parameters are committed only after a full validated response.
 */
bridge_status bridge_cdtunnel_handshake(bridge_cdtunnel *, uint8_t *json_scratch,
    size_t capacity, uint64_t deadline_ms);
/* Raw IPv6 stream: exactly 40-byte header + BE16 payload length; NO CDTunnel or
 * other per-packet prefix. Validates version, exact byte count and negotiated MTU.
 * Zero payload is supported only with No Next Header (59); IPv6 jumbograms are
 * unsupported. Extension-header chains and transport checksums belong to the
 * future IP stack, and are not verified here. Source/destination policy is also
 * the caller's/IP stack's responsibility.
 */
bridge_status bridge_cdtunnel_send_ipv6(bridge_cdtunnel *, const uint8_t *,
    size_t packet_size, uint64_t deadline_ms);
/* capacity must hold negotiated MTU BEFORE any read. Writes no user callback;
 * *packet_size is zero until one COMPLETE packet succeeds. The caller-owned
 * buffer may contain partial bytes on failure and must not be consumed then.
 * Consumes only that packet, leaving subsequent stream bytes untouched.
 */
bridge_status bridge_cdtunnel_recv_ipv6(bridge_cdtunnel *, uint8_t *,
    size_t capacity, size_t *packet_size, uint64_t deadline_ms);
/* All operations use ONE absolute monotonic deadline, including short I/O and
 * parse/validation time. The adapter must honor each remaining timeout. Any
 * failure after wire I/O starts is sticky FAILED: close the underlying service,
 * discard partial data, and open a fresh service before reinitialization.
 * Pure local argument/state/buffer/send-validation failures before wire I/O do
 * not poison READY. FAILED operations return the original error with no I/O.
 */
#endif
