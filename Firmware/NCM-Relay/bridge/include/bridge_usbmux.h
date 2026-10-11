/* SPDX-License-Identifier: GPL-2.0-only OR GPL-3.0-only */
#ifndef BRIDGE_USBMUX_H
#define BRIDGE_USBMUX_H
#include "bridge_core.h"

/* Raw Apple USB multiplexing, NOT the usbmuxd host-daemon socket protocol.
 * Protocol reference: usbmuxd 3ded00c9985a5108cfc7591a309f9a23d57a8cba,
 * src/device.c and src/usb.h. No heap allocation, platform APIs, pairing, or TLS.
 * All calls must run serialized on one task. Callbacks must not reenter this API.
 * The structs are exposed only for static allocation; do not alter their fields.
 * Caller input/output buffers must not overlap this context.
 */
#define BRIDGE_USBMUX_CHANNELS 4u
#define BRIDGE_USBMUX_RX_CAPACITY 8192u
#define BRIDGE_USBMUX_MAX_FRAME 65536u
#define BRIDGE_USBMUX_TX_PAYLOAD 4096u
#define BRIDGE_USBMUX_TX_FRAME (BRIDGE_USBMUX_TX_PAYLOAD + 36u)
#define BRIDGE_USBMUX_TIMEOUT_MS UINT64_C(5000)

typedef enum {
    BRIDGE_USBMUX_IDLE, BRIDGE_USBMUX_VERSION_PENDING,
    BRIDGE_USBMUX_WAIT_VERSION, BRIDGE_USBMUX_SETUP_PENDING,
    BRIDGE_USBMUX_READY, BRIDGE_USBMUX_DEAD
} bridge_usbmux_state;
typedef enum {
    BRIDGE_USBMUX_CH_FREE, BRIDGE_USBMUX_CH_SYN_PENDING,
    BRIDGE_USBMUX_CH_SYN_SENT, BRIDGE_USBMUX_CH_ACK_PENDING,
    BRIDGE_USBMUX_CH_OPEN, BRIDGE_USBMUX_CH_CLOSING, BRIDGE_USBMUX_CH_CLOSED
} bridge_usbmux_channel_state;
typedef enum {
    BRIDGE_USBMUX_REASON_NONE, BRIDGE_USBMUX_REASON_LOCAL_CLOSE,
    BRIDGE_USBMUX_REASON_REFUSED, BRIDGE_USBMUX_REASON_RESET,
    BRIDGE_USBMUX_REASON_TIMEOUT, BRIDGE_USBMUX_REASON_PROTOCOL,
    BRIDGE_USBMUX_REASON_OVERFLOW, BRIDGE_USBMUX_REASON_DISCONNECTED,
    BRIDGE_USBMUX_REASON_IO
} bridge_usbmux_reason;

/* Atomic complete-wire-packet enqueue. OK means copied/owned by the adapter;
 * LIMIT means temporary queue-full, with NO bytes accepted. Any other return
 * makes the link dead. The pointer expires on return. Callback must not block.
 * Preserve packet ordering and boundaries. Adapter sends a terminating USB ZLP
 * when complete packet length is an endpoint max-packet-size multiple; do not
 * insert ZLPs at arbitrary fragments. Async transfer failure must call disconnect.
 */
typedef bridge_status (*bridge_usbmux_send_fn)(void *, const uint8_t *, size_t);
typedef uint32_t bridge_usbmux_channel_id;
typedef struct {
    bridge_usbmux_channel_id id;
    bridge_usbmux_channel_state state;
    bridge_usbmux_reason reason;
    uint16_t local_port, remote_port;
    uint32_t tx_next, tx_acked, peer_window, rx_next, rx_limit, peer_initial_seq;
    size_t rx_head, rx_size;
    uint64_t state_since_ms, progress_since_ms;
    bool ack_pending;
    uint8_t rx[BRIDGE_USBMUX_RX_CAPACITY];
} bridge_usbmux_channel;
typedef struct {
    bridge_usbmux_send_fn send;
    void *send_context;
    bridge_usbmux_state state;
    bridge_status error;
    uint32_t version, minor, next_id;
    uint16_t tx_seq, rx_seq, next_port;
    uint64_t state_since_ms, frame_since_ms;
    size_t frame_used, frame_expected;
    bool anonymous_reset_pending;
    uint16_t anonymous_local, anonymous_remote;
    uint32_t anonymous_ack;
    bridge_usbmux_channel channels[BRIDGE_USBMUX_CHANNELS];
    uint8_t frame[BRIDGE_USBMUX_MAX_FRAME];
    uint8_t tx[BRIDGE_USBMUX_TX_FRAME];
} bridge_usbmux;

bridge_status bridge_usbmux_init(bridge_usbmux *, bridge_usbmux_send_fn, void *);
/* Start once after init. Reinitialize only after adapter queues are drained or
 * cancelled on disconnect. All now_ms values use one monotonic millisecond clock.
 * start/open/close return OK for an accepted asynchronous operation, even when
 * the adapter is temporarily full. Inspect link/channel state for completion.
 */
bridge_status bridge_usbmux_start(bridge_usbmux *, uint64_t now_ms);
/* Feed arbitrary partial headers/payloads or coalesced complete packets. Zero
 * length (including USB ZLP) is valid. Input is copied/consumed before return.
 * Malformed framing is terminal: never attempt byte-scanning resynchronization.
 */
bridge_status bridge_usbmux_feed(bridge_usbmux *, const uint8_t *, size_t, uint64_t now_ms);
/* Call regularly (e.g. every 10 ms) to retry pending control/ACK/RST packets and
 * enforce 5-second handshake, open, partial-frame, unacknowledged-send and close
 * deadlines. Idle open channels and zero-window writes without outstanding data
 * have no implicit deadline: application must impose its own operation deadline.
 * USB is ordered/reliable; there is no lossy-IP retransmission implementation.
 */
bridge_status bridge_usbmux_tick(bridge_usbmux *, uint64_t now_ms);
void bridge_usbmux_disconnect(bridge_usbmux *);
bridge_usbmux_state bridge_usbmux_get_state(const bridge_usbmux *);
bridge_status bridge_usbmux_get_error(const bridge_usbmux *);

bridge_status bridge_usbmux_open(bridge_usbmux *, uint16_t remote_port,
    uint64_t now_ms, bridge_usbmux_channel_id *);
bridge_status bridge_usbmux_channel_status(const bridge_usbmux *, bridge_usbmux_channel_id,
    bridge_usbmux_channel_state *, bridge_usbmux_reason *);
/* Bounded nonblocking byte streams: OK + *count==0 means WOULD BLOCK, not EOF.
 * write accepts at most TX_PAYLOAD and the peer's remaining scaled window;
 * accepted bytes have been copied by the adapter, not necessarily ACKed by peer.
 * read drains buffered bytes before returning a terminal status. Empty OPEN or
 * connecting channel returns OK/0. Local close => EOF, timeout => TIMEOUT,
 * refusal/reset/disconnect => IO, protocol => FORMAT, overflow => LIMIT.
 * Not directly bridge_io-compatible: its zero means EOF. A task-level bridge_io
 * adapter must pump USB/tick until progress/terminal/deadline and never run from
 * USB callbacks. No hidden blocking/polling is performed here.
 */
bridge_status bridge_usbmux_write(bridge_usbmux *, bridge_usbmux_channel_id,
    const uint8_t *, size_t, size_t *count, uint64_t now_ms);
bridge_status bridge_usbmux_read(bridge_usbmux *, bridge_usbmux_channel_id,
    uint8_t *, size_t, size_t *count);
/* Close uses RST, matching usbmuxd; no TCP FIN or half-close. If a local-close
 * RST cannot be enqueued before its deadline, the terminal reason is TIMEOUT.
 * Pending receive
 * bytes remain readable. release is permitted only after CLOSED, invalidates
 * the handle, and discards any unread bytes. Four unreleased handles exhaust
 * capacity. Handles and source ports are not reused within one link lifetime;
 * exhausting either counter requires a fresh physical link/init.
 */
bridge_status bridge_usbmux_close(bridge_usbmux *, bridge_usbmux_channel_id, uint64_t now_ms);
bridge_status bridge_usbmux_release(bridge_usbmux *, bridge_usbmux_channel_id);
#endif
