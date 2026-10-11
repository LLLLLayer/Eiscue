/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "bridge_operations.h"
#include <string.h>

bridge_status bridge_capture_screenshot(bridge_rsd *rsd,const bridge_invocation *invocation,
    const char *display,uint8_t *scratch,size_t capacity,uint32_t max_wrapper,
    bridge_sink_fn sink,void *sink_context,uint64_t deadline,bridge_png_info *out) {
    if(!out) return BRIDGE_E_ARGUMENT;
    memset(out,0,sizeof *out);
    if(!rsd || !invocation || !scratch || capacity<BRIDGE_OPERATIONS_SCRATCH_MIN || !sink ||
       max_wrapper<BRIDGE_XPC_WRAPPER_SIZE || max_wrapper>BRIDGE_OPERATIONS_MAX_IMAGE_WRAPPER)
        return BRIDGE_E_ARGUMENT;
    bridge_rsd_connection connection={0};
    bridge_status s=bridge_rsd_open_service(rsd,BRIDGE_RSD_SCREENSHOT,BRIDGE_RSD_CAPTURE_SCREENSHOT,
        &connection,max_wrapper,NULL,NULL,deadline);
    if(s!=BRIDGE_OK) return s;
    bridge_invocation actual=*invocation;
    actual.message_id=connection.session.next_message_id;
    size_t encoded=0;
    s=bridge_request_screenshot(&actual,display,scratch,capacity,&encoded);
    uint64_t sent_id=0;
    if(s==BRIDGE_OK) s=bridge_remotexpc_send_encoded(&connection.session,scratch,encoded,deadline,&sent_id);
    bridge_remotexpc_response response;
    if(s==BRIDGE_OK) s=bridge_remotexpc_response_open(&connection.session,&response,BRIDGE_RXPC_ANY_STREAM,true,sent_id);
    if(s==BRIDGE_OK) {
        bridge_png_info info;
        s=bridge_xpc_extract_png(&response.io,max_wrapper,scratch,capacity,sink,sink_context,deadline,&info);
        if(s==BRIDGE_OK && info.message_id!=sent_id) s=BRIDGE_E_FORMAT;
        s=bridge_remotexpc_response_finish(&response,s);
        if(s==BRIDGE_OK) *out=info;
    }
    bridge_rsd_close_service(&connection);
    return s;
}
static bridge_status send_home(bridge_rsd_connection *connection,uint32_t state,
    uint8_t *scratch,size_t capacity,uint64_t deadline) {
    size_t encoded=0;uint64_t sent=0;
    bridge_status s=bridge_request_home(connection->session.next_message_id,state,scratch,capacity,&encoded);
    if(s==BRIDGE_OK) s=bridge_remotexpc_send_encoded(&connection->session,scratch,encoded,deadline,&sent);
    return s;
}
bridge_status bridge_press_home(bridge_rsd *rsd,bridge_operation_wait_fn wait,
    void *context,uint8_t *scratch,size_t capacity,uint64_t deadline,bridge_home_result *out) {
    if(!out) return BRIDGE_E_ARGUMENT;
    memset(out,0,sizeof *out);
    if(!rsd || !wait || !scratch || capacity<BRIDGE_OPERATIONS_SCRATCH_MIN) return BRIDGE_E_ARGUMENT;
    if(!rsd->dialer.drain) return BRIDGE_E_UNSUPPORTED;
    bridge_rsd_connection connection={0};
    bridge_status s=bridge_rsd_open_service(rsd,BRIDGE_RSD_INDIGO,BRIDGE_RSD_FEATURE_NONE,
        &connection,BRIDGE_XPC_MAX_MESSAGE_SIZE,NULL,NULL,deadline);
    if(s!=BRIDGE_OK) return s;
    uint64_t now=connection.io.clock_ms(connection.io.context);
    if(now>=deadline || deadline-now<=50u) {s=BRIDGE_E_TIMEOUT;goto done;}
    s=send_home(&connection,1,scratch,capacity,deadline);
    if(s!=BRIDGE_OK) goto done;
    out->down_written=true;
    s=bridge_rsd_drain_service(&connection,deadline);
    if(s!=BRIDGE_OK) goto done;
    out->down_peer_acked=true;
    now=connection.io.clock_ms(connection.io.context);
    bridge_status held=wait(context,50,deadline);
    uint64_t after=connection.io.clock_ms(connection.io.context);
    if(after>=deadline) {s=BRIDGE_E_TIMEOUT;goto done;}
    if(after<now || after-now<50u) held=BRIDGE_E_IO;
    /* If a caller wait failed early but transport/deadline are usable, still
     * attempt release. Preserve the original failure after the attempt. */
    s=send_home(&connection,2,scratch,capacity,deadline);
    if(s==BRIDGE_OK) {
        out->up_written=true;
        s=bridge_rsd_drain_service(&connection,deadline);
        if(s==BRIDGE_OK) out->bytes_peer_acked=true;
    }
    if(held!=BRIDGE_OK) s=held;
done:
    bridge_rsd_close_service(&connection);
    return s;
}
