/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_XPC_H
#define BRIDGE_XPC_H
#include "bridge_core.h"

/* Resident complete messages only, including the 24-byte wrapper. No heap
 * allocation; recursive validation/encoding is bounded by depth and object count.
 * These are hard upper bounds, not a promise that a target has this much RAM. */
#ifndef BRIDGE_XPC_MAX_MESSAGE_SIZE
#define BRIDGE_XPC_MAX_MESSAGE_SIZE (64u * 1024u)
#endif
#define BRIDGE_XPC_MAX_DEPTH 16u
#define BRIDGE_XPC_MAX_OBJECTS 4096u
#define BRIDGE_XPC_WRAPPER_SIZE 24u
#define BRIDGE_XPC_FLAG_ALWAYS_SET UINT32_C(0x00000001)
#define BRIDGE_XPC_FLAG_PING UINT32_C(0x00000002)
#define BRIDGE_XPC_FLAG_DATA_PRESENT UINT32_C(0x00000100)
#define BRIDGE_XPC_FLAG_WANTING_REPLY UINT32_C(0x00010000)
#define BRIDGE_XPC_FLAG_REPLY UINT32_C(0x00020000)
#define BRIDGE_XPC_FLAG_FILE_TX_STREAM_REQUEST UINT32_C(0x00100000)
#define BRIDGE_XPC_FLAG_FILE_TX_STREAM_RESPONSE UINT32_C(0x00200000)
#define BRIDGE_XPC_FLAG_INIT_HANDSHAKE UINT32_C(0x00400000)

typedef enum {
    BRIDGE_XPC_NULL = 0x1000, BRIDGE_XPC_BOOL = 0x2000,
    BRIDGE_XPC_INT64 = 0x3000, BRIDGE_XPC_UINT64 = 0x4000,
    BRIDGE_XPC_DATA = 0x8000, BRIDGE_XPC_STRING = 0x9000,
    BRIDGE_XPC_UUID = 0xa000, BRIDGE_XPC_ARRAY = 0xe000,
    BRIDGE_XPC_DICTIONARY = 0xf000
} bridge_xpc_type;

typedef struct bridge_xpc_object bridge_xpc_object;
typedef struct {
    const char *key; /* NUL-terminated UTF-8, no embedded NUL */
    const bridge_xpc_object *value;
} bridge_xpc_entry;
struct bridge_xpc_object {
    bridge_xpc_type type;
    union {
        bool boolean;
        int64_t int64;
        uint64_t uint64;
        const char *string; /* NUL-terminated UTF-8 */
        struct { const uint8_t *data; size_t size; } bytes;
        uint8_t uuid[16]; /* RFC 4122 byte order, as uuid.UUID.bytes */
        struct { const bridge_xpc_object *values; size_t count; } array;
        struct { const bridge_xpc_entry *entries; size_t count; } dictionary;
    } value;
};

/* Flags are passed through exactly, rather than inferred. A NULL root means no
 * payload; BRIDGE_XPC_NULL encodes an actual typed NULL payload. With output=NULL
 * and capacity=0, returns the required size without writing. On failure out_size
 * is zero and output is untouched. Inputs must remain stable and must not overlap
 * output. The input object tree is borrowed only during this call. */
bridge_status bridge_xpc_encode(const bridge_xpc_object *root, uint32_t flags,
    uint64_t message_id, uint8_t *output, size_t capacity, size_t *out_size);

/* Views borrow the original immutable message. Keep it resident and unchanged.
 * For STRING, payload/size excludes the terminating NUL. For DATA/UUID it is the
 * raw byte sequence. For ARRAY/DICTIONARY it is the encoded entries, excluding
 * their length/count. Never construct or alter views manually. */
typedef struct {
    bridge_xpc_type type;
    const uint8_t *payload;
    size_t size;
    uint32_t count;
    unsigned depth;
} bridge_xpc_view;
typedef struct {
    uint32_t flags;
    uint64_t message_id;
    bool has_payload;
    bridge_xpc_view root;
} bridge_xpc_message;

/* Requires exactly one complete wrapper; validates every nested object, UTF-8,
 * count, length and bound before exposing root. No partial/streaming decode.
 * Unknown object types fail with UNSUPPORTED; trailing bytes fail with FORMAT. */
bridge_status bridge_xpc_parse(const uint8_t *data, size_t size, bridge_xpc_message *out);
/* Duplicate keys follow upstream decode behavior: the last matching entry wins. */
bridge_status bridge_xpc_dict_find(const bridge_xpc_view *, const char *key, bridge_xpc_view *out);
bridge_status bridge_xpc_array_at(const bridge_xpc_view *, size_t index, bridge_xpc_view *out);
bridge_status bridge_xpc_bool(const bridge_xpc_view *, bool *out);
bridge_status bridge_xpc_int64(const bridge_xpc_view *, int64_t *out);
bridge_status bridge_xpc_uint64(const bridge_xpc_view *, uint64_t *out);
#endif
