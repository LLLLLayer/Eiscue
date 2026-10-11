/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_RSD_H
#define BRIDGE_RSD_H
#include "bridge_remotexpc.h"

/* Narrow RSD client for four named CoreDevice RemoteXPC services. The tunnel,
 * pairing, DDI mounting, UUID choice and TCP stack are caller responsibilities.
 * Static allocation, single owner, no concurrent/reentrant calls. */
#define BRIDGE_RSD_MAX_PEER_INFO (64u * 1024u)
#define BRIDGE_RSD_HELLO_CAPACITY 512u

typedef enum {
    BRIDGE_RSD_SCREENSHOT, BRIDGE_RSD_DISPLAY, BRIDGE_RSD_UNIVERSAL_HID,
    BRIDGE_RSD_INDIGO, BRIDGE_RSD_SERVICE_COUNT
} bridge_rsd_service;
typedef enum {
    BRIDGE_RSD_FEATURE_NONE, BRIDGE_RSD_CAPTURE_SCREENSHOT,
    BRIDGE_RSD_MEDIA_SUPPORT, BRIDGE_RSD_MEDIA_STATUS,
    BRIDGE_RSD_MEDIA_START, BRIDGE_RSD_MEDIA_STOP
} bridge_rsd_feature;
typedef enum {
    BRIDGE_RSD_UNKNOWN, BRIDGE_RSD_ALLOWED, BRIDGE_RSD_DENIED
} bridge_rsd_availability;
typedef struct {
    uint16_t port; /* zero means absent, never a dialable port */
    uint8_t feature_mask;
    bool features_advertised; /* nonempty, typed list; empty/missing is UNKNOWN */
    bridge_rsd_availability remote_xpc; /* explicit false prevents wrong-wire use */
} bridge_rsd_entry;
/* On failure dial must release partial resources and leave out zero. On success
 * out must have read/write/clock_ms. close releases it, including after failed
 * handshakes. Both callbacks must honor deadlines, be bounded and not reenter.
 * All successful streams have independent contexts and must coexist. */
typedef bridge_status (*bridge_rsd_dial_fn)(void *, const uint8_t server_ipv6[16],
    uint16_t port, uint64_t deadline_ms, bridge_io *out);
typedef void (*bridge_rsd_close_fn)(void *, bridge_io *);
/* Optional: wait until all previously written TCP bytes are acknowledged by
 * the peer, with the same absolute deadline. This does NOT prove HID effects. */
typedef bridge_status (*bridge_rsd_drain_fn)(void *, bridge_io *, uint64_t deadline_ms);
typedef struct {
    void *context;
    bridge_rsd_dial_fn dial;
    bridge_rsd_close_fn close;
    bridge_rsd_drain_fn drain;
} bridge_rsd_dialer;
typedef enum {
    BRIDGE_RSD_NEW, BRIDGE_RSD_CONNECTING, BRIDGE_RSD_READY,
    BRIDGE_RSD_FAILED, BRIDGE_RSD_CLOSED
} bridge_rsd_state;
typedef struct {
    bridge_rsd_dialer dialer;
    bridge_io control_io;
    bridge_remotexpc control;
    bridge_rsd_entry services[BRIDGE_RSD_SERVICE_COUNT];
    uint8_t server_ipv6[16];
    uint16_t rsd_port;
    bridge_rsd_state state;
    bridge_status failure;
    bool control_open;
    /* Transient caller scratch only, never retained after connect returns. */
    uint8_t *peer_scratch;
    size_t peer_capacity, peer_used;
    uint32_t peer_stream;
    bool peer_active, peer_complete;
} bridge_rsd;
typedef struct {
    bridge_io io;
    bridge_remotexpc session;
    bridge_rsd_dialer dialer;
    bool open;
} bridge_rsd_connection;

const char *bridge_rsd_service_name(bridge_rsd_service);
const char *bridge_rsd_feature_name(bridge_rsd_feature);
/* Initialize fresh/disconnected storage only; never reinit an open connection.
 * The IPv6 address and RSD port should come from CDTunnel negotiation. */
bridge_status bridge_rsd_init(bridge_rsd *, const bridge_rsd_dialer *,
    const uint8_t server_ipv6[16], uint16_t rsd_port);
/* One absolute deadline: dial, HTTP/2 handshake, modern device handshake,
 * unsolicited peer_info. Caller supplies RFC4122-order UUID bytes; no ambient
 * identity lookup/generation. Peer info can arrive on either root/reply stream;
 * it is not correlated to the outgoing handshake's request ID. No-payload
 * controls and empty dictionaries are skipped. Full wrapper must fit scratch
 * AND BRIDGE_RSD_MAX_PEER_INFO (64 KiB by default), with no heap growth. Scratch
 * must not alias context/UUID; bytes written are wiped before return. Any failure
 * after dialing starts is sticky FAILED and closes only the control transport.
 * Success keeps control OPEN, preserving device service listeners. */
bridge_status bridge_rsd_connect(bridge_rsd *, const uint8_t peer_uuid[16],
    uint8_t *scratch, size_t capacity, uint64_t deadline_ms);
bridge_status bridge_rsd_get_port(const bridge_rsd *, bridge_rsd_service, uint16_t *out);
/* NONE checks service existence only. Missing/NULL/empty feature lists return
 * UNKNOWN + OK, matching pinned upstream require_feature, never inferred support.
 * A nonempty list lacking the feature returns DENIED + UNSUPPORTED. */
bridge_status bridge_rsd_require_feature(const bridge_rsd *, bridge_rsd_service,
    bridge_rsd_feature, bridge_rsd_availability *out);
/* out must be zero-initialized and not open. Verifies existence, feature and
 * explicit UsesRemoteXPC=false before dialing; initializes service RemoteXPC
 * transport only (NO device-handshake message on a service connection).
 * A failed service dial/handshake does not close the live RSD control connection.
 * Call require_feature before each later operation needing a different feature.
 * Close every service before closing its parent RSD. */
bridge_status bridge_rsd_open_service(bridge_rsd *, bridge_rsd_service,
    bridge_rsd_feature, bridge_rsd_connection *out, uint64_t max_wrapper_size,
    bridge_remotexpc_consumer, void *consumer_context, uint64_t deadline_ms);
void bridge_rsd_close_service(bridge_rsd_connection *);
/* No successful fallback when absent: returns UNSUPPORTED without I/O.
 * Callback/timeout failures poison the service; caller must close it. */
bridge_status bridge_rsd_drain_service(bridge_rsd_connection *, uint64_t deadline_ms);
/* Pump one control step while the caller's scheduler services connections.
 * No background thread: retain and periodically service this connection.
 * Unexpected later payloads are rejected, not silently used to alter the table. */
bridge_status bridge_rsd_pump(bridge_rsd *, uint64_t deadline_ms);
void bridge_rsd_close(bridge_rsd *);
#endif
