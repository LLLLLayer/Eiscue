/* SPDX-License-Identifier: GPL-3.0-or-later
 * XPC wire schema: pymobiledevice3 remote/xpc_message.py at
 * cd895d17ce8a97d883c10f87b26c7356d5e0ccb1. */
#include "bridge_screenshot_stream.h"
#include <string.h>
#define MAX_DEPTH 16u
#define MAX_ITEMS 4096u
#define MAX_KEY 255u
#define TRY(expr) do { bridge_status st_ = (expr); if (st_ != BRIDGE_OK) return st_; } while (0)
typedef enum { OTHER, ROOT, OUTPUT, IMAGE, IMAGE_FORMAT } path;
typedef struct {
    bridge_io *io; uint8_t *scratch; size_t cap; bridge_sink_fn sink; void *sink_ctx;
    uint64_t deadline, consumed, total; uint32_t items;
    bool output_seen, image_seen, format_seen, error_seen;
    bridge_png_info result; char key_buffer[MAX_KEY+1];
} reader;
static uint32_t le32(const uint8_t *p) { return (uint32_t)p[0] | (uint32_t)p[1]<<8 | (uint32_t)p[2]<<16 | (uint32_t)p[3]<<24; }
static uint32_t be32(const uint8_t *p) { return (uint32_t)p[0]<<24 | (uint32_t)p[1]<<16 | (uint32_t)p[2]<<8 | p[3]; }
static uint64_t le64(const uint8_t *p) { return (uint64_t)le32(p) | (uint64_t)le32(p+4)<<32; }
static bridge_status read_bytes(reader *r, uint8_t *p, size_t n, uint64_t end) {
    if (r->consumed > end || n > end - r->consumed) return BRIDGE_E_FORMAT;
    TRY(bridge_read_exact(r->io, p, n, r->deadline)); r->consumed += n; return BRIDGE_OK;
}
static bridge_status u32(reader *r, uint32_t *v, uint64_t end) {
    uint8_t b[4]; TRY(read_bytes(r,b,4,end)); *v=le32(b); return BRIDGE_OK;
}
static bridge_status skip(reader *r, uint64_t n, uint64_t end) {
    while(n) { size_t part = n < r->cap ? (size_t)n : r->cap; TRY(read_bytes(r,r->scratch,part,end)); n-=part; }
    return BRIDGE_OK;
}
static bridge_status padding(reader *r, uint32_t n, uint64_t end) {
    uint8_t b[3]; size_t pad=(4u-(n&3u))&3u;
    TRY(read_bytes(r,b,pad,end));
    for(size_t i=0;i<pad;i++) if(b[i]) return BRIDGE_E_FORMAT;
    return BRIDGE_OK;
}
static bridge_status key(reader *r, char *out, uint64_t end) {
    for(uint32_t i=0;i<=MAX_KEY;i++) {
        uint8_t b; TRY(read_bytes(r,&b,1,end)); out[i]=(char)b;
        if(!b) return padding(r,i+1,end);
    }
    return BRIDGE_E_LIMIT;
}
static bridge_status emit(reader *r, const uint8_t *p, size_t n) {
    TRY(r->sink(r->sink_ctx,p,n));
    return r->io->clock_ms(r->io->context) >= r->deadline ? BRIDGE_E_TIMEOUT : BRIDGE_OK;
}
static bridge_status png(reader *r, uint32_t size, uint64_t end) {
    if(r->image_seen) return BRIDGE_E_FORMAT;
    if(size < 33) return BRIDGE_E_FORMAT;
    uint8_t header[24]; TRY(read_bytes(r,header,sizeof header,end));
    static const uint8_t signature[8]={137,80,78,71,13,10,26,10};
    if(memcmp(header,signature,8) || be32(header+8)!=13 || memcmp(header+12,"IHDR",4)) return BRIDGE_E_FORMAT;
    uint32_t w=be32(header+16),h=be32(header+20);
    if(!w || !h || w>32768 || h>32768) return BRIDGE_E_LIMIT;
    TRY(emit(r,header,sizeof header));
    uint32_t left=size-(uint32_t)sizeof header;
    while(left) { size_t n=left<r->cap ? left:r->cap; TRY(read_bytes(r,r->scratch,n,end)); TRY(emit(r,r->scratch,n)); left-=(uint32_t)n; }
    r->image_seen=true; r->result.image_bytes=size; r->result.width=w; r->result.height=h;
    return BRIDGE_OK;
}
static bridge_status object(reader *r, uint64_t end, unsigned depth, path current) {
    if(depth>MAX_DEPTH || ++r->items>MAX_ITEMS) return BRIDGE_E_LIMIT;
    uint32_t type; TRY(u32(r,&type,end));
    if((current==ROOT || current==OUTPUT) && type!=0xf000) return BRIDGE_E_TYPE;
    if(current==IMAGE && type!=0x8000) return BRIDGE_E_TYPE;
    if(current==IMAGE_FORMAT && type!=0x9000) return BRIDGE_E_TYPE;
    switch(type) {
    case 0x1000: return BRIDGE_OK;
    case 0x2000: { uint32_t v; TRY(u32(r,&v,end)); return v<=1 ? BRIDGE_OK:BRIDGE_E_FORMAT; }
    case 0x3000: case 0x4000: case 0x5000: case 0x7000: return skip(r,8,end);
    case 0xa000: return skip(r,16,end);
    case 0x8000: case 0x9000: {
        uint32_t n; TRY(u32(r,&n,end));
        if(n>end-r->consumed) return BRIDGE_E_FORMAT;
        if(type==0x8000) {
            if(current==IMAGE) TRY(png(r,n,end)); else TRY(skip(r,n,end));
        } else {
            if(!n) return BRIDGE_E_FORMAT;
            if(current==IMAGE_FORMAT) {
                uint8_t value[4];
                if(r->format_seen || n!=4) return BRIDGE_E_FORMAT;
                TRY(read_bytes(r,value,4,end));
                if(memcmp(value,"png\0",4)) return BRIDGE_E_FORMAT;
                r->format_seen=true;
            } else {
                TRY(skip(r,n-1,end)); uint8_t zero;
                TRY(read_bytes(r,&zero,1,end)); if(zero) return BRIDGE_E_FORMAT;
            }
        }
        return padding(r,n,end);
    }
    case 0xe000: case 0xf000: {
        uint32_t n,count; TRY(u32(r,&n,end));
        if(n<4 || n>end-r->consumed) return BRIDGE_E_FORMAT;
        uint64_t next=r->consumed+n; TRY(u32(r,&count,next));
        if(count>MAX_ITEMS-r->items) return BRIDGE_E_LIMIT;
        for(uint32_t i=0;i<count;i++) {
            path child=OTHER;
            if(type==0xf000) {
                char *k=r->key_buffer; TRY(key(r,k,next));
                if(current==ROOT && !strcmp(k,"CoreDevice.output")) {
                    if(r->output_seen) return BRIDGE_E_FORMAT;
                    r->output_seen=true; child=OUTPUT;
                } else if(current==ROOT && !strcmp(k,"CoreDevice.error")) r->error_seen=true;
                else if(current==OUTPUT && !strcmp(k,"image")) child=IMAGE;
                else if(current==OUTPUT && !strcmp(k,"imageFormat")) child=IMAGE_FORMAT;
            }
            TRY(object(r,next,depth+1,child));
        }
        return r->consumed==next ? BRIDGE_OK:BRIDGE_E_FORMAT;
    }
    default: return BRIDGE_E_UNSUPPORTED;
    }
}
bridge_status bridge_xpc_extract_png(bridge_io *io, uint32_t max, uint8_t *scratch,
    size_t cap, bridge_sink_fn sink, void *ctx, uint64_t deadline, bridge_png_info *info) {
    if(!io || !io->read || !io->clock_ms || !scratch || cap<32 || !sink || !info || max<36) return BRIDGE_E_ARGUMENT;
    memset(info,0,sizeof *info);
    uint8_t h[24]; TRY(bridge_read_exact(io,h,sizeof h,deadline));
    if(le32(h)!=0x29b00b92) return BRIDGE_E_FORMAT;
    uint64_t payload=le64(h+8);
    if(payload>max-24u) return BRIDGE_E_LIMIT;
    if(payload<12) return BRIDGE_E_FORMAT;
    reader r={.io=io,.scratch=scratch,.cap=cap,.sink=sink,.sink_ctx=ctx,.deadline=deadline,.total=payload};
    r.result.message_id=le64(h+16);
    uint8_t prefix[8]; TRY(read_bytes(&r,prefix,8,payload));
    if(le32(prefix)!=0x42133742 || le32(prefix+4)!=5) return BRIDGE_E_FORMAT;
    TRY(object(&r,payload,0,ROOT));
    if(r.consumed!=payload) return BRIDGE_E_FORMAT;
    if(r.error_seen) return BRIDGE_E_FORMAT;
    if(!r.output_seen || !r.image_seen) return BRIDGE_E_NOT_FOUND;
    if(io->clock_ms(io->context)>=deadline) return BRIDGE_E_TIMEOUT;
    *info=r.result; return BRIDGE_OK;
}
