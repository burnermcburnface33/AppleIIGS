// iOS driver for KEGS Apple //GS emulator core.
// Implements all x_* functions KEGS expects from the host platform.
//
// NOTE: most x_* prototypes are declared in protos.h with C++ linkage, so the
// definitions here are also C++ linkage. Only the few functions called from
// Swift/Obj-C are marked extern "C".

#include "defc.h"
#include "driver.h"
#include "sim65816.h"
#include "video.h"
#include "moremem.h"
#include "paddles.h"
#include "config.h"
#include "iwm.h"
#include "sound.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/time.h>
#include <pthread.h>

#include <CoreFoundation/CoreFoundation.h>

// g_dummy_memory1_ptr is declared inside a method in sim65816.h; pull it out.
extern byte *g_dummy_memory1_ptr;

// ----------------------------------------------------------------------------
// Joystick state (read by joystick_update() below)
extern "C" {
    float joyX = 0.f, joyY = 0.f;
    int   oaButton = 0, caButton = 0;
    void  ios_bridge_notify_disk_light(int motorOn, int slot, int drive, int track);
}

// ----------------------------------------------------------------------------
// External framebuffer
static uint8_t *gExternalFrameBuf = NULL;
static int      gFrameW = 0, gFrameH = 0, gFrameStride = 0;

extern "C" void ios_video_set_external_buffer(uint8_t *buf, int w, int h, int stride) {
    gExternalFrameBuf = buf;
    gFrameW = w;
    gFrameH = h;
    gFrameStride = stride;
}

// ----------------------------------------------------------------------------
// Bundle / Documents path helpers. Look in the root, then in ROMs/ subdir.
static const char *bundle_resource_path(const char *name, char *out, size_t outsize) {
    CFBundleRef bundle = CFBundleGetMainBundle();
    if (!bundle) return NULL;

    CFStringRef nameStr = CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8);
    CFURLRef url = CFBundleCopyResourceURL(bundle, nameStr, NULL, NULL);
    if (!url) {
        CFStringRef sub = CFSTR("ROMs");
        url = CFBundleCopyResourceURL(bundle, nameStr, NULL, sub);
    }
    CFRelease(nameStr);
    if (!url) return NULL;

    CFStringRef path = CFURLCopyFileSystemPath(url, kCFURLPOSIXPathStyle);
    CFRelease(url);
    if (!path) return NULL;

    CFStringGetCString(path, out, (CFIndex)outsize, kCFStringEncodingUTF8);
    CFRelease(path);
    return out;
}

// ----------------------------------------------------------------------------
// ROM loader
static int load_rom_file(const char *path, byte *dest, size_t maxbytes, size_t *actualOut) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || (size_t)sz > maxbytes) { fclose(f); return -2; }
    size_t got = fread(dest, 1, (size_t)sz, f);
    fclose(f);
    if (actualOut) *actualOut = got;
    return (got == (size_t)sz) ? 0 : -3;
}

extern "C" void ios_load_roms(void) {
    extern byte *g_rom_fc_ff_ptr;

    g_sim65816.g_mem_size_base = 256 * 1024;
    memset(&g_rom_fc_ff_ptr[0], 0, 2 * 65536);

    char path[1024];

    if (bundle_resource_path("gs-rom03.bin", path, sizeof(path))) {
        size_t actual = 0;
        if (load_rom_file(path, &g_rom_fc_ff_ptr[0], 256 * 1024, &actual) == 0 && actual == 256 * 1024) {
            g_sim65816.g_rom_version = 3;
            printf("Loaded ROM03 (256KB) from %s\n", path);
            return;
        }
    }
    if (bundle_resource_path("gs-rom01.bin", path, sizeof(path))) {
        size_t actual = 0;
        if (load_rom_file(path, &g_rom_fc_ff_ptr[2 * 65536], 128 * 1024, &actual) == 0 && actual == 128 * 1024) {
            g_sim65816.g_rom_version = 1;
            printf("Loaded ROM01 (128KB) from %s\n", path);
            return;
        }
    }

    fprintf(stderr, "FATAL: no Apple //GS ROM found in bundle.\n");
    g_sim65816.g_rom_version = 1;
}

// ----------------------------------------------------------------------------
// x_* functions (C++ linkage to match protos.h)

void x_check_system_input_events(void) {}
int  x_show_alert(int, const char *str) { if (str) fprintf(stderr, "KEGS alert: %s\n", str); return 0; }
void x_fatal_exit(const char *str) { if (str) fprintf(stderr, "KEGS fatal: %s\n", str); }
int  win_nonblock_read_stdin(int, char *, int) { return 0; }
void x_dialog_create_kegs_conf(const char *) {}
void x_update_physical_colormap(void) {}
void x_show_color_array(void) {}
void x_auto_repeat_on(int) {}
void x_update_color(int, int, int, int, word32) {}
void x_redraw_status_lines(void) {}
void x_hide_pointer(int) {}
void x_full_screen(int) {}
void x_update_info(const char *) {}
int  x_calc_ratio(float &rx, float &ry) { rx = 1.f; ry = 1.f; return 0; }
void x_release_kimage(Kimage *kim) {
    if (kim && kim->data_ptr) { free(kim->data_ptr); kim->data_ptr = NULL; }
    if (kim) kim->dev_handle = NULL;
}
void x_video_shut(void) {}

extern void video_get_kimages(void);

void x_video_init(void) {
    // We pick 32bpp (RGBA8) for the main screen and 8bpp for text/hires (KEGS native).
    s_video.g_screen_depth = 32;
    s_video.g_screen_mdepth = 32;
    s_video.g_red_mask    = 0xFF;
    s_video.g_green_mask  = 0xFF;
    s_video.g_blue_mask   = 0xFF;
    s_video.g_red_left_shift   = 16;
    s_video.g_green_left_shift = 8;
    s_video.g_blue_left_shift  = 0;
    s_video.g_red_right_shift   = 0;
    s_video.g_green_right_shift = 0;
    s_video.g_blue_right_shift  = 0;

    // Allocate the main offscreen Kimage (where pushed pixels go)
    g_kimage_offscreen.width_req = X_A2_WINDOW_WIDTH;
    g_kimage_offscreen.width_act = X_A2_WINDOW_WIDTH;
    g_kimage_offscreen.height    = X_A2_WINDOW_HEIGHT;
    g_kimage_offscreen.depth     = 32;
    g_kimage_offscreen.mdepth    = 32;
    x_get_kimage(&g_kimage_offscreen);

    // Main-window Kimage - used as intermediate when converting from 8bpp
    s_video.g_mainwin_kimage.width_req = X_A2_WINDOW_WIDTH;
    s_video.g_mainwin_kimage.height    = X_A2_WINDOW_HEIGHT;
    s_video.g_mainwin_kimage.depth     = 32;
    s_video.g_mainwin_kimage.mdepth    = 32;
    x_get_kimage(&s_video.g_mainwin_kimage);

    // Allocate per-mode Kimages
    s_video.g_kimage_text[0].width_req = A2_WINDOW_WIDTH;
    s_video.g_kimage_text[0].height    = A2_WINDOW_HEIGHT;
    s_video.g_kimage_text[1].width_req = A2_WINDOW_WIDTH;
    s_video.g_kimage_text[1].height    = A2_WINDOW_HEIGHT;
    s_video.g_kimage_hires[0].width_req = A2_WINDOW_WIDTH;
    s_video.g_kimage_hires[0].height    = A2_WINDOW_HEIGHT;
    s_video.g_kimage_hires[1].width_req = A2_WINDOW_WIDTH;
    s_video.g_kimage_hires[1].height    = A2_WINDOW_HEIGHT;
    s_video.g_kimage_superhires.width_req = A2_WINDOW_WIDTH;
    s_video.g_kimage_superhires.height    = A2_WINDOW_HEIGHT;
    s_video.g_kimage_border_special.width_req = X_A2_WINDOW_WIDTH;
    s_video.g_kimage_border_special.height    = X_A2_WINDOW_HEIGHT;
    s_video.g_kimage_border_special2.width_req = X_A2_WINDOW_WIDTH;
    s_video.g_kimage_border_special2.height    = X_A2_WINDOW_HEIGHT;
    s_video.g_kimage_border_sides.width_req = X_A2_WINDOW_WIDTH;
    s_video.g_kimage_border_sides.height    = X_A2_WINDOW_HEIGHT;
    video_get_kimages();
}

void x_push_done(void) {}
void x_invalidrect(void) {}

void x_get_kimage(Kimage *kim) {
    if (!kim) return;
    int depth = kim->mdepth ? kim->mdepth : 32;
    int bpp = depth / 8;
    if (bpp < 1) bpp = 4;
    kim->width_act = kim->width_req;
    kim->depth = depth;
    kim->mdepth = depth;
    int sz = kim->width_act * kim->height * bpp;
    kim->data_ptr = (byte *)calloc(1, (size_t)sz);
    kim->data_size = sz;
    kim->dev_handle = NULL;
}

void x_push_kimage(Kimage *kim, int destx, int desty,
                   int srcx, int srcy, int width, int height) {
    if (!kim || !kim->data_ptr || !gExternalFrameBuf) return;

    int src_bpp = (kim->mdepth ? kim->mdepth : kim->depth) / 8;
    if (src_bpp == 0) src_bpp = 4;
    int src_stride = kim->width_act * src_bpp;
    int dst_stride = gFrameStride;

    if (destx < 0) { srcx -= destx; width += destx; destx = 0; }
    if (desty < 0) { srcy -= desty; height += desty; desty = 0; }
    if (destx + width  > gFrameW) width  = gFrameW - destx;
    if (desty + height > gFrameH) height = gFrameH - desty;
    if (width <= 0 || height <= 0) return;

    for (int y = 0; y < height; y++) {
        const uint8_t *src = kim->data_ptr + (srcy + y) * src_stride + srcx * src_bpp;
        uint8_t *dst = gExternalFrameBuf + (desty + y) * dst_stride + destx * 4;

        if (src_bpp == 4) {
            for (int x = 0; x < width; x++) {
                uint8_t b = src[0], g = src[1], r = src[2];
                dst[0] = r; dst[1] = g; dst[2] = b; dst[3] = 0xFF;
                src += 4; dst += 4;
            }
        } else if (src_bpp == 2) {
            for (int x = 0; x < width; x++) {
                uint16_t p = (uint16_t)src[0] | ((uint16_t)src[1] << 8);
                dst[0] = (uint8_t)(((p >> 11) & 0x1F) * 255 / 31);
                dst[1] = (uint8_t)(((p >>  5) & 0x3F) * 255 / 63);
                dst[2] = (uint8_t)(( p        & 0x1F) * 255 / 31);
                dst[3] = 0xFF;
                src += 2; dst += 4;
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Joystick
void joystick_init(void) {
    g_joystick_native_type1 = 0;
    g_joystick_native_type2 = -1;
    g_joystick_native_type = JOYSTICK_TYPE_NATIVE_1;
}

void joystick_update(double dcycs) {
    paddle_update_trigger_dcycs(dcycs);
    float x = joyX, y = joyY;
    if (x > 1.f) x = 1.f; else if (x < -1.f) x = -1.f;
    if (y > 1.f) y = 1.f; else if (y < -1.f) y = -1.f;
    g_paddles.g_paddle_val[0] = (int)(32767 * x);
    g_paddles.g_paddle_val[1] = (int)(32767 * y);
    g_paddles.g_paddle_val[2] = 32767;
    g_paddles.g_paddle_val[3] = 32767;
}

void joystick_update_buttons(void) {
    g_moremem.g_paddle_buttons = (oaButton & 1) | ((caButton & 1) << 1);
}

void joystick_shut(void) {}

// ----------------------------------------------------------------------------
// Disk light callback
void x_set_light(int motorOn, int slot, int drive, int track) {
    ios_bridge_notify_disk_light(motorOn, slot, drive, track);
}

// ----------------------------------------------------------------------------
// WAV / disk sound stubs (we excluded the openal driver)
bool x_load_wav(const char *, unsigned char **, unsigned int &, OASound &) { return false; }
OASound async_init_wav(const char *) { OASound s; memset(&s, 0, sizeof(s)); return s; }
int async_release_wav(OASound *) { return 0; }
int async_stop_wav(OASound *) { return 0; }
int async_play_wav(OASound *, int, float, float) { return 0; }
void x_preload_sounds(void) {}

// play_sound and g_system_sounds are defined in sound.cpp; don't redefine.

// ----------------------------------------------------------------------------
// Marinetti (TCP/IP) - we excluded marinetti.cpp from the build
void marinetti_init(void) {}
void marinetti_shutdown(void) {}
void marinetti_run(double) {}
int  marinetti_pre_load_state(void) { return 0; }
int  marinetti_post_load_state(void) { return 0; }

// SCC socket driver - stubbed out (sig from protos.h)
void scc_socket_init(int /*port*/) {}
void scc_socket_change_params(int /*port*/) {}
void scc_socket_fill_readbuf(int /*port*/, int /*space_left*/, double /*dcycs*/) {}
void scc_socket_empty_writebuf(int /*port*/, double /*dcycs*/) {}
void scc_accept_socket(int /*port*/, double /*dcycs*/) {}
void scc_socket_open_outgoing(int /*port*/, double /*dcycs*/) {}
void scc_socket_make_nonblock(int /*port*/, double /*dcycs*/) {}
void scc_socket_close(int /*port*/, int /*full_close*/, double /*dcycs*/) {}
void scc_socket_recvd_char(int /*port*/, int /*c*/, double /*dcycs*/) {}
void scc_socket_modem_write(int /*port*/, int /*c*/, double /*dcycs*/) {}
void scc_socket_telnet_reqs(int /*port*/, double /*dcycs*/) {}
void scc_socket_do_cmd_str(int /*port*/, double /*dcycs*/) {}
void scc_socket_send_modem_code(int /*port*/, int /*code*/, double /*dcycs*/) {}
void scc_socket_modem_hangup(int /*port*/, double /*dcycs*/) {}
void scc_socket_modem_connect(int /*port*/, double /*dcycs*/) {}
void scc_socket_modem_do_ring(int /*port*/, double /*dcycs*/) {}
void scc_socket_do_answer(int /*port*/, double /*dcycs*/) {}
void scc_socket_maybe_open_incoming(int /*port*/, double /*dcycs*/) {}

// Sound init/shutdown bridge
void x_async_sound_init(void)                      {}
void x_async_snd_shutdown(void)                    {}
void x_snd_child_init(void)                        {}
word32 *x_sound_allocate(int size) { return (word32 *)calloc(1, (size_t)size); }

// State save (called from Bridge)
extern "C" int ios_save_state(const char *path) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    const char header[8] = { 'G','S','S','T','A','T','E','1' };
    fwrite(header, 1, 8, f);
    fwrite(&g_sim65816, sizeof(g_sim65816), 1, f);
    fwrite(&g_moremem,  sizeof(g_moremem),  1, f);
    fwrite(&g_iwm,      sizeof(g_iwm),      1, f);
    fwrite(&g_video,    sizeof(g_video),    1, f);
    fwrite(&g_sound,    sizeof(g_sound),    1, f);
    fwrite(&g_paddles,  sizeof(g_paddles),  1, f);
    fwrite(g_memory_ptr,        1, g_sim65816.g_mem_size_total, f);
    fwrite(g_slow_memory_ptr,   1, 128 * 1024, f);
    fwrite(g_dummy_memory1_ptr, 1, 256, f);
    fclose(f);
    return 0;
}

extern "C" int ios_load_state(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    char header[8];
    if (fread(header, 1, 8, f) != 8 || memcmp(header, "GSSTATE1", 8) != 0) {
        fclose(f); return -2;
    }
    fread(&g_sim65816, sizeof(g_sim65816), 1, f);
    fread(&g_moremem,  sizeof(g_moremem),  1, f);
    fread(&g_iwm,      sizeof(g_iwm),      1, f);
    fread(&g_video,    sizeof(g_video),    1, f);
    fread(&g_sound,    sizeof(g_sound),    1, f);
    fread(&g_paddles,  sizeof(g_paddles),  1, f);
    fread(g_memory_ptr,        1, g_sim65816.g_mem_size_total, f);
    fread(g_slow_memory_ptr,   1, 128 * 1024, f);
    fread(g_dummy_memory1_ptr, 1, 256, f);
    fclose(f);
    return 0;
}

// ----------------------------------------------------------------------------
// Driver registration: called before kegsmain_init via g_driver.init()
extern "C" void ios_kegs_driver(void) {
    g_driver.platform = PLATFORM_IOS;
    g_driver.environment = ENV_TOUCH;
    g_driver.x_config_load_roms = ios_load_roms;
    g_driver.x_post_event       = NULL;
    g_driver.x_handle_fkey      = NULL;
    g_driver.x_handle_state     = NULL;
    g_driver.x_fixed_memory_ptr = NULL;
    g_driver.x_notify_eject     = NULL;
}
