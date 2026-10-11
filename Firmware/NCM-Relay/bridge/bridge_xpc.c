/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Wire schema: pymobiledevice3/remote/xpc_message.py at
 * cd895d17ce8a97d883c10f87b26c7356d5e0ccb1. See THIRD_PARTY.md. */
#include "bridge_xpc.h"
#include <limits.h>
#include <string.h>

#define WRAPPER_MAGIC UINT32_C(0x29b00b92)
#define PAYLOAD_MAGIC UINT32_C(0x42133742)
#define PROTOCOL_VERSION UINT32_C(5)
_Static_assert(BRIDGE_XPC_MAX_MESSAGE_SIZE >= 36u &&
    BRIDGE_XPC_MAX_MESSAGE_SIZE <= UINT32_MAX - 3u, "XPC message limit must fit the wire lengths");

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 |
        (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static uint64_t le64(const uint8_t *p) {
    return (uint64_t)le32(p) | (uint64_t)le32(p + 4) << 32;
}
static size_t padded(size_t n) { return (n + 3u) & ~(size_t)3u; }

/* Reject overlong sequences, surrogates, incomplete sequences and > U+10ffff. */
static bool utf8_valid(const uint8_t *p, size_t n) {
    size_t i = 0;
    while (i < n) {
        uint8_t c = p[i++];
        if (c < 0x80u) continue;
        unsigned remaining;
        uint32_t cp, minimum;
        if (c >= 0xc2u && c <= 0xdfu) {
            remaining = 1; cp = c & 0x1fu; minimum = 0x80u;
        } else if (c >= 0xe0u && c <= 0xefu) {
            remaining = 2; cp = c & 0x0fu; minimum = 0x800u;
        } else if (c >= 0xf0u && c <= 0xf4u) {
            remaining = 3; cp = c & 0x07u; minimum = 0x10000u;
        } else return false;
        if ((size_t)remaining > n - i) return false;
        while (remaining-- > 0u) {
            uint8_t next = p[i++];
            if ((next & 0xc0u) != 0x80u) return false;
            cp = (cp << 6) | (next & 0x3fu);
        }
        if (cp < minimum || cp > 0x10ffffu || (cp >= 0xd800u && cp <= 0xdfffu)) return false;
    }
    return true;
}

static bridge_status string_size(const char *s, size_t *out) {
    if (!s) return BRIDGE_E_ARGUMENT;
    size_t n = 0;
    while (n < BRIDGE_XPC_MAX_MESSAGE_SIZE && s[n] != '\0') ++n;
    if (n == BRIDGE_XPC_MAX_MESSAGE_SIZE) return BRIDGE_E_LIMIT;
    if (!utf8_valid((const uint8_t *)s, n)) return BRIDGE_E_FORMAT;
    *out = n + 1u;
    return BRIDGE_OK;
}

typedef struct { uint8_t *data; size_t size; unsigned objects; } writer;
static bridge_status append(writer *w, const void *data, size_t n) {
    if (n > BRIDGE_XPC_MAX_MESSAGE_SIZE - w->size) return BRIDGE_E_LIMIT;
    if (w->data && n) {
        if (data) memcpy(w->data + w->size, data, n);
        else memset(w->data + w->size, 0, n);
    }
    w->size += n;
    return BRIDGE_OK;
}
static void patch32(writer *w, size_t at, uint32_t n) {
    if (w->data) {
        for (unsigned i = 0; i < 4u; ++i) w->data[at + i] = (uint8_t)(n >> (i * 8u));
    }
}
static bridge_status write32(writer *w, uint32_t n) {
    size_t at = w->size;
    bridge_status st = append(w, NULL, 4);
    if (st == BRIDGE_OK) patch32(w, at, n);
    return st;
}
static bridge_status write64(writer *w, uint64_t n) {
    bridge_status st = write32(w, (uint32_t)n);
    if (st == BRIDGE_OK) st = write32(w, (uint32_t)(n >> 32));
    return st;
}
#define TRY(expr) do { bridge_status status_ = (expr); if (status_ != BRIDGE_OK) return status_; } while (0)

static bridge_status encode_object(writer *w, const bridge_xpc_object *obj, unsigned depth) {
    if (!obj) return BRIDGE_E_ARGUMENT;
    if (depth > BRIDGE_XPC_MAX_DEPTH || ++w->objects > BRIDGE_XPC_MAX_OBJECTS) return BRIDGE_E_LIMIT;
    TRY(write32(w, (uint32_t)obj->type));
    size_t n = 0;
    switch (obj->type) {
        case BRIDGE_XPC_NULL: return BRIDGE_OK;
        case BRIDGE_XPC_BOOL: return write32(w, obj->value.boolean ? 1u : 0u);
        case BRIDGE_XPC_INT64: return write64(w, (uint64_t)obj->value.int64);
        case BRIDGE_XPC_UINT64: return write64(w, obj->value.uint64);
        case BRIDGE_XPC_UUID: return append(w, obj->value.uuid, 16);
        case BRIDGE_XPC_STRING:
            TRY(string_size(obj->value.string, &n));
            TRY(write32(w, (uint32_t)n));
            TRY(append(w, obj->value.string, n));
            return append(w, NULL, padded(n) - n);
        case BRIDGE_XPC_DATA:
            n = obj->value.bytes.size;
            if (n > BRIDGE_XPC_MAX_MESSAGE_SIZE) return BRIDGE_E_LIMIT;
            if (n && !obj->value.bytes.data) return BRIDGE_E_ARGUMENT;
            TRY(write32(w, (uint32_t)n));
            TRY(append(w, obj->value.bytes.data, n));
            return append(w, NULL, padded(n) - n);
        case BRIDGE_XPC_ARRAY:
        case BRIDGE_XPC_DICTIONARY: {
            bool dict = obj->type == BRIDGE_XPC_DICTIONARY;
            n = dict ? obj->value.dictionary.count : obj->value.array.count;
            if (n > BRIDGE_XPC_MAX_OBJECTS) return BRIDGE_E_LIMIT;
            if (n && (dict ? obj->value.dictionary.entries == NULL : obj->value.array.values == NULL))
                return BRIDGE_E_ARGUMENT;
            size_t at = w->size;
            TRY(write32(w, 0));
            TRY(write32(w, (uint32_t)n));
            for (size_t i = 0; i < n; ++i) {
                if (dict) {
                    const bridge_xpc_entry *entry = &obj->value.dictionary.entries[i];
                    size_t key_size;
                    TRY(string_size(entry->key, &key_size));
                    TRY(append(w, entry->key, key_size));
                    TRY(append(w, NULL, padded(key_size) - key_size));
                    TRY(encode_object(w, entry->value, depth + 1u));
                } else TRY(encode_object(w, &obj->value.array.values[i], depth + 1u));
            }
            patch32(w, at, (uint32_t)(w->size - at - 4u));
            return BRIDGE_OK;
        }
        default: return BRIDGE_E_UNSUPPORTED;
    }
}

static bridge_status encode_message(writer *w, const bridge_xpc_object *root,
        uint32_t flags, uint64_t message_id) {
    TRY(write32(w, WRAPPER_MAGIC));
    TRY(write32(w, flags));
    TRY(write64(w, 0));
    TRY(write64(w, message_id));
    if (root) {
        TRY(write32(w, PAYLOAD_MAGIC));
        TRY(write32(w, PROTOCOL_VERSION));
        TRY(encode_object(w, root, 1));
    }
    /* The wire uint64 length EXCLUDES message_id, despite the Prefixed Struct. */
    patch32(w, 8, (uint32_t)(w->size - BRIDGE_XPC_WRAPPER_SIZE));
    return BRIDGE_OK;
}

bridge_status bridge_xpc_encode(const bridge_xpc_object *root, uint32_t flags,
        uint64_t message_id, uint8_t *output, size_t capacity, size_t *out_size) {
    if (!out_size) return BRIDGE_E_ARGUMENT;
    *out_size = 0;
    if (!output && capacity) return BRIDGE_E_ARGUMENT;
    writer measure = {0};
    TRY(encode_message(&measure, root, flags, message_id));
    if (output) {
        if (capacity < measure.size) return BRIDGE_E_LIMIT;
        writer write = { .data = output };
        TRY(encode_message(&write, root, flags, message_id));
    }
    *out_size = measure.size;
    return BRIDGE_OK;
}

typedef struct { const uint8_t *data; size_t size, at; unsigned objects; } reader;
static bridge_status take(reader *r, size_t n, const uint8_t **out) {
    if (n > r->size - r->at) return BRIDGE_E_FORMAT;
    *out = r->data + r->at;
    r->at += n;
    return BRIDGE_OK;
}
static bridge_status read_key(reader *r, const uint8_t **key, size_t *size) {
    const uint8_t *begin = r->data + r->at;
    const uint8_t *end = memchr(begin, 0, r->size - r->at);
    if (!end) return BRIDGE_E_FORMAT;
    size_t n = (size_t)(end - begin);
    if (!utf8_valid(begin, n)) return BRIDGE_E_FORMAT;
    TRY(take(r, padded(n + 1u), key));
    *size = n;
    return BRIDGE_OK;
}

static bridge_status parse_object(reader *r, unsigned depth, bridge_xpc_view *out) {
    if (depth > BRIDGE_XPC_MAX_DEPTH || ++r->objects > BRIDGE_XPC_MAX_OBJECTS) return BRIDGE_E_LIMIT;
    const uint8_t *p;
    TRY(take(r, 4, &p));
    uint32_t wire_type = le32(p);
    bridge_xpc_view value = { .type = (bridge_xpc_type)wire_type, .depth = depth };
    size_t n = 0;
    switch (wire_type) {
        case BRIDGE_XPC_NULL: break;
        case BRIDGE_XPC_BOOL: n = 4; break;
        case BRIDGE_XPC_INT64:
        case BRIDGE_XPC_UINT64: n = 8; break;
        case BRIDGE_XPC_UUID: n = 16; break;
        case BRIDGE_XPC_STRING:
        case BRIDGE_XPC_DATA:
            TRY(take(r, 4, &p));
            n = le32(p);
            if (n > BRIDGE_XPC_MAX_MESSAGE_SIZE) return BRIDGE_E_LIMIT;
            TRY(take(r, padded(n), &value.payload));
            if (wire_type == BRIDGE_XPC_STRING) {
                if (!n || value.payload[n - 1u] != 0 || memchr(value.payload, 0, n - 1u) ||
                    !utf8_valid(value.payload, n - 1u)) return BRIDGE_E_FORMAT;
                --n;
            }
            value.size = n;
            *out = value;
            return BRIDGE_OK;
        case BRIDGE_XPC_ARRAY:
        case BRIDGE_XPC_DICTIONARY: {
            TRY(take(r, 4, &p));
            n = le32(p);
            if (n > BRIDGE_XPC_MAX_MESSAGE_SIZE) return BRIDGE_E_LIMIT;
            if (n < 4u) return BRIDGE_E_FORMAT;
            TRY(take(r, n, &p));
            value.count = le32(p);
            if (value.count > BRIDGE_XPC_MAX_OBJECTS - r->objects) return BRIDGE_E_LIMIT;
            value.payload = p + 4;
            value.size = n - 4u;
            reader entries = { .data = value.payload, .size = value.size, .objects = r->objects };
            for (uint32_t i = 0; i < value.count; ++i) {
                if (wire_type == BRIDGE_XPC_DICTIONARY) {
                    const uint8_t *key;
                    size_t key_size;
                    TRY(read_key(&entries, &key, &key_size));
                }
                bridge_xpc_view child;
                TRY(parse_object(&entries, depth + 1u, &child));
            }
            if (entries.at != entries.size) return BRIDGE_E_FORMAT;
            r->objects = entries.objects;
            *out = value;
            return BRIDGE_OK;
        }
        default: return BRIDGE_E_UNSUPPORTED;
    }
    TRY(take(r, n, &value.payload));
    value.size = n;
    *out = value;
    return BRIDGE_OK;
}

bridge_status bridge_xpc_parse(const uint8_t *data, size_t size, bridge_xpc_message *out) {
    if (!out) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof(*out));
    if (!data) return BRIDGE_E_ARGUMENT;
    if (size > BRIDGE_XPC_MAX_MESSAGE_SIZE) return BRIDGE_E_LIMIT;
    if (size < BRIDGE_XPC_WRAPPER_SIZE || le32(data) != WRAPPER_MAGIC ||
        le64(data + 8) != (uint64_t)(size - BRIDGE_XPC_WRAPPER_SIZE)) return BRIDGE_E_FORMAT;
    bridge_xpc_message message = { .flags = le32(data + 4), .message_id = le64(data + 16) };
    if (size > BRIDGE_XPC_WRAPPER_SIZE) {
        if (size < BRIDGE_XPC_WRAPPER_SIZE + 12u || le32(data + 24) != PAYLOAD_MAGIC ||
            le32(data + 28) != PROTOCOL_VERSION) return BRIDGE_E_FORMAT;
        reader r = { .data = data, .size = size, .at = 32 };
        TRY(parse_object(&r, 1, &message.root));
        if (r.at != size) return BRIDGE_E_FORMAT;
        message.has_payload = true;
    }
    *out = message;
    return BRIDGE_OK;
}

bridge_status bridge_xpc_dict_find(const bridge_xpc_view *dict, const char *key, bridge_xpc_view *out) {
    if (!dict || !key || !out || !dict->payload) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof(*out));
    if (dict->type != BRIDGE_XPC_DICTIONARY) return BRIDGE_E_TYPE;
    size_t wanted;
    TRY(string_size(key, &wanted));
    --wanted;
    reader r = { .data = dict->payload, .size = dict->size };
    bool found = false;
    bridge_xpc_view match = {0};
    for (uint32_t i = 0; i < dict->count; ++i) {
        const uint8_t *name;
        size_t length;
        TRY(read_key(&r, &name, &length));
        bridge_xpc_view child;
        TRY(parse_object(&r, dict->depth + 1u, &child));
        if (length == wanted && memcmp(name, key, wanted) == 0) {
            match = child;
            found = true;
        }
    }
    if (r.at != r.size) return BRIDGE_E_FORMAT;
    if (!found) return BRIDGE_E_NOT_FOUND;
    *out = match;
    return BRIDGE_OK;
}

bridge_status bridge_xpc_array_at(const bridge_xpc_view *array, size_t index, bridge_xpc_view *out) {
    if (!array || !out || !array->payload) return BRIDGE_E_ARGUMENT;
    memset(out, 0, sizeof(*out));
    if (array->type != BRIDGE_XPC_ARRAY) return BRIDGE_E_TYPE;
    if (index >= array->count) return BRIDGE_E_NOT_FOUND;
    reader r = { .data = array->payload, .size = array->size };
    bridge_xpc_view child;
    for (size_t i = 0; i <= index; ++i) TRY(parse_object(&r, array->depth + 1u, &child));
    *out = child;
    return BRIDGE_OK;
}

bridge_status bridge_xpc_bool(const bridge_xpc_view *view, bool *out) {
    if (!view || !out || !view->payload) return BRIDGE_E_ARGUMENT;
    if (view->type != BRIDGE_XPC_BOOL) return BRIDGE_E_TYPE;
    if (view->size != 4u) return BRIDGE_E_FORMAT;
    *out = le32(view->payload) != 0;
    return BRIDGE_OK;
}
bridge_status bridge_xpc_uint64(const bridge_xpc_view *view, uint64_t *out) {
    if (!view || !out || !view->payload) return BRIDGE_E_ARGUMENT;
    if (view->type != BRIDGE_XPC_UINT64) return BRIDGE_E_TYPE;
    if (view->size != 8u) return BRIDGE_E_FORMAT;
    *out = le64(view->payload);
    return BRIDGE_OK;
}
bridge_status bridge_xpc_int64(const bridge_xpc_view *view, int64_t *out) {
    if (!view || !out || !view->payload) return BRIDGE_E_ARGUMENT;
    if (view->type != BRIDGE_XPC_INT64) return BRIDGE_E_TYPE;
    if (view->size != 8u) return BRIDGE_E_FORMAT;
    uint64_t bits = le64(view->payload);
    /* Avoid implementation-defined unsigned-to-signed conversion. */
    *out = bits <= (uint64_t)INT64_MAX ? (int64_t)bits : -1 - (int64_t)(UINT64_MAX - bits);
    return BRIDGE_OK;
}
