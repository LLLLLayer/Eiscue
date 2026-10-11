/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_rsd.h"
#include "bridge_requests.h"
#include <string.h>

static const char *const service_names[BRIDGE_RSD_SERVICE_COUNT] = {
    BRIDGE_SCREENSHOT_SERVICE, BRIDGE_DISPLAY_SERVICE,
    BRIDGE_UNIVERSAL_HID_SERVICE, BRIDGE_INDIGO_SERVICE
};
static const char *const feature_names[] = {
    NULL, "com.apple.coredevice.feature.capturescreenshot",
    "com.apple.coredevice.feature.getmediasupportinfo",
    "com.apple.coredevice.feature.getmediastreamserverstatus",
    "com.apple.coredevice.feature.startmediastream",
    "com.apple.coredevice.feature.stopmediastream"
};
const char *bridge_rsd_service_name(bridge_rsd_service id) {
    return (unsigned)id < BRIDGE_RSD_SERVICE_COUNT ? service_names[id] : NULL;
}
const char *bridge_rsd_feature_name(bridge_rsd_feature id) {
    return (unsigned)id < sizeof feature_names / sizeof feature_names[0] ? feature_names[id] : NULL;
}
static void wipe(void *memory, size_t size) {
    volatile uint8_t *p = memory;
    while (size--) *p++ = 0;
}
static void release_scratch(bridge_rsd *s) {
    if (s->peer_scratch) wipe(s->peer_scratch, s->peer_used);
    wipe(s->control.scratch, sizeof s->control.scratch);
    for (size_t i = 0; i < 2; ++i)
        if (!s->control.streams[i].active && !s->control.streams[i].header_used)
            wipe(s->control.streams[i].header, sizeof s->control.streams[i].header);
    s->peer_scratch = NULL; s->peer_capacity = 0; s->peer_used = 0;
    s->peer_active = false;
}
static void close_control(bridge_rsd *s) {
    if (s->control_open) {
        s->dialer.close(s->dialer.context, &s->control_io);
        s->control_open = false;
        memset(&s->control_io, 0, sizeof s->control_io);
    }
}
static bridge_status failed(bridge_rsd *s, bridge_status e) {
    if (s->failure == BRIDGE_OK) s->failure = e;
    if (s->control.transport) (void)bridge_remotexpc_abort(&s->control, s->failure);
    close_control(s); release_scratch(s);
    memset(s->services, 0, sizeof s->services);
    s->state = BRIDGE_RSD_FAILED;
    return s->failure;
}
static bridge_status ready(const bridge_rsd *s) {
    if (!s) return BRIDGE_E_ARGUMENT;
    if (s->state == BRIDGE_RSD_FAILED) return s->failure;
    if (s->state != BRIDGE_RSD_READY || !s->control_open) return BRIDGE_E_ARGUMENT;
    return s->control.failure;
}
static bool equal_string(const bridge_xpc_view *v, const char *text) {
    size_t size = strlen(text);
    return v->type == BRIDGE_XPC_STRING && v->size == size && !memcmp(v->payload, text, size);
}
static bridge_status parse_port(const bridge_xpc_view *v, uint16_t *out) {
    uint64_t port = 0;
    if (v->type == BRIDGE_XPC_UINT64) {
        bridge_status e = bridge_xpc_uint64(v, &port);
        if (e != BRIDGE_OK) return e;
    } else if (v->type == BRIDGE_XPC_INT64) {
        int64_t value = 0;
        bridge_status e = bridge_xpc_int64(v, &value);
        if (e != BRIDGE_OK) return e;
        if (value <= 0) return BRIDGE_E_FORMAT;
        port = (uint64_t)value;
    } else if (v->type == BRIDGE_XPC_STRING) {
        /* Canonical decimal only. Python int also accepts signs/whitespace;
         * those undocumented wire representations are deliberately rejected. */
        if (!v->size || v->size > 5) return BRIDGE_E_FORMAT;
        for (size_t i = 0; i < v->size; ++i) {
            uint8_t c = v->payload[i];
            if (c < '0' || c > '9') return BRIDGE_E_FORMAT;
            port = port * 10 + (uint64_t)(c - '0');
        }
    } else return BRIDGE_E_TYPE;
    if (!port || port > UINT16_MAX) return BRIDGE_E_FORMAT;
    *out = (uint16_t)port;
    return BRIDGE_OK;
}
static bridge_status parse_entry(const bridge_xpc_view *v, bridge_rsd_entry *out) {
    if (v->type != BRIDGE_XPC_DICTIONARY) return BRIDGE_E_TYPE;
    bridge_xpc_view value, properties;
    bridge_status e = bridge_xpc_dict_find(v, "Port", &value);
    if (e != BRIDGE_OK) return e;
    e = parse_port(&value, &out->port);
    if (e != BRIDGE_OK) return e;
    e = bridge_xpc_dict_find(v, "Properties", &properties);
    if (e == BRIDGE_E_NOT_FOUND) return BRIDGE_OK;
    if (e != BRIDGE_OK) return e;
    if (properties.type != BRIDGE_XPC_DICTIONARY) return BRIDGE_E_TYPE;
    e = bridge_xpc_dict_find(&properties, "UsesRemoteXPC", &value);
    if (e == BRIDGE_OK) {
        bool supported = false;
        e = bridge_xpc_bool(&value, &supported);
        if (e != BRIDGE_OK) return e;
        out->remote_xpc = supported ? BRIDGE_RSD_ALLOWED : BRIDGE_RSD_DENIED;
    } else if (e != BRIDGE_E_NOT_FOUND) return e;
    e = bridge_xpc_dict_find(&properties, "Features", &value);
    if (e == BRIDGE_E_NOT_FOUND) return BRIDGE_OK;
    if (e != BRIDGE_OK) return e;
    if (value.type == BRIDGE_XPC_NULL) return BRIDGE_OK;
    if (value.type != BRIDGE_XPC_ARRAY) return BRIDGE_E_TYPE;
    out->features_advertised = value.count != 0;
    for (size_t i = 0; i < value.count; ++i) {
        bridge_xpc_view feature;
        e = bridge_xpc_array_at(&value, i, &feature);
        if (e != BRIDGE_OK) return e;
        if (feature.type != BRIDGE_XPC_STRING) return BRIDGE_E_TYPE;
        for (unsigned j = BRIDGE_RSD_CAPTURE_SCREENSHOT; j <= BRIDGE_RSD_MEDIA_STOP; ++j)
            if (equal_string(&feature, feature_names[j])) out->feature_mask |= (uint8_t)(1u << j);
    }
    return BRIDGE_OK;
}
static bridge_status parse_info(bridge_rsd *s) {
    bridge_xpc_message message;
    bridge_status e = bridge_xpc_parse(s->peer_scratch, s->peer_used, &message);
    if (e != BRIDGE_OK) return e;
    if (!message.has_payload || message.root.type != BRIDGE_XPC_DICTIONARY) return BRIDGE_E_TYPE;
    bridge_xpc_view services;
    e = bridge_xpc_dict_find(&message.root, "Services", &services);
    if (e != BRIDGE_OK) return e;
    if (services.type != BRIDGE_XPC_DICTIONARY) return BRIDGE_E_TYPE;
    bridge_rsd_entry entries[BRIDGE_RSD_SERVICE_COUNT] = {{0}};
    for (unsigned i = 0; i < BRIDGE_RSD_SERVICE_COUNT; ++i) {
        bridge_xpc_view service;
        e = bridge_xpc_dict_find(&services, service_names[i], &service);
        if (e == BRIDGE_E_NOT_FOUND) continue;
        if (e != BRIDGE_OK) return e;
        e = parse_entry(&service, &entries[i]);
        if (e != BRIDGE_OK) return e;
    }
    memcpy(s->services, entries, sizeof entries);
    /* receive_response advances the received stream's sequence, without
     * request-ID matching. Only root IDs are transmitted by this C subset. */
    if (s->peer_stream == BRIDGE_RXPC_ROOT) {
        if (message.message_id == UINT64_MAX) return BRIDGE_E_LIMIT;
        s->control.next_message_id = message.message_id + 1;
    }
    return BRIDGE_OK;
}
static bridge_status peer_event(void *context, bridge_remotexpc_event event,
    const bridge_remotexpc_message *m, const uint8_t *data, size_t size) {
    bridge_rsd *s = context;
    if (m->wrapper_size == BRIDGE_XPC_WRAPPER_SIZE) return BRIDGE_OK;
    if (event == BRIDGE_RXPC_BEGIN) {
        if (!s->peer_scratch || s->peer_active || s->peer_complete) return BRIDGE_E_UNSUPPORTED;
        if (m->wrapper_size > s->peer_capacity) return BRIDGE_E_LIMIT;
        s->peer_active = true; s->peer_stream = m->stream_id; s->peer_used = 0;
    }
    if (!s->peer_active || s->peer_stream != m->stream_id) return BRIDGE_E_FORMAT;
    if (event == BRIDGE_RXPC_CHUNK) {
        if (size > s->peer_capacity - s->peer_used) return BRIDGE_E_LIMIT;
        memcpy(s->peer_scratch + s->peer_used, data, size); s->peer_used += size;
    } else if (event == BRIDGE_RXPC_END) {
        bridge_xpc_message parsed;
        bridge_status e = bridge_xpc_parse(s->peer_scratch, s->peer_used, &parsed);
        if (e != BRIDGE_OK) return e;
        s->peer_active = false;
        /* receive_response also skips dictionaries with no entries. */
        if (parsed.has_payload && parsed.root.type == BRIDGE_XPC_DICTIONARY && !parsed.root.count) {
            wipe(s->peer_scratch, s->peer_used); s->peer_used = 0;
        } else s->peer_complete = true;
    }
    return BRIDGE_OK;
}
bridge_status bridge_rsd_init(bridge_rsd *s, const bridge_rsd_dialer *dialer,
    const uint8_t address[16], uint16_t port) {
    if (!s || !dialer || !dialer->dial || !dialer->close || !address || !port) return BRIDGE_E_ARGUMENT;
    memset(s, 0, sizeof *s); s->dialer = *dialer;
    memcpy(s->server_ipv6, address, 16); s->rsd_port = port; s->state = BRIDGE_RSD_NEW;
    return BRIDGE_OK;
}
static bridge_status hello(bridge_rsd *s, const uint8_t uuid[16], uint64_t deadline) {
    bridge_xpc_object type = {.type = BRIDGE_XPC_STRING, .value.string = "Handshake"};
    bridge_xpc_object version = {.type = BRIDGE_XPC_UINT64, .value.uint64 = 7};
    bridge_xpc_object identity = {.type = BRIDGE_XPC_UUID};
    memcpy(identity.value.uuid, uuid, 16);
    bridge_xpc_object flags = {.type = BRIDGE_XPC_UINT64, .value.uint64 = UINT64_C(0x0100000000000006)};
    bridge_xpc_object visible = {.type = BRIDGE_XPC_BOOL, .value.boolean = true};
    bridge_xpc_entry props[] = {{"RemoteXPCVersionFlags", &flags}, {"SensitivePropertiesVisible", &visible}};
    bridge_xpc_object properties = {.type = BRIDGE_XPC_DICTIONARY, .value.dictionary = {props, 2}};
    bridge_xpc_object services = {.type = BRIDGE_XPC_DICTIONARY, .value.dictionary = {NULL, 0}};
    bridge_xpc_entry entries[] = {{"MessageType", &type}, {"MessagingProtocolVersion", &version},
        {"UUID", &identity}, {"Properties", &properties}, {"Services", &services}};
    bridge_xpc_object root = {.type = BRIDGE_XPC_DICTIONARY, .value.dictionary = {entries, 5}};
    uint8_t encoded[BRIDGE_RSD_HELLO_CAPACITY];
    uint64_t message_id;
    bridge_status e = bridge_remotexpc_send(&s->control, &root, false, encoded, sizeof encoded, deadline, &message_id);
    wipe(encoded, sizeof encoded); wipe(&identity, sizeof identity);
    return e;
}
bridge_status bridge_rsd_connect(bridge_rsd *s, const uint8_t uuid[16],
    uint8_t *scratch, size_t capacity, uint64_t deadline) {
    if (!s) return BRIDGE_E_ARGUMENT;
    if (s->state == BRIDGE_RSD_FAILED) return s->failure;
    if (s->state != BRIDGE_RSD_NEW || !uuid || !scratch || capacity < BRIDGE_XPC_WRAPPER_SIZE ||
        capacity > BRIDGE_RSD_MAX_PEER_INFO) return BRIDGE_E_ARGUMENT;
    s->state = BRIDGE_RSD_CONNECTING;
    s->peer_scratch = scratch; s->peer_capacity = capacity;
    bridge_status e = s->dialer.dial(s->dialer.context, s->server_ipv6, s->rsd_port, deadline, &s->control_io);
    if (e != BRIDGE_OK) return failed(s, e);
    s->control_open = true;
    e = bridge_remotexpc_init(&s->control, &s->control_io, capacity, peer_event, s);
    if (e == BRIDGE_OK) e = bridge_remotexpc_handshake(&s->control, deadline);
    if (e == BRIDGE_OK) e = hello(s, uuid, deadline);
    while (e == BRIDGE_OK && !s->peer_complete) e = bridge_remotexpc_pump(&s->control, deadline);
    if (e == BRIDGE_OK) e = parse_info(s);
    if (e == BRIDGE_OK && s->control_io.clock_ms(s->control_io.context) >= deadline) e = BRIDGE_E_TIMEOUT;
    if (e != BRIDGE_OK) return failed(s, e);
    release_scratch(s); s->state = BRIDGE_RSD_READY;
    return BRIDGE_OK;
}
bridge_status bridge_rsd_get_port(const bridge_rsd *s, bridge_rsd_service id, uint16_t *out) {
    if (!out || !bridge_rsd_service_name(id)) return BRIDGE_E_ARGUMENT;
    *out = 0;
    bridge_status e = ready(s);
    if (e != BRIDGE_OK) return e;
    if (!s->services[id].port) return BRIDGE_E_NOT_FOUND;
    *out = s->services[id].port; return BRIDGE_OK;
}
bridge_status bridge_rsd_require_feature(const bridge_rsd *s, bridge_rsd_service id,
    bridge_rsd_feature feature, bridge_rsd_availability *out) {
    if (!out || (unsigned)feature > BRIDGE_RSD_MEDIA_STOP) return BRIDGE_E_ARGUMENT;
    *out = BRIDGE_RSD_UNKNOWN;
    if ((feature == BRIDGE_RSD_CAPTURE_SCREENSHOT && id != BRIDGE_RSD_SCREENSHOT) ||
        (feature >= BRIDGE_RSD_MEDIA_SUPPORT && id != BRIDGE_RSD_DISPLAY)) return BRIDGE_E_ARGUMENT;
    uint16_t port;
    bridge_status e = bridge_rsd_get_port(s, id, &port);
    if (e != BRIDGE_OK) return e;
    if (feature == BRIDGE_RSD_FEATURE_NONE || !s->services[id].features_advertised) return BRIDGE_OK;
    *out = (s->services[id].feature_mask & (uint8_t)(1u << feature)) ? BRIDGE_RSD_ALLOWED : BRIDGE_RSD_DENIED;
    return *out == BRIDGE_RSD_DENIED ? BRIDGE_E_UNSUPPORTED : BRIDGE_OK;
}
bridge_status bridge_rsd_open_service(bridge_rsd *s, bridge_rsd_service id,
    bridge_rsd_feature feature, bridge_rsd_connection *out, uint64_t max_wrapper,
    bridge_remotexpc_consumer consumer, void *context, uint64_t deadline) {
    if (!out || out->open || max_wrapper < BRIDGE_XPC_WRAPPER_SIZE) return BRIDGE_E_ARGUMENT;
    bridge_rsd_availability availability;
    bridge_status e = bridge_rsd_require_feature(s, id, feature, &availability);
    if (e != BRIDGE_OK) return e;
    if (s->services[id].remote_xpc == BRIDGE_RSD_DENIED) return BRIDGE_E_UNSUPPORTED;
    if (s->control_io.clock_ms(s->control_io.context) >= deadline) return BRIDGE_E_TIMEOUT;
    memset(out, 0, sizeof *out); out->dialer = s->dialer;
    e = s->dialer.dial(s->dialer.context, s->server_ipv6, s->services[id].port, deadline, &out->io);
    if (e != BRIDGE_OK) return e;
    out->open = true;
    e = bridge_remotexpc_init(&out->session, &out->io, max_wrapper, consumer, context);
    if (e == BRIDGE_OK) e = bridge_remotexpc_handshake(&out->session, deadline);
    if (e != BRIDGE_OK) bridge_rsd_close_service(out);
    return e;
}
void bridge_rsd_close_service(bridge_rsd_connection *s) {
    if (s && s->open) {
        if (s->session.transport) (void)bridge_remotexpc_abort(&s->session, BRIDGE_E_EOF);
        s->dialer.close(s->dialer.context, &s->io);
        s->open = false; memset(&s->io, 0, sizeof s->io);
    }
}
bridge_status bridge_rsd_drain_service(bridge_rsd_connection *s, uint64_t deadline) {
    if (!s || !s->open) return BRIDGE_E_ARGUMENT;
    if (s->session.failure != BRIDGE_OK) return s->session.failure;
    if (!s->dialer.drain) return BRIDGE_E_UNSUPPORTED;
    bridge_status e = s->io.clock_ms(s->io.context) >= deadline ? BRIDGE_E_TIMEOUT :
        s->dialer.drain(s->dialer.context, &s->io, deadline);
    if (e == BRIDGE_OK && s->io.clock_ms(s->io.context) >= deadline) e = BRIDGE_E_TIMEOUT;
    return e == BRIDGE_OK ? BRIDGE_OK : bridge_remotexpc_abort(&s->session, e);
}
bridge_status bridge_rsd_pump(bridge_rsd *s, uint64_t deadline) {
    bridge_status e = ready(s);
    if (e != BRIDGE_OK) return e;
    e = bridge_remotexpc_pump(&s->control, deadline);
    return e == BRIDGE_OK ? BRIDGE_OK : failed(s, e);
}
void bridge_rsd_close(bridge_rsd *s) {
    if (!s || s->state == BRIDGE_RSD_CLOSED) return;
    if (s->control.transport) (void)bridge_remotexpc_abort(&s->control, BRIDGE_E_EOF);
    close_control(s); release_scratch(s);
    memset(s->services, 0, sizeof s->services); s->state = BRIDGE_RSD_CLOSED;
}
