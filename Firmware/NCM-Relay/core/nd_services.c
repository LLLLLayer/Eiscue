/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "nd_services.h"
#include <string.h>
bridge_status nd_services_open(nd_services *s,const nd_authenticated_tunnel *t,const uint8_t uuid[16],uint8_t *scratch,size_t cap,uint64_t deadline) {
    if (!s || !t || !uuid || !scratch || s->ready || s->rsd.control_open) return BRIDGE_E_ARGUMENT;
    if ((t->route!=ND_ROUTE_LOCKDOWN && t->route!=ND_ROUTE_REMOTE_PAIRING) || t->identity_kind!=t->route ||
        !t->peer_verified || !t->developer_mode || !t->personalized_ddi) return BRIDGE_E_UNSUPPORTED;
    const uint8_t zero[16]={0};
    if (!memcmp(t->server_ipv6,zero,16) || t->server_ipv6[0]==0xff || !t->rsd_port) return BRIDGE_E_ARGUMENT;
    bridge_status r=bridge_rsd_init(&s->rsd,&t->dialer,t->server_ipv6,t->rsd_port);
    if (r==BRIDGE_OK) r=bridge_rsd_connect(&s->rsd,uuid,scratch,cap,deadline);
    s->ready=r==BRIDGE_OK; return r;
}
bridge_status nd_services_capture(nd_services *s,const bridge_invocation *invocation,uint8_t *scratch,size_t cap,bridge_sink_fn sink,void *context,uint64_t deadline,bridge_png_info *out) {
    if (out) memset(out,0,sizeof *out);
    if (!s || !s->ready) return BRIDGE_E_UNSUPPORTED;
    return bridge_capture_screenshot(&s->rsd,invocation,NULL,scratch,cap,BRIDGE_OPERATIONS_MAX_IMAGE_WRAPPER,sink,context,deadline,out);
}
bridge_status nd_services_tap(nd_services *s,uint16_t x,uint16_t y) { (void)s;(void)x;(void)y; return BRIDGE_E_UNSUPPORTED; }
void nd_services_close(nd_services *s) { if (s) { s->ready=false; bridge_rsd_close(&s->rsd); } }
