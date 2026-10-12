// SPDX-License-Identifier: Apache-2.0
// Runs the actual auth module against bounded in-memory NVS and time/random
// providers. OpenSSL performs real HMAC; fixed vectors were generated in Python.
#include "board_auth.h"
#include "esp_random.h"
#include "esp_timer.h"
#include "mbedtls/md.h"
#include "nvs.h"
#include <assert.h>
#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <stdio.h>
#include <string.h>

static uint8_t stored_id[64],stored_key[64],next_random;
static size_t id_length,key_length;
static int64_t now;
static bool fail_open,fail_commit,fail_hmac;
static unsigned writes;
static const uint8_t private_canary[]={0x97,0x13,0x04,0x29};
static uint8_t private_configuration[sizeof private_canary];
esp_err_t nvs_open(const char *name,int mode,nvs_handle_t *handle) {
    assert(strcmp(name,"eiscue_auth")==0 && mode==NVS_READWRITE);
    if(fail_open)return ESP_FAIL;
    *handle=1;return ESP_OK;
}
esp_err_t nvs_get_blob(nvs_handle_t handle,const char *name,void *value,size_t *length) {
    assert(handle==1);
    bool id=strcmp(name,"board_id")==0;assert(id || strcmp(name,"root_key")==0);
    size_t actual=id?id_length:key_length;
    if(!actual)return ESP_ERR_NVS_NOT_FOUND;
    if(!value){*length=actual;return ESP_OK;}
    if(*length<actual){*length=actual;return ESP_ERR_INVALID_SIZE;}
    memcpy(value,id?stored_id:stored_key,actual);*length=actual;return ESP_OK;
}
esp_err_t nvs_set_blob(nvs_handle_t handle,const char *name,const void *value,size_t length) {
    assert(handle==1 && length<=sizeof stored_key);
    bool id=strcmp(name,"board_id")==0;assert(id || strcmp(name,"root_key")==0);
    memcpy(id?stored_id:stored_key,value,length);
    if(id)id_length=length;else key_length=length;
    writes++;return ESP_OK;
}
esp_err_t nvs_commit(nvs_handle_t handle){assert(handle==1);return fail_commit?ESP_FAIL:ESP_OK;}
void nvs_close(nvs_handle_t handle){assert(handle==1);}
void esp_fill_random(void *value,size_t length) {
    uint8_t *bytes=value;for(size_t i=0;i<length;i++)bytes[i]=next_random++;
}
int64_t esp_timer_get_time(void){return now;}
const mbedtls_md_info_t *mbedtls_md_info_from_type(int type) {
    static const mbedtls_md_info_t info={MBEDTLS_MD_SHA256};
    assert(type==MBEDTLS_MD_SHA256);return &info;
}
int mbedtls_md_hmac(const mbedtls_md_info_t *info,const unsigned char *key,size_t key_length,
    const unsigned char *input,size_t input_length,unsigned char *output) {
    assert(info->type==MBEDTLS_MD_SHA256 && key_length==32);
    unsigned length=0;
    return fail_hmac || !HMAC(EVP_sha256(),key,(int)key_length,input,input_length,output,&length) || length!=32?-1:0;
}
static void reset_store(void) {
    board_auth_end_connection();memset(stored_id,0,sizeof stored_id);memset(stored_key,0,sizeof stored_key);
    id_length=key_length=writes=0;now=1000000;next_random=32;
    fail_open=fail_commit=fail_hmac=false;memcpy(private_configuration,private_canary,sizeof private_canary);
}
static void root_bytes(uint8_t root[32]){for(unsigned i=0;i<32;i++)root[i]=(uint8_t)i;}
static void assert_hex(const uint8_t *actual,const char *hex,size_t length) {
    assert(strlen(hex)==length*2);
    for(size_t i=0;i<length;i++){unsigned byte;assert(sscanf(hex+2*i,"%2x",&byte)==1);assert(actual[i]==byte);}
}
static bool all_zero(const uint8_t *value,size_t length) {
    for(size_t i=0;i<length;i++)if(value[i])return false;return true;
}
static void independent_mac(const uint8_t root[32],const char *label,const uint8_t *body,size_t length,uint8_t out[32]) {
    uint8_t message[96];size_t prefix=strlen(label);assert(prefix+length<=sizeof message);
    memcpy(message,label,prefix);memcpy(message+prefix,body,length);
    unsigned result=0;assert(HMAC(EVP_sha256(),root,32,message,prefix+length,out,&result) && result==32);
}
static void context_for(const uint8_t challenge[34],const uint8_t request[50],uint8_t context[48]) {
    memcpy(context,challenge+2,32);memcpy(context+32,request+2,16);
}
static void make_request(uint8_t op,const uint8_t challenge[34],uint8_t request[50],uint8_t session[32]) {
    uint8_t root[32],context[48];root_bytes(root);memset(request,0,50);request[0]=2;request[1]=op;
    for(unsigned i=0;i<16;i++)request[2+i]=(uint8_t)(64+i);
    context_for(challenge,request,context);
    if(op==1)memcpy(request+18,root,32);else independent_mac(root,"EiscueBLE/v2/client",context,48,request+18);
    independent_mac(root,"EiscueBLE/v2/session",context,48,session);
}
static void make_command(const uint8_t session[32],uint32_t sequence,uint8_t out[52]) {
    memset(out,0,52);out[0]=2;out[1]=7;out[2]=1;
    for(unsigned i=0;i<4;i++)out[16+i]=(uint8_t)(sequence>>(8*i));
    independent_mac(session,"EiscueBLE/v2/cmd",out,20,out+20);
}
static void enroll(uint8_t session[32]) {
    uint8_t challenge[34],request[50],reply[35];
    assert(board_auth_init()==ESP_OK);board_auth_begin_connection();board_auth_get_challenge(challenge);
    make_request(1,challenge,request,session);assert(board_auth_handle_request(request,50,reply));
}
static void shared_vectors_and_pending_reply(void) {
    reset_store();assert(board_auth_init()==ESP_OK);board_auth_begin_connection();
    uint8_t challenge[34],second[34],request[50],response[35],session[32];
    board_auth_get_challenge(challenge);board_auth_get_challenge(second);assert(memcmp(challenge,second,34)==0);
    assert(challenge[0]==2 && challenge[1]==2);for(unsigned i=0;i<32;i++)assert(challenge[2+i]==32+i);
    make_request(1,challenge,request,session);
    assert_hex(session,"32b321beb8e823f10801fe2dca0b06960e0bb4bc25c3671dfe07d2efb6451ccc",32);
    assert(board_auth_handle_request(request,50,response));assert(board_auth_is_authenticated() && board_auth_has_key());
    assert(response[0]==2 && response[1]==1 && response[2]==0);
    assert_hex(response+3,"b265f10b6f27da2f22f62382d67a3e7b7db3d4c9d9c1087d4c7bb075add0afc6",32);
    board_auth_get_challenge(second);assert(second[1]==1 && memcmp(second+2,challenge+2,32)==0);
    uint8_t command[52],inner[16];uint32_t sequence;
    make_command(session,1,command);
    assert_hex(command+20,"47769a48f7da2b455345bb77d5aeced911ae91aad6f9ca1cde95053c562f09c0",32);
    assert(board_auth_unwrap_command(command,52,inner,&sequence));assert(sequence==1 && inner[0]==1 && inner[1]==7);
    uint8_t reply_inner[8]={1,7,1,0,0,3,1,0},reply[44];
    assert(board_auth_wrap_reply(reply_inner,1,reply));assert(reply[0]==2 && reply[8]==1);
    assert_hex(reply+12,"a2a11a5e295d712e43cb4628a86b8645e820fc4fdfb85dc69f75e042ec5c7251",32);
    memcpy(reply,reply_inner,8);assert(board_auth_wrap_reply(reply,1,reply));
    assert_hex(reply+12,"a2a11a5e295d712e43cb4628a86b8645e820fc4fdfb85dc69f75e042ec5c7251",32);
    make_command(session,2,command);assert(board_auth_unwrap_command(command,52,inner,&sequence));
    // A pending action's signed reply keeps its own older sequence.
    assert(board_auth_wrap_reply(reply_inner,1,reply));assert(reply[8]==1);
    assert(!board_auth_wrap_reply(reply_inner,0,reply));assert(all_zero(reply,44));
    assert(!board_auth_wrap_reply(reply_inner,3,reply));
    assert(memcmp(private_configuration,private_canary,sizeof private_canary)==0 && writes==2);
}
static void replay_and_bad_mac_do_not_advance(void) {
    reset_store();uint8_t session[32],command[53],inner[16];uint32_t sequence;enroll(session);
    make_command(session,1,command);assert(board_auth_unwrap_command(command,52,inner,&sequence));
    assert(!board_auth_unwrap_command(command,52,inner,&sequence));assert(sequence==0 && all_zero(inner,16));
    make_command(session,100,command);command[51]^=1;assert(!board_auth_unwrap_command(command,52,inner,&sequence));
    make_command(session,2,command);assert(board_auth_unwrap_command(command,52,inner,&sequence));
    make_command(session,3,command);
    for(size_t length=0;length<52;length++)assert(!board_auth_unwrap_command(command,length,inner,&sequence));
    assert(!board_auth_unwrap_command(command,53,inner,&sequence));
    command[0]=1;independent_mac(session,"EiscueBLE/v2/cmd",command,20,command+20);
    assert(!board_auth_unwrap_command(command,52,inner,&sequence));
    make_command(session,0,command);assert(!board_auth_unwrap_command(command,52,inner,&sequence));
    make_command(session,1,command);assert(!board_auth_unwrap_command(command,52,inner,&sequence));
    make_command(session,UINT32_MAX,command);assert(board_auth_unwrap_command(command,52,inner,&sequence));
    make_command(session,3,command);assert(!board_auth_unwrap_command(command,52,inner,&sequence));
    board_auth_end_connection();make_command(session,UINT32_MAX,command);
    assert(!board_auth_unwrap_command(command,52,inner,&sequence));
    uint8_t reply[44],reply_inner[8]={1};assert(!board_auth_wrap_reply(reply_inner,1,reply));
}
static void one_auth_attempt_and_no_key_replacement(void) {
    reset_store();uint8_t session[32],challenge[34],request[50],reply[35];enroll(session);
    board_auth_get_challenge(challenge);make_request(1,challenge,request,session);request[18]^=1;
    assert(!board_auth_handle_request(request,50,reply));assert(all_zero(reply,35) && !board_auth_is_authenticated());
    uint8_t root[32];root_bytes(root);assert(memcmp(stored_key,root,32)==0 && writes==2);
    board_auth_begin_connection();board_auth_get_challenge(challenge);make_request(1,challenge,request,session);
    assert(!board_auth_handle_request(request,50,reply));assert(memcmp(stored_key,root,32)==0 && writes==2);
    make_request(2,challenge,request,session);assert(!board_auth_handle_request(request,50,reply));
    board_auth_begin_connection();board_auth_get_challenge(challenge);make_request(2,challenge,request,session);
    assert(board_auth_handle_request(request,50,reply));assert(board_auth_is_authenticated());
}
static void persisted_identity_and_fresh_connection_proofs(void) {
    reset_store();uint8_t session[32],challenge[34],request[50],reply[35];enroll(session);
    now=90000000;assert(board_auth_init()==ESP_OK);next_random=48;board_auth_begin_connection();
    board_auth_get_challenge(challenge);assert(challenge[1]==1);make_request(2,challenge,request,session);
    assert_hex(request+18,"874fadbd6da150c89a5b73eb32b44458e195acde1218d7c0901b307e9cda9e12",32);
    assert(board_auth_handle_request(request,50,reply));
    assert_hex(reply+3,"ac5635eb36ef08626577c576f294a63987ff3240eb9900f339a96306aab79e93",32);
    uint8_t old_challenge[34];memcpy(old_challenge,challenge,34);
    board_auth_end_connection();board_auth_begin_connection();board_auth_get_challenge(challenge);
    assert(memcmp(challenge+2,old_challenge+2,16)==0 && memcmp(challenge+18,old_challenge+18,16)!=0);
    assert(!board_auth_handle_request(request,50,reply));
    make_request(2,challenge,request,session);assert(!board_auth_handle_request(request,50,reply));
    board_auth_begin_connection();board_auth_get_challenge(challenge);make_request(2,challenge,request,session);
    assert(board_auth_handle_request(request,50,reply));assert(writes==2);
}
static void enrollment_deadline_and_invalid_auth(void) {
    reset_store();assert(board_auth_init()==ESP_OK);board_auth_begin_connection();
    uint8_t challenge[34],request[51],reply[35],session[32];
    now=59999999;board_auth_get_challenge(challenge);assert(challenge[1]==2);
    make_request(1,challenge,request,session);now=60000000;board_auth_get_challenge(challenge);assert(challenge[1]==0);
    assert(!board_auth_handle_request(request,50,reply));assert(!board_auth_has_key() && writes==1);
    board_auth_begin_connection();board_auth_get_challenge(challenge);assert(challenge[1]==0);
    assert(!board_auth_handle_request(request,50,reply));
    reset_store();assert(board_auth_init()==ESP_OK);
    for(size_t length=0;length<=51;length++) {
        if(length==50)continue;
        board_auth_begin_connection();board_auth_get_challenge(challenge);make_request(1,challenge,request,session);
        assert(!board_auth_handle_request(request,length,reply));assert(all_zero(reply,35));
        assert(!board_auth_handle_request(request,50,reply));
    }
    board_auth_begin_connection();board_auth_get_challenge(challenge);make_request(2,challenge,request,session);
    assert(!board_auth_handle_request(request,50,reply));
    board_auth_begin_connection();make_request(1,challenge,request,session);request[0]=1;
    assert(!board_auth_handle_request(request,50,reply));
    board_auth_begin_connection();make_request(3,challenge,request,session);
    assert(!board_auth_handle_request(request,50,reply));assert(writes==1);
}
static void corrupt_storage_and_uncertain_write_fail_closed(void) {
    reset_store();fail_open=true;assert(board_auth_init()==ESP_FAIL);
    board_auth_begin_connection();uint8_t challenge[34],request[50],reply[35],session[32];
    board_auth_get_challenge(challenge);assert(all_zero(challenge+1,33));
    reset_store();id_length=15;assert(board_auth_init()==ESP_ERR_INVALID_SIZE && writes==0);
    reset_store();id_length=16;key_length=31;assert(board_auth_init()==ESP_ERR_INVALID_SIZE && writes==0);
    reset_store();key_length=32;assert(board_auth_init()==ESP_ERR_INVALID_STATE && writes==0);
    reset_store();assert(board_auth_init()==ESP_OK);board_auth_begin_connection();board_auth_get_challenge(challenge);
    make_request(1,challenge,request,session);fail_commit=true;
    assert(!board_auth_handle_request(request,50,reply));assert(!board_auth_is_authenticated() && all_zero(reply,35));
    board_auth_begin_connection();assert(!board_auth_handle_request(request,50,reply));assert(writes==2);
    fail_commit=false;assert(board_auth_init()==ESP_OK && board_auth_has_key());
    board_auth_begin_connection();board_auth_get_challenge(challenge);make_request(2,challenge,request,session);
    assert(board_auth_handle_request(request,50,reply));assert(writes==2);
    board_auth_begin_connection();board_auth_get_challenge(challenge);make_request(2,challenge,request,session);fail_hmac=true;
    assert(!board_auth_handle_request(request,50,reply));assert(!board_auth_is_authenticated() && all_zero(reply,35));
    assert(memcmp(private_configuration,private_canary,sizeof private_canary)==0);
}
int main(void) {
    shared_vectors_and_pending_reply();replay_and_bad_mac_do_not_advance();
    one_auth_attempt_and_no_key_replacement();persisted_identity_and_fresh_connection_proofs();
    enrollment_deadline_and_invalid_auth();corrupt_storage_and_uncertain_write_fail_closed();
    puts("Board auth: 6 scenario groups passed (shared HMAC vectors, replay, persistence, enrollment, fail-closed storage)");
}
