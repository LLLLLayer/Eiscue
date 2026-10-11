/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_REMOTEXPC_H
#define BRIDGE_REMOTEXPC_H
#include "bridge_xpc.h"

/* Pinned RemoteXPC subset, NOT general HTTP/2: streams 1/3, empty header
 * blocks, resident outbound XPC, streamed inbound XPC. No heap allocation,
 * file-transfer streams, HPACK, push, authentication, socket or identity creation.
 * All APIs are synchronous, single-owner and non-reentrant. Callbacks must be
 * bounded/nonblocking. Any transport/protocol/callback failure poisons session;
 * close the underlying transport and discard provisional consumer output. */
#define BRIDGE_RXPC_CHUNK_SIZE 1024u
#define BRIDGE_RXPC_ROOT 1u
#define BRIDGE_RXPC_REPLY 3u
#define BRIDGE_RXPC_ANY_STREAM 0u /* response selection: first payload on 1 or 3 */
#define BRIDGE_RXPC_RECEIVE_WINDOW 16384u
#define BRIDGE_RXPC_FRAME_SIZE 16384u

typedef struct {
    uint32_t stream_id, flags;
    uint64_t message_id, wrapper_size;
} bridge_remotexpc_message;
typedef enum { BRIDGE_RXPC_BEGIN, BRIDGE_RXPC_CHUNK, BRIDGE_RXPC_END } bridge_remotexpc_event;
/* CHUNK includes the 24-byte wrapper header. BEGIN/END have no data. Each
 * stream's events are ordered but streams may interleave. END only certifies
 * wrapper framing, not XPC object validity; use bridge_xpc_parse or extractor.
 * Consumer may reject BEGIN before a mismatched response emits payload. */
typedef bridge_status (*bridge_remotexpc_consumer)(void *,
    bridge_remotexpc_event, const bridge_remotexpc_message *, const uint8_t *, size_t);
typedef struct {
    uint8_t header[BRIDGE_XPC_WRAPPER_SIZE];
    size_t header_used;
    uint64_t body_left;
    bridge_remotexpc_message message;
    int64_t send_window;
    uint32_t receive_window, receive_pending;
    bool active, remote_closed;
} bridge_remotexpc_stream;
typedef struct {
    bridge_io *transport;
    bridge_remotexpc_consumer consumer;
    void *consumer_context;
    bridge_remotexpc_stream streams[2];
    uint8_t scratch[BRIDGE_RXPC_CHUNK_SIZE];
    uint64_t max_wrapper_size, next_message_id;
    int64_t send_window;
    uint32_t peer_initial_window, receive_window, receive_pending;
    uint32_t frame_left, frame_stream, continuation_stream, peer_error;
    uint8_t frame_flags;
    bridge_status failure;
    bool started, ready, peer_settings, settings_acked, data_active;
    bool response_attached, in_callback, continuation_end_stream;
} bridge_remotexpc;

bridge_status bridge_remotexpc_init(bridge_remotexpc *, bridge_io *,
    uint64_t max_wrapper_size, bridge_remotexpc_consumer, void *context);
/* Mark semantic/parser failure as terminal without owning/closing transport.
 * reason must be a non-OK BRIDGE_E_*; first failure is preserved. */
bridge_status bridge_remotexpc_abort(bridge_remotexpc *, bridge_status reason);
/* Sends pinned transport handshake with bounded receive-window SETTINGS
 * (16 KiB/stream, connection default 65535), pumps controls until a non-ACK
 * SETTINGS arrives, and ACKs it. Caller supplies one absolute deadline. */
bridge_status bridge_remotexpc_handshake(bridge_remotexpc *, uint64_t deadline_ms);
/* Processes at most one control frame or one wrapper header/body fragment.
 * Callback deliveries, including unsolicited messages, can occur while sending
 * if the peer must grant more window. Stream errors/GOAWAY are terminal, with
 * HTTP/2 peer error preserved in peer_error. Public pump/send are rejected
 * while a pull response is attached; only its io.read may advance the session. */
bridge_status bridge_remotexpc_pump(bridge_remotexpc *, uint64_t deadline_ms);
/* Encodes a root-stream request into caller scratch and sends with flow control.
 * First application ID is 1, following handshake ID 0. IDs never wrap. */
bridge_status bridge_remotexpc_send(bridge_remotexpc *, const bridge_xpc_object *,
    bool wanting_reply, uint8_t *scratch, size_t capacity,
    uint64_t deadline_ms, uint64_t *message_id);
/* For already serialized complete wrappers. Validates XPC and matches its ID to
 * next_message_id. Intended for caller-prepared bounded request envelopes. */
bridge_status bridge_remotexpc_send_encoded(bridge_remotexpc *, const uint8_t *,
    size_t size, uint64_t deadline_ms, uint64_t *message_id);

typedef struct {
    bridge_remotexpc *session;
    bridge_remotexpc_consumer previous_consumer;
    void *previous_context;
    bridge_io io;
    uint8_t pending[BRIDGE_RXPC_CHUNK_SIZE];
    size_t pending_offset, pending_size;
    uint64_t expected_id;
    uint32_t expected_stream;
    bridge_remotexpc_message message;
    bool match_id, active, complete, attached;
} bridge_remotexpc_response;
/* Pull adapter for bridge_xpc_extract_png / bridge_read_exact. Selects one
 * wrapper on stream 1 or 3, with optional exact message-ID correlation. Passing
 * BRIDGE_RXPC_ANY_STREAM selects the first payload on either supported stream,
 * matching upstream receive_response without assuming a reply-channel number.
 * Concurrent matching payloads on both streams fail rather than being merged. Other
 * wrappers are forwarded to the session's existing consumer. Set match_id=true
 * for requests; false selects the first payload-bearing wrapper and skips
 * no-payload controls, useful for unsolicited RSD peer_info. A NULL
 * previous consumer rejects unrelated payloads (no silent response loss), but
 * ignores no-payload control wrappers. A 1024-byte fixed queue means
 * there is no screenshot-sized allocation. Read never crosses wrapper end. */
bridge_status bridge_remotexpc_response_open(bridge_remotexpc *,
    bridge_remotexpc_response *, uint32_t stream, bool match_id, uint64_t message_id);
/* Must be called after consumer succeeds/fails. Success requires exact complete
 * consumption; failed or abandoned responses poison the session. */
bridge_status bridge_remotexpc_response_finish(bridge_remotexpc_response *, bridge_status consumer_status);
#endif
