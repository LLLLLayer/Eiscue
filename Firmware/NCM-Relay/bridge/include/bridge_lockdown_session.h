/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef BRIDGE_LOCKDOWN_SESSION_H
#define BRIDGE_LOCKDOWN_SESSION_H
#include "bridge_core.h"

#define BRIDGE_LOCKDOWN_COREDEVICE_PROXY "com.apple.internal.devicecompute.CoreDeviceProxy"
#define BRIDGE_LOCKDOWN_ID_CAPACITY 128u
#define BRIDGE_LOCKDOWN_SESSION_MIN_WORKSPACE 2048u
#define BRIDGE_LOCKDOWN_SESSION_MAX_WORKSPACE 4096u

/* Only a previously paired identity is supported. No Pair, credential creation,
 * import, persistent storage, or raw reply/identifier logging is performed.
 * IDs are bounded printable ASCII; the opaque TLS identity is owned by caller.
 * All three fields must remain valid until close; TLS must use this same identity.
 */
typedef struct {
    const char *host_id;
    const char *system_buid;
    const void *tls_identity;
} bridge_lockdown_pair_identity;

typedef enum {
    BRIDGE_LOCKDOWN_CHANNEL_SESSION = 0,
    BRIDGE_LOCKDOWN_CHANNEL_SERVICE
} bridge_lockdown_channel;

typedef struct {
    void *context;
    /* Port is host byte order. Set out on success. Failure may leave a partial
     * channel; close is always invoked for that attempt, even with a zero IO. */
    bridge_status (*open_service)(void *, uint16_t, bridge_io *out, uint64_t deadline_ms);
    /* Upgrade exactly this stream, with the existing pair identity. Success
     * replaces inout with authenticated TLS I/O only after handshake completion.
     * Never report success for a partially negotiated stream or plaintext.
     * Failure is terminal; close must release any partial TLS/transport state.
     * Must enforce the absolute deadline. All IO clocks use the same domain. */
    bridge_status (*start_tls)(void *, bridge_lockdown_channel, bridge_io *inout,
        const void *tls_identity, uint64_t deadline_ms);
    /* Idempotent, nonblocking teardown, also valid for partial open/TLS failure.
     * Destroy TLS before closing its underlying transport; never send protocol
     * requests, reconnect, or wait indefinitely during teardown. */
    void (*close)(void *, bridge_lockdown_channel, bridge_io *);
} bridge_lockdown_session_ops;

typedef enum {
    BRIDGE_LOCKDOWN_NEW = 0, BRIDGE_LOCKDOWN_STARTING, BRIDGE_LOCKDOWN_ACTIVE,
    BRIDGE_LOCKDOWN_STARTING_SERVICE, BRIDGE_LOCKDOWN_SERVICE_READY,
    BRIDGE_LOCKDOWN_STOPPING, BRIDGE_LOCKDOWN_CLOSED, BRIDGE_LOCKDOWN_FAILED
} bridge_lockdown_session_state;

typedef enum {
    BRIDGE_LOCKDOWN_FAILURE_NONE = 0, BRIDGE_LOCKDOWN_FAILURE_ARGUMENT,
    BRIDGE_LOCKDOWN_FAILURE_STATE, BRIDGE_LOCKDOWN_FAILURE_MISSING_IDENTITY,
    BRIDGE_LOCKDOWN_FAILURE_TRANSPORT, BRIDGE_LOCKDOWN_FAILURE_PROTOCOL,
    BRIDGE_LOCKDOWN_FAILURE_PEER, BRIDGE_LOCKDOWN_FAILURE_TLS
} bridge_lockdown_failure;

typedef enum {
    BRIDGE_LOCKDOWN_PEER_NONE = 0, BRIDGE_LOCKDOWN_PEER_INVALID_HOST_ID,
    BRIDGE_LOCKDOWN_PEER_INVALID_CONNECTION, BRIDGE_LOCKDOWN_PEER_SESSION_INACTIVE,
    BRIDGE_LOCKDOWN_PEER_PASSWORD_PROTECTED, BRIDGE_LOCKDOWN_PEER_INVALID_SERVICE,
    BRIDGE_LOCKDOWN_PEER_SERVICE_PROHIBITED, BRIDGE_LOCKDOWN_PEER_OTHER
} bridge_lockdown_peer_error;

typedef enum {
    BRIDGE_LOCKDOWN_REPLY_START_SESSION = 0,
    BRIDGE_LOCKDOWN_REPLY_START_SERVICE,
    BRIDGE_LOCKDOWN_REPLY_STOP_SESSION
} bridge_lockdown_reply_kind;

typedef struct {
    char session_id[BRIDGE_LOCKDOWN_ID_CAPACITY]; /* sensitive; never log */
    uint16_t port;
    bool enable_ssl;
    bridge_lockdown_peer_error peer_error; /* bounded category, never raw text */
} bridge_lockdown_reply;

/* Strict flat XML/binary plist subset. Request echo required. Optional flags
 * default to false, but if present must be plist boolean (not string/integer).
 * StartSession requires nonempty SessionID, StartService requires port 1..65535,
 * StopSession requires Result=Success. Unknown/duplicate fields, nesting,
 * overlapping/unreachable binary objects and trailing documents are rejected.
 * On peer Error or legacy Result=Failure returns BRIDGE_E_TYPE with only
 * peer_error set. Other failures leave out zero. Pure parser, no allocation. */
bridge_status bridge_lockdown_session_parse_reply(const uint8_t *, size_t,
    bridge_lockdown_reply_kind, bridge_lockdown_reply *out);

typedef struct {
    bridge_lockdown_session_state state;
    bridge_lockdown_failure failure;
    bridge_lockdown_peer_error peer_error;
    bridge_status status;
    bool session_ssl, service_ssl, owns_session, owns_service;
    uint16_t service_port;
    char session_id[BRIDGE_LOCKDOWN_ID_CAPACITY];
    bridge_io session_io, service_io;
    bridge_lockdown_session_ops ops;
    bridge_lockdown_pair_identity identity;
    uint8_t *workspace;
    size_t workspace_capacity;
} bridge_lockdown_session;

/* Single caller, no recursion or concurrent calls. Fields are diagnostic/read-
 * only to callers. Storage arguments must be disjoint. No heap allocation.
 * init takes ownership of the already connected plaintext lockdownd stream
 * only on BRIDGE_OK. On init failure caller retains it. Never re-init a live
 * session. Use QueryType separately before init if service probing is desired.
 * All subsequent failures are terminal: both owned channels close, SessionID
 * and workspace are erased, and no retries/resynchronization are allowed.
 * Explicit close is idempotent. stop sends StopSession over current session
 * transport (TLS if negotiated), then closes both channels; no TLS downgrade.
 * Modern CoreDevice policy requires EnableSessionSSL=true; false or absent
 * fails UNSUPPORTED before StartService. Service SSL follows its reply flag.
 * Each operation uses one absolute deadline, including connect/TLS callbacks.
 */
bridge_status bridge_lockdown_session_init(bridge_lockdown_session *, const bridge_io *,
    const bridge_lockdown_session_ops *, const bridge_lockdown_pair_identity *,
    uint8_t *workspace, size_t workspace_capacity);
bridge_status bridge_lockdown_session_start(bridge_lockdown_session *, uint64_t deadline_ms);
bridge_status bridge_lockdown_session_start_coredevice_proxy(bridge_lockdown_session *, uint64_t deadline_ms);
bridge_status bridge_lockdown_session_stop(bridge_lockdown_session *, uint64_t deadline_ms);
void bridge_lockdown_session_close(bridge_lockdown_session *);
/* NULL until StartService connect and required TLS both succeed. Borrowed IO,
 * invalidated by stop/close/failure. Its use must obey the same deadline rules. */
bridge_io *bridge_lockdown_session_service_io(bridge_lockdown_session *);
#endif
