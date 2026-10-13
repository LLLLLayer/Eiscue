// SPDX-License-Identifier: Apache-2.0
#include "companion.h"
#include "companion_assets.h"
#include "companion_text.h"
#include "hid_peripheral.h"
#include "driver/gpio.h"
#include "driver/spi_master.h"
#include "esp_adc/adc_oneshot.h"
#include "esp_adc/adc_cali.h"
#include "esp_adc/adc_cali_scheme.h"
#include "esp_lcd_panel_io.h"
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_panel_vendor.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include <string.h>

#define LCD_WIDTH 240
#define LCD_HEIGHT 320
#define STRIP_HEIGHT 8
static const char *TAG="eiscue_companion";
static companion_stop stop_state;
static portMUX_TYPE state_lock=portMUX_INITIALIZER_UNLOCKED;
static struct { bool connected,secure; companion_status status; uint64_t updated_at; } state;
static esp_lcd_panel_handle_t panel;
static SemaphoreHandle_t transfer_done;
static uint16_t *strip;
static bool display_failed;

static uint64_t now_ms(void) {return (uint64_t)esp_timer_get_time()/1000;}
bool companion_input_stopped(void) {return companion_stop_is_latched(&stop_state);}
bool companion_accepts_command(uint8_t opcode) {return companion_command_allowed(&stop_state,opcode);}
void companion_read_stop(uint8_t bytes[COMPANION_STOP_SIZE]) {companion_stop_bytes(&stop_state,bytes);}
void companion_host_unlock(void) {companion_stop_unlock(&stop_state);}
void companion_connection_changed(bool connected,bool secure) {
    taskENTER_CRITICAL(&state_lock);
    if(state.connected!=connected || state.secure!=secure)state.updated_at=0;
    state.connected=connected;state.secure=secure;
    taskEXIT_CRITICAL(&state_lock);
}
bool companion_update_status(const uint8_t *bytes,size_t length) {
    companion_status value;
    if(!companion_parse_status(bytes,length,&value))return false;
    taskENTER_CRITICAL(&state_lock);
    state.status=value;state.updated_at=now_ms();
    taskEXIT_CRITICAL(&state_lock);
    return true;
}
static bool transfer_complete(esp_lcd_panel_io_handle_t io,esp_lcd_panel_io_event_data_t *event,void *context) {
    (void)io;(void)event;(void)context;
    BaseType_t wake=pdFALSE;xSemaphoreGiveFromISR(transfer_done,&wake);return wake==pdTRUE;
}
static bool draw_strip(int x,int y,int width,int height) {
    if(display_failed)return false;
    esp_err_t result=esp_lcd_panel_draw_bitmap(panel,x,y,x+width,y+height,strip);
    if(result!=ESP_OK || xSemaphoreTake(transfer_done,pdMS_TO_TICKS(500))!=pdTRUE) {
        // Never reuse a DMA buffer after a timed-out transfer; stop rendering.
        display_failed=true;gpio_set_level(21,0);
        ESP_LOGW(TAG,"display transfer stopped code=%ld",(long)result);return false;
    }
    return true;
}
static void clear_area(int y,int height) {
    if(display_failed)return;
    // Matches the baked assets; bytes are big-endian RGB565 for ST7789.
    const uint16_t background=(uint16_t)((COMPANION_BACKGROUND_RGB565>>8)|(COMPANION_BACKGROUND_RGB565<<8));
    for(int i=0;i<LCD_WIDTH*STRIP_HEIGHT;i++)strip[i]=background;
    for(int row=y;row<y+height;row+=STRIP_HEIGHT) {
        int rows=y+height-row;if(rows>STRIP_HEIGHT)rows=STRIP_HEIGHT;
        if(!draw_strip(0,row,LCD_WIDTH,rows))return;
        taskYIELD();
    }
}
static void draw_bitmap(const companion_bitmap *bitmap,int y) {
    if(display_failed || !bitmap || bitmap->width>LCD_WIDTH || y+bitmap->height>LCD_HEIGHT)return;
    for(unsigned row=0;row<bitmap->height;row+=STRIP_HEIGHT) {
        unsigned rows=bitmap->height-row;if(rows>STRIP_HEIGHT)rows=STRIP_HEIGHT;
        for(unsigned i=0;i<rows;i++)
            if(!companion_bitmap_decode_row(bitmap,row+i,strip+i*bitmap->width,LCD_WIDTH))return;
        if(!draw_strip((LCD_WIDTH-bitmap->width)/2,y,bitmap->width,rows))return;
        y+=(int)rows;taskYIELD();
    }
}
static void draw_number(uint16_t value,int y) {
    if(display_failed)return;
    uint8_t digits[5];unsigned count=0;
    do{digits[count++]=value%10;value/=10;}while(value && count<5);
    unsigned width=count*14;
    for(unsigned row=0;row<20;row++) {
        for(unsigned i=0;i<count;i++) {
            const companion_bitmap *glyph=companion_text_get(COMPANION_TEXT_DIGIT_ZERO+digits[count-1-i],0);
            if(!companion_bitmap_decode_row(glyph,row,strip+i*14,14))return;
        }
        if(!draw_strip((LCD_WIDTH-width)/2,y+row,width,1))return;
    }
}
static bool display_init(void) {
    transfer_done=xSemaphoreCreateBinary();
    strip=heap_caps_malloc(LCD_WIDTH*STRIP_HEIGHT*sizeof *strip,MALLOC_CAP_DMA|MALLOC_CAP_INTERNAL);
    if(!transfer_done || !strip)return false;
    gpio_config_t backlight={.pin_bit_mask=1ULL<<21,.mode=GPIO_MODE_OUTPUT};
    if(gpio_config(&backlight)!=ESP_OK)return false;
    gpio_set_level(21,0);
    spi_bus_config_t bus={.mosi_io_num=9,.miso_io_num=-1,.sclk_io_num=8,
        .quadwp_io_num=-1,.quadhd_io_num=-1,.max_transfer_sz=LCD_WIDTH*STRIP_HEIGHT*2};
    if(spi_bus_initialize(SPI2_HOST,&bus,SPI_DMA_CH_AUTO)!=ESP_OK)return false;
    esp_lcd_panel_io_handle_t io;
    esp_lcd_panel_io_spi_config_t config={.dc_gpio_num=20,.cs_gpio_num=1,.pclk_hz=20000000,
        .lcd_cmd_bits=8,.lcd_param_bits=8,.spi_mode=0,.trans_queue_depth=1,
        .on_color_trans_done=transfer_complete};
    if(esp_lcd_new_panel_io_spi((esp_lcd_spi_bus_handle_t)SPI2_HOST,&config,&io)!=ESP_OK)return false;
    esp_lcd_panel_dev_config_t device={.reset_gpio_num=-1,.rgb_ele_order=LCD_RGB_ELEMENT_ORDER_RGB,.bits_per_pixel=16};
    if(esp_lcd_new_panel_st7789(io,&device,&panel)!=ESP_OK || esp_lcd_panel_reset(panel)!=ESP_OK ||
        esp_lcd_panel_init(panel)!=ESP_OK || esp_lcd_panel_invert_color(panel,true)!=ESP_OK)return false;
    clear_area(0,LCD_HEIGHT);
    if(display_failed || esp_lcd_panel_disp_on_off(panel,true)!=ESP_OK)return false;
    gpio_set_level(21,1);return true;
}
static void display_task(void *context) {
    (void)context;
    if(!display_init()){ESP_LOGW(TAG,"display unavailable");vTaskDelete(NULL);return;}
    uint8_t old_phase=255,old_language=255;uint16_t old_count=UINT16_MAX;
    for(;;) {
        taskENTER_CRITICAL(&state_lock);
        companion_status status=state.status;bool connected=state.connected,secure=state.secure;
        uint64_t updated_at=state.updated_at;
        taskEXIT_CRITICAL(&state_lock);
        uint8_t phase=companion_visible_phase(connected,secure,companion_input_stopped(),now_ms(),updated_at,&status);
        if(phase!=old_phase || status.language!=old_language || status.completed_actions!=old_count) {
            unsigned emotion=phase==COMPANION_COMPLETED?3:phase==COMPANION_STOPPED || phase==COMPANION_FAILED?4:
                phase==COMPANION_THINKING || phase==COMPANION_WAITING?1:
                phase==COMPANION_ACTING || phase==COMPANION_OBSERVING?2:0;
            clear_area(0,LCD_HEIGHT);
            draw_bitmap(companion_asset_get(emotion),12);
            draw_bitmap(companion_text_get(phase,status.language),181);
            if(connected && secure && phase>=COMPANION_THINKING && phase<=COMPANION_STOPPED) {
                draw_bitmap(companion_text_get(15,status.language),232);
                draw_number(status.completed_actions,257);
            }
            draw_bitmap(companion_text_get(companion_input_stopped()?14:13,status.language),290);
            old_phase=phase;old_language=status.language;old_count=status.completed_actions;
        }
        if(display_failed){vTaskDelete(NULL);return;}
        vTaskDelay(pdMS_TO_TICKS(200));
    }
}
static void button_task(void *context) {
    (void)context;
    adc_oneshot_unit_handle_t adc;adc_cali_handle_t calibration;
    adc_oneshot_unit_init_cfg_t unit={.unit_id=ADC_UNIT_1};
    adc_oneshot_chan_cfg_t channel={.bitwidth=ADC_BITWIDTH_12,.atten=ADC_ATTEN_DB_12};
    adc_cali_curve_fitting_config_t curve={.unit_id=ADC_UNIT_1,.chan=ADC_CHANNEL_0,
        .atten=ADC_ATTEN_DB_12,.bitwidth=ADC_BITWIDTH_12};
    if(adc_oneshot_new_unit(&unit,&adc)!=ESP_OK || adc_oneshot_config_channel(adc,ADC_CHANNEL_0,&channel)!=ESP_OK ||
        adc_cali_create_scheme_curve_fitting(&curve,&calibration)!=ESP_OK) {
        // A board claiming a stop key must fail closed if it cannot read it.
        companion_stop_latch(&stop_state);eiscue_ble_companion_stop(false);
        ESP_LOGE(TAG,"stop key unavailable; input blocked");vTaskDelete(NULL);return;
    }
    companion_button button={0};
    for(;;) {
        int raw=0,millivolts=0;
        if(adc_oneshot_read(adc,ADC_CHANNEL_0,&raw)!=ESP_OK || adc_cali_raw_to_voltage(calibration,raw,&millivolts)!=ESP_OK) {
            if(companion_stop_latch(&stop_state))eiscue_ble_companion_stop(false);
        } else {
            bool ok=millivolts>=447 && millivolts<1900;
            enum companion_button_event event=companion_button_sample(&button,ok,companion_input_stopped(),now_ms());
            if(event==COMPANION_BUTTON_STOP && companion_stop_latch(&stop_state))eiscue_ble_companion_stop(false);
            else if(event==COMPANION_BUTTON_UNLOCK)eiscue_ble_companion_stop(true);
        }
        vTaskDelay(pdMS_TO_TICKS(20));
    }
}
void companion_init(void) {
    // Input sampling cannot wait for a slow LCD transfer or rendering allocation.
    if(xTaskCreate(button_task,"companion_keys",3072,NULL,5,NULL)!=pdPASS) {
        companion_stop_latch(&stop_state);eiscue_ble_companion_stop(false);
    }
    if(xTaskCreate(display_task,"companion_lcd",3072,NULL,1,NULL)!=pdPASS)
        ESP_LOGW(TAG,"display task unavailable");
}
