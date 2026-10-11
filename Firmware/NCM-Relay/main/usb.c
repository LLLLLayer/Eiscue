/* SPDX-License-Identifier: GPL-3.0-or-later
 * Descriptor/lifecycle adapted from this repository's firmware-device baseline. */
#include "usb.h"
#include "tinyusb.h"
#include "tinyusb_default_config.h"
#include "tusb.h"
#include <stdatomic.h>
#if CFG_TUD_HID || CFG_TUD_CDC || CFG_TUD_MSC
#error "NCM developer experiment must not expose HID/CDC/MSC"
#endif
static const tusb_desc_device_t device={
    .bLength=sizeof(tusb_desc_device_t),.bDescriptorType=TUSB_DESC_DEVICE,.bcdUSB=0x0200,
    .bDeviceClass=TUSB_CLASS_MISC,.bDeviceSubClass=MISC_SUBCLASS_COMMON,.bDeviceProtocol=MISC_PROTOCOL_IAD,
    .bMaxPacketSize0=64,.idVendor=0x303a,.idProduct=0x4002,.bcdDevice=0x0100,
    .iManufacturer=1,.iProduct=2,.bNumConfigurations=1
};
static const uint8_t configuration[]={
    TUD_CONFIG_DESCRIPTOR(1,2,0,TUD_CONFIG_DESC_LEN+TUD_CDC_NCM_DESC_LEN,0,100),
    TUD_CDC_NCM_DESCRIPTOR(0,3,4,0x81,64,0x02,0x82,64,1514)
};
static const char *strings[]={(const char[]){0x09,0x04},"Eiscue development","Eiscue NCM Relay","USB Ethernet","020000000002"};
static atomic_uint epoch;
static atomic_bool online;
static void event(tinyusb_event_t *e,void *unused) {
    (void)unused; atomic_fetch_add(&epoch,1); atomic_store(&online,e->id==TINYUSB_EVENT_ATTACHED || e->id==TINYUSB_EVENT_RESUMED);
}
void nd_usb_install(void) {
    tinyusb_config_t config=TINYUSB_DEFAULT_CONFIG();
    config.descriptor.device=&device; config.descriptor.full_speed_config=configuration;
    config.descriptor.string=strings; config.descriptor.string_count=sizeof strings/sizeof strings[0];
    config.phy.self_powered=false; config.event_cb=event;
    ESP_ERROR_CHECK(tinyusb_driver_install(&config));
}
bool nd_usb_online(void) { return atomic_load(&online); }
uint32_t nd_usb_epoch(void) { return atomic_load(&epoch); }
