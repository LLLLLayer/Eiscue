/* SPDX-License-Identifier: GPL-3.0-or-later
 * Selective translation of pymobiledevice3 CoreDevice request envelopes at
 * cd895d17ce8a97d883c10f87b26c7356d5e0ccb1, GPL-3.0-or-later. */
#include "bridge_requests.h"
#include <string.h>
#define COUNT(a) (sizeof(a)/sizeof((a)[0]))
#define STR(s) ((bridge_xpc_object){.type=BRIDGE_XPC_STRING,.value.string=(s)})
#define U64(n) ((bridge_xpc_object){.type=BRIDGE_XPC_UINT64,.value.uint64=(n)})
#define I64(n) ((bridge_xpc_object){.type=BRIDGE_XPC_INT64,.value.int64=(n)})
#define DICT(a) ((bridge_xpc_object){.type=BRIDGE_XPC_DICTIONARY,.value.dictionary={(a),COUNT(a)}})
#define ARRAY(a) ((bridge_xpc_object){.type=BRIDGE_XPC_ARRAY,.value.array={(a),COUNT(a)}})
#define DATA(p,n) ((bridge_xpc_object){.type=BRIDGE_XPC_DATA,.value.bytes={(p),(n)}})
#define EMPTY ((bridge_xpc_object){.type=BRIDGE_XPC_DICTIONARY,.value.dictionary={NULL,0}})
static bool uuid_string(const char *s) {
    if(!s) return false;
    for(size_t i=0;i<36;i++) {
        char c=s[i]; if(!c) return false;
        if(i==8 || i==13 || i==18 || i==23) { if(c!='-') return false; }
        else if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F'))) return false;
    }
    return !s[36];
}
static bridge_status invoke(const bridge_invocation *id, const char *feature, const char *action,
    const bridge_xpc_object *input, uint8_t *out, size_t cap, size_t *size) {
    if(!size) return BRIDGE_E_ARGUMENT;
    *size=0;
    if(!id || !uuid_string(id->device_identifier) || !uuid_string(id->invocation_identifier)) return BRIDGE_E_ARGUMENT;
    const bridge_xpc_object protocol=I64(2), version_parts[]={U64(629),U64(3)}, version_count=I64(2), version_text=STR("629.3");
    const bridge_xpc_object parts=ARRAY(version_parts);
    const bridge_xpc_entry ve[]={{"components",&parts},{"originalComponentsCount",&version_count},{"stringValue",&version_text}};
    const bridge_xpc_object version=DICT(ve), device=STR(id->device_identifier), invocation=STR(id->invocation_identifier);
    const bridge_xpc_object f=STR(feature),a=STR(action),empty=EMPTY;
    const bridge_xpc_entry entries[]={
        {"CoreDevice.CoreDeviceDDIProtocolVersion",&protocol},{"CoreDevice.coreDeviceVersion",&version},
        {"CoreDevice.deviceIdentifier",&device},{"CoreDevice.input",input},
        {"CoreDevice.invocationIdentifier",&invocation},{"CoreDevice.featureIdentifier",&f},
        {"CoreDevice.action",&empty},{"CoreDevice.actionIdentifier",&a}
    };
    const bridge_xpc_object root=DICT(entries);
    return bridge_xpc_encode(&root,BRIDGE_XPC_FLAG_ALWAYS_SET|BRIDGE_XPC_FLAG_DATA_PRESENT|BRIDGE_XPC_FLAG_WANTING_REPLY,
        id->message_id,out,cap,size);
}
bridge_status bridge_request_screenshot(const bridge_invocation *id, const char *display,
    uint8_t *out,size_t cap,size_t *size) {
    bridge_xpc_object d=display?STR(display):(bridge_xpc_object){.type=BRIDGE_XPC_NULL},format=STR("png");
    const bridge_xpc_entry entries[]={{"displayUniqueID",&d},{"requestedFormat",&format}};
    const bridge_xpc_object input=DICT(entries);
    return invoke(id,"com.apple.coredevice.feature.capturescreenshot","com.apple.coredevice.action.capturescreenshot",&input,out,cap,size);
}
bridge_status bridge_request_touch_report(uint64_t mid,uint64_t service,const uint8_t report[BRIDGE_TOUCH_REPORT_SIZE],
    uint8_t *out,size_t cap,size_t *size) {
    if(!size) return BRIDGE_E_ARGUMENT;
    *size=0;
    if(!report || !service || report[0]!=9 || report[1]!=1 || report[2]!=5 ||
       (report[3]!=BRIDGE_TOUCH_CONTACT && report[3]!=BRIDGE_TOUCH_RELEASE)) return BRIDGE_E_ARGUMENT;
    const bridge_xpc_object data=DATA(report,BRIDGE_TOUCH_REPORT_SIZE),sid=U64(service);
    const bridge_xpc_entry se[]={{"_0",&data},{"_1",&sid}};
    const bridge_xpc_object send=DICT(se);
    const bridge_xpc_entry pe[]={{"send",&send}};
    const bridge_xpc_object payload=DICT(pe),feature=STR("com.apple.coredevice.feature.remote.universalhidservice"),type=STR("Request");
    const bridge_xpc_entry e[]={{"featureIdentifier",&feature},{"messageType",&type},{"payload",&payload}};
    const bridge_xpc_object root=DICT(e);
    return bridge_xpc_encode(&root,BRIDGE_XPC_FLAG_ALWAYS_SET|BRIDGE_XPC_FLAG_DATA_PRESENT,mid,out,cap,size);
}
bridge_status bridge_request_home(uint64_t mid,uint32_t state,uint8_t *out,size_t cap,size_t *size) {
    if(!size) return BRIDGE_E_ARGUMENT;
    *size=0; if(state<1 || state>3) return BRIDGE_E_ARGUMENT;
    const bridge_xpc_object s=U64(state),page=U64(BRIDGE_HOME_USAGE_PAGE),usage=U64(BRIDGE_HOME_USAGE_CODE);
    const bridge_xpc_entry pe[]={{"state",&s},{"usagePage",&page},{"usageCode",&usage}};
    const bridge_xpc_object payload=DICT(pe),type=STR("IndigoButtonEvent"),feature=STR("com.apple.coredevice.feature.remote.hid.button");
    const bridge_xpc_entry e[]={{"messageType",&type},{"payload",&payload},{"featureIdentifier",&feature}};
    const bridge_xpc_object root=DICT(e);
    return bridge_xpc_encode(&root,BRIDGE_XPC_FLAG_ALWAYS_SET|BRIDGE_XPC_FLAG_DATA_PRESENT,mid,out,cap,size);
}
static bool ipv6_string(const char *s) {
    if(!s) return false;
    size_t n=0; bool colon=false;
    for(;n<64&&s[n];n++) { char c=s[n]; if(c==':') colon=true; else if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F')||c=='.')) return false; }
    return n>1&&n<64&&colon; /* syntax prefilter; transport must parse/validate actual tunnel address */
}
bridge_status bridge_request_media_start(const bridge_invocation *id,const uint8_t uuid[16],
    const char *receiver,uint16_t port,const char *sender,const uint8_t *offer,size_t offer_size,
    uint8_t *out,size_t cap,size_t *size) {
    if(!size) return BRIDGE_E_ARGUMENT;
    *size=0;
    if(!uuid || !ipv6_string(receiver) || !ipv6_string(sender) || !port || !offer || offer_size<8 ||
       offer_size>1024 || memcmp(offer,"bplist00",8)) return BRIDGE_E_ARGUMENT;
    const bridge_xpc_object one=I64(1),two=I64(2),display=STR("DisplayByID");
    bridge_xpc_object session={.type=BRIDGE_XPC_UUID}; memcpy(session.value.uuid,uuid,16);
    const bridge_xpc_entry ae[]={{"int",&one}},te[]={{"int",&two}},de[]={{"string",&display}},ie[]={{"int",&one}},se[]={{"uuid",&session}};
    const bridge_xpc_object access=DICT(ae),transport=DICT(te),mode=DICT(de),displayid=DICT(ie),sessionid=DICT(se);
    const bridge_xpc_entry options_e[]={
        {"AVCMediaStreamNegotiatorAccessNetworkType",&access},{"AVCMediaStreamNegotiatorTransportProtocolType",&transport},
        {"CoreDeviceVideoDisplayMode",&mode},{"VideoStreamForDisplayID",&displayid},{"avcMediaStreamOptionClientSessionID",&sessionid}
    };
    const bridge_xpc_object features=U64(140),direction=STR("output"),negotiator=DATA(offer,offer_size),options=DICT(options_e);
    const bridge_xpc_object rip=STR(receiver),rp=U64(port),sip=STR(sender),timeout=U64(20),type=STR("video");
    const bridge_xpc_entry e[]={{"clientSupportedFeatures",&features},{"direction",&direction},{"negotiatorOffer",&negotiator},
        {"options",&options},{"receiverIP",&rip},{"receiverPort",&rp},{"senderIP",&sip},{"timeout",&timeout},{"type",&type}};
    const bridge_xpc_object input=DICT(e);
    return invoke(id,"com.apple.coredevice.feature.startmediastream","com.apple.coredevice.action.mediastreamstart",&input,out,cap,size);
}
bridge_status bridge_request_media_stop(const bridge_invocation *id,uint32_t token,uint8_t *out,size_t cap,size_t *size) {
    const bridge_xpc_object no={.type=BRIDGE_XPC_BOOL,.value.boolean=false},ids[]={U64(token)},array=ARRAY(ids);
    const bridge_xpc_entry e[]={{"stopAll",&no},{"identifiers",&array}};
    const bridge_xpc_object input=DICT(e);
    return invoke(id,"com.apple.coredevice.feature.stopmediastream","com.apple.coredevice.action.mediastreamstop",&input,out,cap,size);
}
