// Stubs for KEGS functions whose host-side implementations are not needed on
// iOS (debug console, raster, breakpoints, mac/win-specific drivers, etc.).
// All have C++ linkage to match the declarations in protos.h.

#include "defc.h"
#include "sim65816.h"
#include "iwm.h"
#include "moremem.h"
#include "video.h"
#include "sound.h"
#include "paddles.h"
#include "config.h"
#include "scc.h"
#include "adb.h"
#include "moremem.h"
#include "protos_engine_c.h"

#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <unistd.h>

// ----------------------------------------------------------------------------
// printf/fprintf substitutes - defc.h #defines `printf` to outputInfo and
// `fprintf` to fOutputInfo. We must provide them with C linkage.

extern "C" int outputInfo(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vfprintf(stderr, fmt, ap);
    va_end(ap);
    return r;
}

extern "C" int fOutputInfo(FILE *f, const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    int r = vfprintf(f ? f : stderr, fmt, ap);
    va_end(ap);
    return r;
}

// ----------------------------------------------------------------------------
// halt_printf in real KEGS would halt the CPU and dump state. For iOS we just
// silently drop these — they're noisy "halt for debugger" hooks (IWM, ADB,
// etc.) that fire constantly during normal disk activity and would otherwise
// flood the device log.
void halt_printf(const char *fmt, ...) { (void)fmt; }
void halt2_printf(const char *fmt, ...) { (void)fmt; }

// fatal_printf is defined in sim65816.cpp; don't redefine.
// irq_printf is a #define macro in defc.h; nothing to do here.

// ----------------------------------------------------------------------------
// Breakpoint globals (dis.cpp excluded)
int g_num_breakpoints = 0;
int g_stepping = 0;
struct_breakpoint g_breakpts[MAX_BREAK_POINTS] = {};

// Apply breakpoints - normally walks g_breakpts and patches code; no-op
void apply_breakpoints(void) {}

// Disk drive sound stub (sound.cpp's play_sound() calls x_play_sound)
void x_play_sound(enum_sound /*s*/) {}

// ----------------------------------------------------------------------------
// Empty stubs for misc KEGS functions

void config_init(void) {
    // Normally loads kegs.conf and populates menus; we don't use any of that.
}

void checkImages(void) {}
void disableConsole(void) {}
void do_debug_intfc(void) {}
void apply_patch(int /*addr*/, int /*size*/, unsigned char * /*buf*/, int /*offset*/, int /*image*/) {}

void x_set_video_fx(_videofx /*fx*/) {}
void x_refresh_panel(int /*panel*/) {}
void x_refresh_video(void) {}
void x_recenter_hw_mouse(void) {}
void x_update_modifiers(unsigned int /*mods*/) {}
void x_clk_setup_bram_version(void) {}
void x_config_load_additional_roms(void) {}
void x_notify_motor_status(int /*on*/, int /*slot*/, int /*drive*/, int /*track*/) {}
void x_notify_disk_ejection(int /*slot*/, int /*drive*/) {}
void x_notify_disk_insertion(int /*a*/, int /*b*/, int /*c*/, int /*d*/, int /*e*/) {}

// ----------------------------------------------------------------------------
// Marinetti TCP/IP - returns 0 (no action)
int process_marinetti_command(int /*cmd*/, unsigned int * /*p1*/, unsigned int & /*p2*/, unsigned int & /*p3*/) {
    return 0;
}

// ----------------------------------------------------------------------------
// SCC mac serial driver (we don't include the real mac driver)
int  scc_serial_mac_init(int /*port*/)                                   { return 0; }
void scc_serial_mac_change_params(int /*port*/)                          {}
void scc_serial_mac_fill_readbuf(int /*port*/, int /*space_left*/, double /*dcycs*/) {}
void scc_serial_mac_empty_writebuf(int /*port*/)                         {}
void scc_delayed_enable(void)                                            {}

// ----------------------------------------------------------------------------
// Disassembler stubs (dis.cpp excluded)
int do_dis(FILE * /*f*/, unsigned int /*addr*/, int /*a*/, int /*b*/, int /*c*/, unsigned int /*d*/) {
    return 0;
}

// ----------------------------------------------------------------------------
// Paddles - we don't emulate the iCade
void paddle_trigger_icade(double /*dcycs*/) {}

// ----------------------------------------------------------------------------
// Sound shmem placeholder - sound.cpp's "child" sound loop is for a separate
// process model that we don't use. Provide stubs.
void child_sound_loop(int /*read_fd*/, int /*write_fd*/, unsigned int * /*shmem*/) {}
void child_sound_playit(unsigned int /*amt*/) {}
void x_sound_free(unsigned int * /*ptr*/) {}

// ----------------------------------------------------------------------------
// Exit
void x_exit(int code) {
    fprintf(stderr, "x_exit(%d)\n", code);
    // Don't actually exit - that would kill the app. Halt the simulator.
    set_halt(HALT_EVENT);
}

// my_exit and micro_sleep are defined elsewhere (sim65816.cpp / clock.cpp).

// ----------------------------------------------------------------------------
// SaveState class - we excluded SaveState.cpp but sim65816/async_event still
// reference g_savestate.handleState() and handleKey(). Provide minimal stubs.

#include "SaveState.h"

int savedState::maxSize = 0;

savedState::savedState() {
    fullsave = 0;
    fastalloc = 0;
    memset(&param, 0, sizeof(param));
}

void savedState::release() {}
void savedState::save(int, int) {}
void savedState::writeToDisk(const char *) {}
int  savedState::loadFromDisk(const char *) { return -1; }
int  savedState::loadFromDiskInternal(const char *) { return -1; }
void savedState::restore() {}
void savedState::display() {}

s_savestate::s_savestate() {
    iNextState = 0;
    iCurState = 0;
    nextStateVBL = 0;
    nextScreenVBL = 0;
    targetStateSens = 0;
    lastrefreshcycs = 0.0;
    cache = nullptr;
    cachepos = 0;
    cachefree = 0;
    cacheSize = 0;
    stateActionRequired = 0;
}
s_savestate::~s_savestate() {}
void s_savestate::handleState() {}
void s_savestate::handleKey(int /*key*/, int /*isup*/) {}

// The remaining methods aren't referenced from any compiled object but provide
// them anyway so the linker can satisfy any internal references.
void  s_savestate::reset_rewind()           {}
void  s_savestate::reset_state()            {}
void  s_savestate::delete_state(int)        {}
void  s_savestate::init()                   {}
void  s_savestate::shut()                   {}
void  s_savestate::saveState(const char *)  {}
void  s_savestate::restoreState(const char *) {}
int   s_savestate::getSavedStateVBL()       { return 0; }
void *s_savestate::x_free(void *p, int, int) { free(p); return nullptr; }
void *s_savestate::x_malloc(int sz, int)    { return calloc(1, (size_t)sz); }
int   s_savestate::get_free_memory_size()   { return 0; }

s_savestate g_savestate;
