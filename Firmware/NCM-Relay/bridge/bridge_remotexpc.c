/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_remotexpc.h"
#include <limits.h>
#include <string.h>

#define RXPC_MAX_WINDOW UINT32_C(0x7fffffff)
#define RXPC_REPLENISH 8192u
static uint32_t be32(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[3] << 24 | (uint32_t)p[2] << 16 | (uint32_t)p[1] << 8 | p[0];
}
static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p + 4) << 32 | le32(p); }
static void put32(uint8_t *p, uint32_t n) {
    p[0] = (uint8_t)(n >> 24); p[1] = (uint8_t)(n >> 16);
    p[2] = (uint8_t)(n >> 8); p[3] = (uint8_t)n;
}
static bridge_remotexpc_stream *stream_for(bridge_remotexpc *s, uint32_t id) {
    return id == 1 ? &s->streams[0] : id == 3 ? &s->streams[1] : NULL;
}
static bridge_status fail(bridge_remotexpc *s, bridge_status status) {
    if (status != BRIDGE_OK && s->failure == BRIDGE_OK) s->failure = status;
    return status;
}
static bridge_status check(bridge_remotexpc *s, uint64_t deadline) {
    if (!s || !s->transport || s->in_callback) return BRIDGE_E_ARGUMENT;
    if (s->failure != BRIDGE_OK) return s->failure;
    if (s->transport->clock_ms(s->transport->context) >= deadline) return fail(s, BRIDGE_E_TIMEOUT);
    return BRIDGE_OK;
}
static bridge_status read_bytes(bridge_remotexpc *s, uint8_t *p, size_t n, uint64_t d) {
    return fail(s, bridge_read_exact(s->transport, p, n, d));
}
static bridge_status frame(bridge_remotexpc *s, uint8_t type, uint8_t flags,
    uint32_t id, const uint8_t *p, size_t n, uint64_t d) {
    uint8_t h[9] = {(uint8_t)(n >> 16), (uint8_t)(n >> 8), (uint8_t)n, type, flags, 0, 0, 0, 0};
    put32(h + 5, id);
    bridge_status e = bridge_write_exact(s->transport, h, sizeof h, d);
    if (e == BRIDGE_OK && n) e = bridge_write_exact(s->transport, p, n, d);
    return fail(s, e);
}
static bridge_status window_update(bridge_remotexpc *s, uint32_t id, uint32_t n, uint64_t d) {
    uint8_t p[4]; put32(p, n); return frame(s, 8, 0, id, p, 4, d);
}
static bridge_status credit(bridge_remotexpc *s, bridge_remotexpc_stream *st, uint32_t n, uint64_t d) {
    s->receive_pending += n; st->receive_pending += n;
    if (s->receive_pending >= RXPC_REPLENISH) {
        bridge_status e = window_update(s, 0, s->receive_pending, d);
        if (e != BRIDGE_OK) return e;
        s->receive_window += s->receive_pending; s->receive_pending = 0;
    }
    if (st->receive_pending >= RXPC_REPLENISH) {
        bridge_status e = window_update(s, st->message.stream_id, st->receive_pending, d);
        if (e != BRIDGE_OK) return e;
        st->receive_window += st->receive_pending; st->receive_pending = 0;
    }
    return BRIDGE_OK;
}
static bridge_status emit(bridge_remotexpc *s, bridge_remotexpc_stream *st,
    bridge_remotexpc_event event, const uint8_t *p, size_t n, uint64_t d) {
    bridge_status e = BRIDGE_OK;
    if (!s->consumer && event == BRIDGE_RXPC_BEGIN && st->message.wrapper_size > 24)
        return fail(s, BRIDGE_E_UNSUPPORTED);
    if (s->consumer) {
        s->in_callback = true;
        e = s->consumer(s->consumer_context, event, &st->message, p, n);
        s->in_callback = false;
    }
    if (e == BRIDGE_OK) e = check(s, d);
    return fail(s, e);
}
static bridge_status data_done(bridge_remotexpc *s, bridge_remotexpc_stream *st) {
    if (!s->frame_left) {
        s->data_active = false;
        if (s->frame_flags & 1u) {
            st->remote_closed = true;
            if (st->active || st->header_used) return fail(s, BRIDGE_E_FORMAT);
        }
    }
    return BRIDGE_OK;
}
static bridge_status data_chunk(bridge_remotexpc *s, uint64_t d) {
    bridge_remotexpc_stream *st = stream_for(s, s->frame_stream);
    if (!st) return fail(s, BRIDGE_E_UNSUPPORTED);
    if (!s->frame_left) return data_done(s, st);
    size_t n;
    bridge_status e;
    if (!st->active) {
        n = BRIDGE_XPC_WRAPPER_SIZE - st->header_used;
        if (n > s->frame_left) n = s->frame_left;
        e = read_bytes(s, st->header + st->header_used, n, d);
        if (e != BRIDGE_OK) return e;
        st->header_used += n; s->frame_left -= (uint32_t)n;
        if (st->header_used == BRIDGE_XPC_WRAPPER_SIZE) {
            uint64_t size = le64(st->header + 8);
            uint32_t flags = le32(st->header + 4);
            const uint32_t allowed = UINT32_C(0x00430303);
            if (le32(st->header) != UINT32_C(0x29b00b92) || !(flags & 1u))
                return fail(s, BRIDGE_E_FORMAT);
            if ((flags & ~allowed) != 0) return fail(s, BRIDGE_E_UNSUPPORTED);
            if (size > s->max_wrapper_size - BRIDGE_XPC_WRAPPER_SIZE) return fail(s, BRIDGE_E_LIMIT);
            if (size && size < 12u) return fail(s, BRIDGE_E_FORMAT);
            st->message.flags = flags; st->message.message_id = le64(st->header + 16);
            st->message.wrapper_size = size + BRIDGE_XPC_WRAPPER_SIZE;
            st->body_left = size; st->active = true;
            e = emit(s, st, BRIDGE_RXPC_BEGIN, NULL, 0, d);
            if (e == BRIDGE_OK) e = emit(s, st, BRIDGE_RXPC_CHUNK, st->header, BRIDGE_XPC_WRAPPER_SIZE, d);
            if (e != BRIDGE_OK) return e;
        }
    } else {
        n = sizeof s->scratch;
        if ((uint64_t)n > st->body_left) n = (size_t)st->body_left;
        if (n > s->frame_left) n = s->frame_left;
        e = read_bytes(s, s->scratch, n, d);
        if (e != BRIDGE_OK) return e;
        st->body_left -= n; s->frame_left -= (uint32_t)n;
        e = emit(s, st, BRIDGE_RXPC_CHUNK, s->scratch, n, d);
        if (e != BRIDGE_OK) return e;
    }
    if (st->active && !st->body_left) {
        e = emit(s, st, BRIDGE_RXPC_END, NULL, 0, d);
        if (e != BRIDGE_OK) return e;
        st->active = false; st->header_used = 0;
    }
    e = credit(s, st, (uint32_t)n, d);
    return e == BRIDGE_OK ? data_done(s, st) : e;
}
bridge_status bridge_remotexpc_init(bridge_remotexpc *s, bridge_io *io,
    uint64_t max, bridge_remotexpc_consumer consumer, void *ctx) {
    if (!s || !io || !io->read || !io->write || !io->clock_ms || max < 24) return BRIDGE_E_ARGUMENT;
    memset(s, 0, sizeof *s);
    s->transport = io; s->consumer = consumer; s->consumer_context = ctx;
    s->max_wrapper_size = max; s->send_window = 65535; s->peer_initial_window = 65535;
    s->receive_window = 65535;
    for (size_t i = 0; i < 2; ++i) {
        s->streams[i].send_window = 65535;
        s->streams[i].receive_window = BRIDGE_RXPC_RECEIVE_WINDOW;
        s->streams[i].message.stream_id = i == 0 ? 1u : 3u;
    }
    return BRIDGE_OK;
}
bridge_status bridge_remotexpc_abort(bridge_remotexpc *s, bridge_status reason) {
    if (!s || !s->transport || s->in_callback || reason == BRIDGE_OK ||
        (unsigned)reason > BRIDGE_E_UNSUPPORTED) return BRIDGE_E_ARGUMENT;
    return s->failure != BRIDGE_OK ? s->failure : fail(s, reason);
}
static bridge_status settings(bridge_remotexpc *s, uint8_t flags, uint32_t n, uint64_t d) {
    if (flags & 1u) {
        if (n || s->settings_acked) return fail(s, BRIDGE_E_FORMAT);
        s->settings_acked = true; return BRIDGE_OK;
    }
    if (n % 6u) return fail(s, BRIDGE_E_FORMAT);
    while (n) {
        uint8_t p[6]; bridge_status e = read_bytes(s, p, sizeof p, d);
        if (e != BRIDGE_OK) return e;
        uint16_t id = (uint16_t)((uint16_t)p[0] << 8 | p[1]); uint32_t value = be32(p + 2);
        if (id == 4) {
            if (value > RXPC_MAX_WINDOW) return fail(s, BRIDGE_E_FORMAT);
            int64_t delta = (int64_t)value - s->peer_initial_window;
            for (size_t i = 0; i < 2; ++i) {
                int64_t next = s->streams[i].send_window + delta;
                if (next > RXPC_MAX_WINDOW) return fail(s, BRIDGE_E_FORMAT);
                s->streams[i].send_window = next;
            }
            s->peer_initial_window = value;
        } else if (id == 5 && (value < 16384 || value > UINT32_C(0xffffff))) {
            return fail(s, BRIDGE_E_FORMAT);
        } else if (id == 2 && value > 1) {
            return fail(s, BRIDGE_E_FORMAT);
        } else if (id == 3 && value < 2) {
            return fail(s, BRIDGE_E_UNSUPPORTED);
        }
        n -= 6;
    }
    s->peer_settings = true;
    return frame(s, 4, 1, 0, NULL, 0, d);
}
static bridge_status pump_inner(bridge_remotexpc *s, uint64_t d) {
    bridge_status e = check(s, d);
    if (e != BRIDGE_OK) return e;
    if (!s->started) return BRIDGE_E_ARGUMENT;
    if (s->data_active) return data_chunk(s, d);
    uint8_t h[9]; e = read_bytes(s, h, sizeof h, d);
    if (e != BRIDGE_OK) return e;
    uint32_t n = (uint32_t)h[0] << 16 | (uint32_t)h[1] << 8 | h[2];
    uint32_t id = be32(h + 5) & RXPC_MAX_WINDOW;
    uint8_t type = h[3], flags = h[4];
    if (n > BRIDGE_RXPC_FRAME_SIZE) return fail(s, BRIDGE_E_LIMIT);
    if (s->continuation_stream && (type != 9 || id != s->continuation_stream))
        return fail(s, BRIDGE_E_FORMAT);
    bridge_remotexpc_stream *st = stream_for(s, id);
    switch (type) {
        case 0: /* DATA: no optional padding in this bounded RemoteXPC subset. */
            if (!id) return fail(s, BRIDGE_E_FORMAT);
            if (!st) return fail(s, BRIDGE_E_UNSUPPORTED);
            if (flags & 8u) return fail(s, BRIDGE_E_UNSUPPORTED);
            if (st->remote_closed) return fail(s, BRIDGE_E_FORMAT);
            if (n > s->receive_window || n > st->receive_window) return fail(s, BRIDGE_E_FORMAT);
            s->receive_window -= n; st->receive_window -= n;
            s->frame_left = n; s->frame_stream = id; s->frame_flags = flags; s->data_active = true;
            return data_chunk(s, d);
        case 1: /* HEADERS and CONTINUATION only support an empty HPACK block. */
        case 9:
            if (!id) return fail(s, BRIDGE_E_FORMAT);
            if (!st) return fail(s, BRIDGE_E_UNSUPPORTED);
            if (st->remote_closed) return fail(s, BRIDGE_E_FORMAT);
            if (type == 9 && !s->continuation_stream) return fail(s, BRIDGE_E_FORMAT);
            if (n || (type == 1 && (flags & 0x28u))) return fail(s, BRIDGE_E_UNSUPPORTED);
            s->continuation_stream = (flags & 4u) ? 0 : id;
            if (type == 1) s->continuation_end_stream = (flags & 1u) != 0;
            if (!s->continuation_stream && s->continuation_end_stream) {
                if (st->active || st->header_used) return fail(s, BRIDGE_E_FORMAT);
                st->remote_closed = true; s->continuation_end_stream = false;
            }
            return BRIDGE_OK;
        case 3: /* RST_STREAM */
            if (!id || n != 4) return fail(s, BRIDGE_E_FORMAT);
            if (!st) return fail(s, BRIDGE_E_UNSUPPORTED);
            e = read_bytes(s, s->scratch, 4, d); if (e != BRIDGE_OK) return e;
            s->peer_error = be32(s->scratch); return fail(s, BRIDGE_E_EOF);
        case 4:
            if (id) return fail(s, BRIDGE_E_FORMAT);
            return settings(s, flags, n, d);
        case 6: /* PING */
            if (id || n != 8) return fail(s, BRIDGE_E_FORMAT);
            e = read_bytes(s, s->scratch, 8, d); if (e != BRIDGE_OK) return e;
            return (flags & 1u) ? BRIDGE_OK : frame(s, 6, 1, 0, s->scratch, 8, d);
        case 7: /* GOAWAY: terminal, including graceful shutdown in this subset. */
            if (id || n < 8) return fail(s, BRIDGE_E_FORMAT);
            e = read_bytes(s, s->scratch, 8, d); if (e != BRIDGE_OK) return e;
            s->peer_error = be32(s->scratch + 4); return fail(s, BRIDGE_E_EOF);
        case 8: {
            if (n != 4) return fail(s, BRIDGE_E_FORMAT);
            if (id && !st) return fail(s, BRIDGE_E_UNSUPPORTED);
            e = read_bytes(s, s->scratch, 4, d); if (e != BRIDGE_OK) return e;
            uint32_t inc = be32(s->scratch) & RXPC_MAX_WINDOW;
            int64_t *window = id ? &st->send_window : &s->send_window;
            if (!inc || *window + inc > RXPC_MAX_WINDOW) return fail(s, BRIDGE_E_FORMAT);
            *window += inc; return BRIDGE_OK;
        }
        case 2: case 5: /* Priority / push are not part of this service subset. */
            return fail(s, BRIDGE_E_UNSUPPORTED);
        default:
            /* HTTP/2 unknown extensions are ignored without allocating body. */
            while (n) {
                size_t part = n < sizeof s->scratch ? n : sizeof s->scratch;
                e = read_bytes(s, s->scratch, part, d); if (e != BRIDGE_OK) return e;
                n -= (uint32_t)part;
            }
            return BRIDGE_OK;
    }
}
bridge_status bridge_remotexpc_pump(bridge_remotexpc *s, uint64_t d) {
    if (s && s->response_attached) return BRIDGE_E_ARGUMENT;
    return pump_inner(s, d);
}
static bridge_status send_data(bridge_remotexpc *s, uint32_t id, const uint8_t *p, size_t n, uint64_t d) {
    bridge_remotexpc_stream *st = stream_for(s, id);
    if (!st || st->remote_closed) return fail(s, BRIDGE_E_EOF);
    while (n) {
        bridge_status e = check(s, d); if (e != BRIDGE_OK) return e;
        int64_t budget = s->send_window < st->send_window ? s->send_window : st->send_window;
        if (budget <= 0) {
            e = bridge_remotexpc_pump(s, d); if (e != BRIDGE_OK) return e;
            if (st->remote_closed) return fail(s, BRIDGE_E_EOF);
            continue;
        }
        size_t part = n < BRIDGE_RXPC_FRAME_SIZE ? n : BRIDGE_RXPC_FRAME_SIZE;
        if ((int64_t)part > budget) part = (size_t)budget;
        e = frame(s, 0, 0, id, p, part, d); if (e != BRIDGE_OK) return e;
        s->send_window -= (int64_t)part; st->send_window -= (int64_t)part;
        p += part; n -= part;
    }
    return BRIDGE_OK;
}
bridge_status bridge_remotexpc_handshake(bridge_remotexpc *s, uint64_t d) {
    bridge_status e = check(s, d);
    if (e != BRIDGE_OK) return e;
    if (s->started) return BRIDGE_E_ARGUMENT;
    s->started = true;
    static const uint8_t preface[] = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n";
    e = fail(s, bridge_write_exact(s->transport, preface, sizeof preface - 1, d));
    const uint8_t settings_payload[12] = {0,3,0,0,0,100,0,4,0,0,0x40,0};
    if (e == BRIDGE_OK) e = frame(s, 4, 0, 0, settings_payload, sizeof settings_payload, d);
    if (e == BRIDGE_OK) e = frame(s, 1, 4, 1, NULL, 0, d);
    bridge_xpc_object empty = {.type = BRIDGE_XPC_DICTIONARY, .value.dictionary = {NULL, 0}};
    uint8_t wrapper[64]; size_t size = 0;
    if (e == BRIDGE_OK) e = bridge_xpc_encode(&empty, 1, 0, wrapper, sizeof wrapper, &size);
    if (e == BRIDGE_OK) e = send_data(s, 1, wrapper, size, d);
    if (e == BRIDGE_OK) e = frame(s, 1, 4, 3, NULL, 0, d);
    if (e == BRIDGE_OK) e = bridge_xpc_encode(NULL, 0x201, 0, wrapper, sizeof wrapper, &size);
    if (e == BRIDGE_OK) e = send_data(s, 1, wrapper, size, d);
    if (e == BRIDGE_OK) e = bridge_xpc_encode(NULL, 0x400001, 0, wrapper, sizeof wrapper, &size);
    if (e == BRIDGE_OK) e = send_data(s, 3, wrapper, size, d);
    while (e == BRIDGE_OK && !s->peer_settings) e = bridge_remotexpc_pump(s, d);
    if (e == BRIDGE_OK) { s->ready = true; s->next_message_id = 1; }
    return fail(s, e);
}
bridge_status bridge_remotexpc_send_encoded(bridge_remotexpc *s, const uint8_t *p,
    size_t n, uint64_t d, uint64_t *message_id) {
    if (!s || !p || !message_id || s->in_callback || s->response_attached || !s->ready) return BRIDGE_E_ARGUMENT;
    bridge_status e = check(s, d); if (e != BRIDGE_OK) return e;
    if (s->next_message_id == UINT64_MAX) return BRIDGE_E_LIMIT;
    bridge_xpc_message message;
    e = bridge_xpc_parse(p, n, &message); if (e != BRIDGE_OK) return e;
    if (message.message_id != s->next_message_id) return BRIDGE_E_ARGUMENT;
    if (!(message.flags & BRIDGE_XPC_FLAG_ALWAYS_SET) ||
        (message.flags & ~(BRIDGE_XPC_FLAG_ALWAYS_SET | BRIDGE_XPC_FLAG_DATA_PRESENT | BRIDGE_XPC_FLAG_WANTING_REPLY)))
        return BRIDGE_E_UNSUPPORTED;
    e = send_data(s, 1, p, n, d);
    if (e == BRIDGE_OK) *message_id = s->next_message_id++;
    return e;
}
bridge_status bridge_remotexpc_send(bridge_remotexpc *s, const bridge_xpc_object *root,
    bool wanting_reply, uint8_t *scratch, size_t capacity, uint64_t d, uint64_t *message_id) {
    if (!s || !root || !scratch || !message_id || !s->ready || s->in_callback || s->response_attached) return BRIDGE_E_ARGUMENT;
    uint32_t flags = BRIDGE_XPC_FLAG_ALWAYS_SET;
    if (root->type != BRIDGE_XPC_DICTIONARY || root->value.dictionary.count) flags |= BRIDGE_XPC_FLAG_DATA_PRESENT;
    if (wanting_reply) flags |= BRIDGE_XPC_FLAG_WANTING_REPLY;
    size_t n;
    bridge_status e = bridge_xpc_encode(root, flags, s->next_message_id, scratch, capacity, &n);
    return e == BRIDGE_OK ? bridge_remotexpc_send_encoded(s, scratch, n, d, message_id) : e;
}
static bridge_status response_event(void *ctx, bridge_remotexpc_event event,
    const bridge_remotexpc_message *message, const uint8_t *p, size_t n) {
    bridge_remotexpc_response *r = ctx;
    bool selected = (!r->expected_stream || message->stream_id == r->expected_stream) &&
        (r->match_id ? message->message_id == r->expected_id : message->wrapper_size > 24) &&
        (r->expected_stream || message->wrapper_size > 24);
    if (event == BRIDGE_RXPC_BEGIN && selected && !r->complete) {
        if (r->active) return BRIDGE_E_FORMAT;
        r->active = true; r->message = *message;
    }
    if (r->active && message->stream_id == r->message.stream_id) {
        if (event == BRIDGE_RXPC_CHUNK) {
            if (r->pending_size || n > sizeof r->pending) return BRIDGE_E_LIMIT;
            memcpy(r->pending, p, n); r->pending_offset = 0; r->pending_size = n;
        } else if (event == BRIDGE_RXPC_END) {
            r->active = false; r->complete = true;
        }
        return BRIDGE_OK;
    }
    if (r->previous_consumer) return r->previous_consumer(r->previous_context, event, message, p, n);
    return event == BRIDGE_RXPC_BEGIN && message->wrapper_size > 24 ? BRIDGE_E_UNSUPPORTED : BRIDGE_OK;
}
static uint64_t response_clock(void *ctx) {
    bridge_remotexpc_response *r = ctx;
    return r->session->transport->clock_ms(r->session->transport->context);
}
static ptrdiff_t response_read(void *ctx, uint8_t *p, size_t n, uint32_t timeout) {
    bridge_remotexpc_response *r = ctx;
    if (!r->attached || !p || !n) return -(ptrdiff_t)BRIDGE_E_ARGUMENT;
    uint64_t now = response_clock(ctx);
    uint64_t d = UINT64_MAX - now < timeout ? UINT64_MAX : now + timeout;
    while (!r->pending_size) {
        if (r->complete) return 0;
        bridge_remotexpc_stream *st = stream_for(r->session, r->expected_stream);
        if (!st && r->expected_stream) return -(ptrdiff_t)fail(r->session, BRIDGE_E_ARGUMENT);
        bool closed = st ? st->remote_closed :
            (r->session->streams[0].remote_closed && r->session->streams[1].remote_closed);
        if (closed) return -(ptrdiff_t)fail(r->session, BRIDGE_E_EOF);
        bridge_status e = pump_inner(r->session, d);
        if (e != BRIDGE_OK) return -(ptrdiff_t)e;
    }
    if (n > r->pending_size) n = r->pending_size;
    memcpy(p, r->pending + r->pending_offset, n);
    r->pending_offset += n; r->pending_size -= n;
    return (ptrdiff_t)n;
}
bridge_status bridge_remotexpc_response_open(bridge_remotexpc *s,
    bridge_remotexpc_response *r, uint32_t id, bool match_id, uint64_t message_id) {
    if (!s || !r || !s->ready || s->response_attached || s->in_callback ||
        (id && !stream_for(s, id))) return BRIDGE_E_ARGUMENT;
    if (s->failure != BRIDGE_OK) return s->failure;
    if (s->streams[0].active || s->streams[0].header_used || s->streams[1].active || s->streams[1].header_used)
        return BRIDGE_E_ARGUMENT;
    memset(r, 0, sizeof *r);
    r->session = s; r->previous_consumer = s->consumer; r->previous_context = s->consumer_context;
    r->expected_stream = id; r->expected_id = message_id; r->match_id = match_id; r->attached = true;
    r->io = (bridge_io){r, response_read, NULL, response_clock};
    s->consumer = response_event; s->consumer_context = r; s->response_attached = true;
    return BRIDGE_OK;
}
bridge_status bridge_remotexpc_response_finish(bridge_remotexpc_response *r, bridge_status result) {
    if (!r || !r->attached || r->session->in_callback) return BRIDGE_E_ARGUMENT;
    bridge_remotexpc *s = r->session;
    if (s->failure != BRIDGE_OK) result = s->failure;
    else if (result == BRIDGE_OK && (!r->complete || r->pending_size)) result = BRIDGE_E_FORMAT;
    s->consumer = r->previous_consumer; s->consumer_context = r->previous_context;
    s->response_attached = false; r->attached = false;
    return fail(s, result);
}
