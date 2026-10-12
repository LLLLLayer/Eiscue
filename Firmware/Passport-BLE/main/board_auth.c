// SPDX-License-Identifier: Apache-2.0
#include "board_auth.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "mbedtls/md.h"
#include "nvs.h"
#include <string.h>

#define AUTH_CONTEXT_SIZE 48
#define ENROLLMENT_US INT64_C(60000000)

static const char *AUTH_NAMESPACE="eiscue_auth";
static const char *BOARD_ID_KEY="board_id";
static const char *ROOT_KEY="root_key";
static uint8_t board_id[16],root_key[32],board_nonce[16],session_key[32];
static bool ready,key_present,connected,attempted,authenticated;
static uint32_t last_sequence;

static void wipe(void *data,size_t length) {
    volatile uint8_t *bytes=data;
    while(length--)*bytes++=0;
}
static bool equal_tag(const uint8_t *a,const uint8_t *b,size_t length) {
    volatile uint8_t difference=0;
    for(size_t i=0;i<length;i++)difference|=a[i]^b[i];
    return difference==0;
}
static bool mac(const uint8_t key[32],const char *label,const uint8_t *body,
    size_t length,uint8_t out[32]) {
    uint8_t message[96];
    size_t label_length=strlen(label);
    if(label_length+length>sizeof message)return false;
    memcpy(message,label,label_length);memcpy(message+label_length,body,length);
    const mbedtls_md_info_t *info=mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
    bool ok=info && mbedtls_md_hmac(info,key,32,message,label_length+length,out)==0;
    wipe(message,sizeof message);
    if(!ok)wipe(out,32);
    return ok;
}
static bool enrollment_open(void) {
    int64_t uptime=esp_timer_get_time();
    return ready && !key_present && uptime>=0 && uptime<ENROLLMENT_US;
}
static void revoke_session(void) {
    authenticated=false;last_sequence=0;wipe(session_key,sizeof session_key);
}
static esp_err_t read_exact(nvs_handle_t handle,const char *name,void *value,size_t length) {
    size_t stored_length=length;
    esp_err_t error=nvs_get_blob(handle,name,value,&stored_length);
    if(error==ESP_OK && stored_length!=length)return ESP_ERR_INVALID_SIZE;
    return error;
}
esp_err_t board_auth_init(void) {
    ready=false;key_present=false;board_auth_end_connection();
    wipe(board_id,sizeof board_id);wipe(root_key,sizeof root_key);
    nvs_handle_t handle;
    esp_err_t error=nvs_open(AUTH_NAMESPACE,NVS_READWRITE,&handle);
    if(error!=ESP_OK)return error;
    error=read_exact(handle,ROOT_KEY,root_key,sizeof root_key);
    if(error==ESP_OK)key_present=true;
    else if(error==ESP_ERR_NVS_NOT_FOUND)error=ESP_OK;
    if(error==ESP_OK)error=read_exact(handle,BOARD_ID_KEY,board_id,sizeof board_id);
    if(error==ESP_ERR_NVS_NOT_FOUND) {
        // A claimed board must not silently invent a new persistent identity.
        if(key_present)error=ESP_ERR_INVALID_STATE;
        else {
            esp_fill_random(board_id,sizeof board_id);
            error=nvs_set_blob(handle,BOARD_ID_KEY,board_id,sizeof board_id);
            if(error==ESP_OK)error=nvs_commit(handle);
        }
    }
    nvs_close(handle);
    if(error!=ESP_OK){wipe(root_key,sizeof root_key);wipe(board_id,sizeof board_id);return error;}
    ready=true;return ESP_OK;
}
void board_auth_begin_connection(void) {
    board_auth_end_connection();
    if(!ready)return;
    esp_fill_random(board_nonce,sizeof board_nonce);connected=true;
}
void board_auth_end_connection(void) {
    revoke_session();connected=false;attempted=false;
    wipe(board_nonce,sizeof board_nonce);
}
void board_auth_get_challenge(uint8_t out[BOARD_AUTH_CHALLENGE_SIZE]) {
    memset(out,0,BOARD_AUTH_CHALLENGE_SIZE);out[0]=BOARD_AUTH_VERSION;
    if(!ready || !connected)return;
    out[1]=(key_present?1:0)|(enrollment_open()?2:0);
    memcpy(out+2,board_id,16);memcpy(out+18,board_nonce,16);
}
// Recheck the persistent record instead of relying on a startup flag. On any
// uncertain write, fail closed until reboot; never overwrite a first claim.
static bool save_first_key(const uint8_t key[32]) {
    nvs_handle_t handle;
    esp_err_t error=nvs_open(AUTH_NAMESPACE,NVS_READWRITE,&handle);
    if(error!=ESP_OK){ready=false;return false;}
    size_t length=0;
    error=nvs_get_blob(handle,ROOT_KEY,NULL,&length);
    if(error==ESP_ERR_NVS_NOT_FOUND) {
        error=nvs_set_blob(handle,ROOT_KEY,key,32);
        if(error==ESP_OK)error=nvs_commit(handle);
    } else if(error==ESP_OK)error=ESP_ERR_INVALID_STATE;
    nvs_close(handle);
    if(error!=ESP_OK){ready=false;return false;}
    memcpy(root_key,key,32);key_present=true;return true;
}
bool board_auth_handle_request(const uint8_t *data,size_t length,
    uint8_t out[BOARD_AUTH_RESPONSE_SIZE]) {
    memset(out,0,BOARD_AUTH_RESPONSE_SIZE);revoke_session();
    if(!ready || !connected || attempted)return false;
    attempted=true;
    if(!data || length!=BOARD_AUTH_REQUEST_SIZE || data[0]!=BOARD_AUTH_VERSION)return false;
    uint8_t operation=data[1],context[AUTH_CONTEXT_SIZE],expected[32],new_session[32];
    bool ok=false;
    memcpy(context,board_id,16);memcpy(context+16,board_nonce,16);memcpy(context+32,data+2,16);
    const uint8_t *key=root_key;
    if(operation==BOARD_AUTH_ENROLL) {
        if(!enrollment_open())goto finish;
        key=data+18;
    } else if(operation==BOARD_AUTH_PROVE) {
        if(!key_present || !mac(key,"EiscueBLE/v2/client",context,sizeof context,expected) ||
            !equal_tag(expected,data+18,32))goto finish;
    } else goto finish;
    if(!mac(key,"EiscueBLE/v2/session",context,sizeof context,new_session))goto finish;
    out[0]=BOARD_AUTH_VERSION;out[1]=operation;out[2]=0;
    uint8_t server_body[AUTH_CONTEXT_SIZE+3];
    memcpy(server_body,context,sizeof context);memcpy(server_body+sizeof context,out,3);
    bool signed_reply=mac(key,"EiscueBLE/v2/server",server_body,sizeof server_body,out+3);
    wipe(server_body,sizeof server_body);
    if(!signed_reply)goto finish;
    if(operation==BOARD_AUTH_ENROLL && !save_first_key(key))goto finish;
    memcpy(session_key,new_session,32);authenticated=true;ok=true;
finish:
    wipe(context,sizeof context);wipe(expected,sizeof expected);wipe(new_session,sizeof new_session);
    if(!ok){memset(out,0,BOARD_AUTH_RESPONSE_SIZE);revoke_session();}
    return ok;
}
static uint32_t read_sequence(const uint8_t *bytes) {
    return (uint32_t)bytes[0]|((uint32_t)bytes[1]<<8)|((uint32_t)bytes[2]<<16)|((uint32_t)bytes[3]<<24);
}
static void write_sequence(uint8_t *bytes,uint32_t sequence) {
    for(unsigned i=0;i<4;i++)bytes[i]=(uint8_t)(sequence>>(8*i));
}
bool board_auth_unwrap_command(const uint8_t *data,size_t length,
    uint8_t inner[16],uint32_t *sequence) {
    memset(inner,0,16);*sequence=0;
    if(!board_auth_is_authenticated() || !data || length!=BOARD_AUTH_COMMAND_SIZE ||
        data[0]!=BOARD_AUTH_VERSION)return false;
    uint32_t candidate=read_sequence(data+16);
    if(candidate==0 || candidate<=last_sequence)return false;
    uint8_t tag[32];
    bool ok=mac(session_key,"EiscueBLE/v2/cmd",data,20,tag) && equal_tag(tag,data+20,32);
    wipe(tag,sizeof tag);
    if(!ok)return false;
    last_sequence=candidate;memcpy(inner,data,16);inner[0]=1;*sequence=candidate;return true;
}
bool board_auth_wrap_reply(const uint8_t inner[8],uint32_t sequence,
    uint8_t out[BOARD_AUTH_REPLY_SIZE]) {
    uint8_t saved[8];
    if(inner)memcpy(saved,inner,sizeof saved);
    memset(out,0,BOARD_AUTH_REPLY_SIZE);
    if(!board_auth_is_authenticated() || !inner || !sequence || sequence>last_sequence)return false;
    memcpy(out,saved,8);out[0]=BOARD_AUTH_VERSION;write_sequence(out+8,sequence);
    if(mac(session_key,"EiscueBLE/v2/reply",out,12,out+12))return true;
    memset(out,0,BOARD_AUTH_REPLY_SIZE);return false;
}
bool board_auth_is_authenticated(void) {return ready && connected && authenticated;}
bool board_auth_has_key(void) {return ready && key_present;}
