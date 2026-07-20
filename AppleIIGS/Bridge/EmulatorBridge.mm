#import "EmulatorBridge.h"
#import <UIKit/UIKit.h>

#include <pthread.h>
#include <atomic>

// KEGS core
#include "defc.h"
#include "driver.h"
#include "sim65816.h"
#include "video.h"
#include "moremem.h"
#include "iwm.h"
#include "paddles.h"
#include "adb.h"
#include "async_event.h"

// KEGS entry points (C++ linkage - declared in protos.h / sim65816)
void kegsmain_init(int argc, char **argv);
void kegsmain_shut(void);
void run_prog_init(void);
int  run_prog_loop(void);
void run_prog_shut(void);
void insert_disk(int slot, int drive, const char *name, int ejected, int force_size, const char *partition_name, int part_num);
void eject_disk_by_num(int slot, int drive);

// iOS-specific entry points (we control these so we use C linkage)
extern "C" {
    void ios_kegs_driver(void);
    void ios_video_set_external_buffer(uint8_t *buf, int w, int h, int stride);
    void ios_audio_install(void);
    void ios_audio_shutdown(void);
    void ios_audio_pause(BOOL paused);
    int  ios_save_state(const char *path);
    int  ios_load_state(const char *path);
    extern int   x_vbl_count;
    extern float joyX, joyY;
    extern int   oaButton, caButton;
}

// Public framebuffer (BGRA8 - we draw into this from x_async_refresh)
static const int kFrameWidth  = X_A2_WINDOW_WIDTH;
static const int kFrameHeight = X_A2_WINDOW_HEIGHT;
static const int kBytesPerPx  = 4;
static uint8_t   gFrameBuffer[kFrameWidth * kFrameHeight * kBytesPerPx] __attribute__((aligned(64)));

static EmulatorBridge *gBridgeInstance = nil;

@interface EmulatorBridge ()
{
    pthread_t           _thread;
    std::atomic<bool>   _shouldRun;
    std::atomic<bool>   _paused;
    std::atomic<bool>   _initialized;
    NSMutableDictionary<NSNumber *, NSString *> *_mountedDisks;
}
@end

// Pending disk operations are deferred to the emulator thread to avoid races.
typedef struct {
    int  slot;
    int  drive;
    BOOL eject;
    char path[1024];
} PendingDiskOp;

static pthread_mutex_t gPendingMutex = PTHREAD_MUTEX_INITIALIZER;
static PendingDiskOp   gPendingOps[16];
static int             gPendingCount = 0;

static void apply_pending_disk_ops(void) {
    pthread_mutex_lock(&gPendingMutex);
    int count = gPendingCount;
    PendingDiskOp ops[16];
    memcpy(ops, gPendingOps, sizeof(PendingDiskOp) * count);
    gPendingCount = 0;
    pthread_mutex_unlock(&gPendingMutex);

    for (int i = 0; i < count; i++) {
        if (ops[i].eject) {
            eject_disk_by_num(ops[i].slot, ops[i].drive);
        } else {
            insert_disk(ops[i].slot, ops[i].drive, ops[i].path, 0, 0, NULL, 0);
        }
    }
}

@implementation EmulatorBridge

+ (instancetype)shared {
    static dispatch_once_t once;
    static EmulatorBridge *inst;
    dispatch_once(&once, ^{
        inst = [[EmulatorBridge alloc] init];
        gBridgeInstance = inst;
    });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _mountedDisks = [NSMutableDictionary dictionary];
        _shouldRun.store(false);
        _paused.store(false);
        _initialized.store(false);
        memset(gFrameBuffer, 0, sizeof(gFrameBuffer));
    }
    return self;
}

#pragma mark - Properties

- (NSInteger)frameWidth  { return kFrameWidth; }
- (NSInteger)frameHeight { return kFrameHeight; }
- (NSInteger)frameBytesPerRow { return kFrameWidth * kBytesPerPx; }
- (const uint8_t *)frameBufferPtr { return gFrameBuffer; }
- (BOOL)isRunning { return _shouldRun.load() && !_paused.load(); }
- (BOOL)isInitialized { return _initialized.load(); }
- (float)currentMHz { return (float)g_sim65816.g_sim_mhz; }

#pragma mark - Lifecycle

- (void)start {
    if (_shouldRun.load()) return;

    // Wire up the iOS driver before any KEGS code runs
    g_driver.init(ios_kegs_driver);
    g_driver.platform = PLATFORM_IOS;
    g_driver.environment = ENV_TOUCH;

    // Install audio (must be done from main thread for AVAudioSession)
    ios_audio_install();

    // Tell the video driver where to render its output bitmap
    ios_video_set_external_buffer(gFrameBuffer, kFrameWidth, kFrameHeight, kFrameWidth * kBytesPerPx);

    _shouldRun.store(true);
    _paused.store(false);

    pthread_create(&_thread, NULL, &EmulatorThreadMain, (__bridge void *)self);
}

static void *EmulatorThreadMain(void *ctx) {
    pthread_setname_np("AppleIIGS.emulator");

    EmulatorBridge *self = (__bridge EmulatorBridge *)ctx;

    // Initialize KEGS
    kegsmain_init(0, NULL);
    run_prog_init();

    self->_initialized.store(true);

    while (self->_shouldRun.load()) {
        if (self->_paused.load()) {
            usleep(16000);
            continue;
        }

        apply_pending_disk_ops();

        int ret = run_prog_loop();
        if (!ret) {
            // Halted - try to recover by resetting
            do_reset();
            r_sim65816.reset_quit();
        }

        // Notify renderer that a new frame is ready
        id<EmulatorBridgeDelegate> delegate = self.delegate;
        if (delegate && [delegate respondsToSelector:@selector(emulatorDidUpdateFrame)]) {
            [delegate emulatorDidUpdateFrame];
        }
    }

    run_prog_shut();
    kegsmain_shut();
    return NULL;
}

- (void)pause {
    _paused.store(true);
    ios_audio_pause(YES);
    r_sim65816.pause();
}

- (void)resume {
    _paused.store(false);
    ios_audio_pause(NO);
    r_sim65816.resume();
}

- (void)reset {
    if (!_initialized.load()) return;
    do_reset();
}

- (void)coldBoot {
    if (!_initialized.load()) return;
    // Wipe RAM, then reset
    extern byte *g_memory_ptr;
    if (g_memory_ptr) {
        memset(g_memory_ptr, 0, g_sim65816.g_mem_size_total);
    }
    do_reset();
}

- (void)shutdown {
    _shouldRun.store(false);
    if (_thread) {
        pthread_join(_thread, NULL);
        _thread = 0;
    }
    ios_audio_shutdown();
}

#pragma mark - Configuration

- (void)setSpeed:(GSSpeed)speed {
    g_sim65816.set_limit_speed((enum speedenum)speed);
}

- (GSSpeed)speed {
    return (GSSpeed)g_sim65816.get_limit_speed();
}

- (void)setColorMonitor:(BOOL)color {
    r_sim65816.set_color_mode(color ? COLORMODE_AUTO : COLORMODE_BW);
}

#pragma mark - Keyboard

// All keyboard injection goes through ActiveGS's async event queue so the
// actual ADB state update happens on the emulator thread (in unstack_event,
// called from run_prog_loop). Calling adb_*_update from the main thread races
// with the CPU and the keystrokes get dropped.

- (void)keyDown:(int)a2code {
    add_event_key(a2code, 0);
}

- (void)keyUp:(int)a2code {
    add_event_key(a2code, 1);
}

- (void)typeText:(NSString *)text {
    NSData *data = [text dataUsingEncoding:NSASCIIStringEncoding];
    if (!data) return;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    NSUInteger len = data.length;
    for (NSUInteger i = 0; i < len; i++) {
        uint8_t ch = bytes[i];
        int code = AsciiToAdbScancode(ch);
        if (code < 0) continue;
        BOOL shift = AsciiNeedsShift(ch);
        if (shift) add_event_key(0x38, 0); // shift down
        add_event_key(code, 0);
        add_event_key(code, 1);
        if (shift) add_event_key(0x38, 1); // shift up
    }
}

static int AsciiToAdbScancode(uint8_t c) {
    // ADB raw scancodes used in KEGS adb_kbd_reg0_data
    static const int letterMap[26] = {
        0x00, 0x0b, 0x08, 0x02, 0x0e, 0x03, 0x05, 0x04, 0x22, 0x26,
        0x28, 0x25, 0x2e, 0x2d, 0x1f, 0x23, 0x0c, 0x0f, 0x01, 0x11,
        0x20, 0x09, 0x0d, 0x07, 0x10, 0x06
    };
    static const int digitMap[10] = {
        0x1d, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1a, 0x1c, 0x19
    };
    if (c >= 'a' && c <= 'z') return letterMap[c - 'a'];
    if (c >= 'A' && c <= 'Z') return letterMap[c - 'A'];
    if (c >= '0' && c <= '9') return digitMap[c - '0'];
    switch (c) {
        case ' ':  return 0x31;
        case '\n':
        case '\r': return 0x24;
        case '\t': return 0x30;
        case 0x7f: // backspace
        case 0x08: return 0x33;
        case 0x1b: return 0x35;
        case '-':  return 0x1b;
        case '=':  return 0x18;
        case '[':  return 0x21;
        case ']':  return 0x1e;
        case '\\': return 0x2a;
        case ';':  return 0x29;
        case '\'': return 0x27;
        case ',':  return 0x2b;
        case '.':  return 0x2f;
        case '/':  return 0x2c;
        case '`':  return 0x32;
        // shifted symbols handled in AsciiNeedsShift path below
        case '!':  return 0x12;
        case '@':  return 0x13;
        case '#':  return 0x14;
        case '$':  return 0x15;
        case '%':  return 0x17;
        case '^':  return 0x16;
        case '&':  return 0x1a;
        case '*':  return 0x1c;
        case '(':  return 0x19;
        case ')':  return 0x1d;
        case '_':  return 0x1b;
        case '+':  return 0x18;
        case '{':  return 0x21;
        case '}':  return 0x1e;
        case '|':  return 0x2a;
        case ':':  return 0x29;
        case '"':  return 0x27;
        case '<':  return 0x2b;
        case '>':  return 0x2f;
        case '?':  return 0x2c;
        case '~':  return 0x32;
        default:   return -1;
    }
}

static BOOL AsciiNeedsShift(uint8_t c) {
    if (c >= 'A' && c <= 'Z') return YES;
    switch (c) {
        case '!': case '@': case '#': case '$': case '%':
        case '^': case '&': case '*': case '(': case ')':
        case '_': case '+': case '{': case '}': case '|':
        case ':': case '"': case '<': case '>': case '?':
        case '~':
            return YES;
        default: return NO;
    }
}

#pragma mark - Joystick

- (void)setJoystickX:(float)x y:(float)y {
    joyX = x;
    joyY = y;
}

- (void)setJoystickButton:(int)button pressed:(BOOL)pressed {
    if (button == 0) oaButton = pressed ? 1 : 0;
    else if (button == 1) caButton = pressed ? 1 : 0;
}

#pragma mark - Disk

static void enqueue_disk_op(int slot, int drive, BOOL eject, const char *path) {
    pthread_mutex_lock(&gPendingMutex);
    if (gPendingCount < 16) {
        PendingDiskOp *op = &gPendingOps[gPendingCount++];
        op->slot = slot;
        op->drive = drive;
        op->eject = eject;
        if (path) {
            strncpy(op->path, path, sizeof(op->path) - 1);
            op->path[sizeof(op->path) - 1] = 0;
        } else {
            op->path[0] = 0;
        }
    }
    pthread_mutex_unlock(&gPendingMutex);
}

static void slotDriveForDiskSlot(GSDiskSlot s, int *slot, int *drive) {
    switch (s) {
        case GSDiskSlotS5D1: *slot = 5; *drive = 1; break;
        case GSDiskSlotS5D2: *slot = 5; *drive = 2; break;
        case GSDiskSlotS6D1: *slot = 6; *drive = 1; break;
        case GSDiskSlotS6D2: *slot = 6; *drive = 2; break;
        case GSDiskSlotS7D1: *slot = 7; *drive = 1; break;
        case GSDiskSlotS7D2: *slot = 7; *drive = 2; break;
        default:             *slot = 5; *drive = 1; break;
    }
}

- (BOOL)insertDiskAtPath:(NSString *)path slot:(GSDiskSlot)slot {
    int s, d;
    slotDriveForDiskSlot(slot, &s, &d);
    enqueue_disk_op(s, d, NO, path.fileSystemRepresentation);
    _mountedDisks[@(slot)] = path;
    return YES;
}

- (void)ejectDisk:(GSDiskSlot)slot {
    int s, d;
    slotDriveForDiskSlot(slot, &s, &d);
    enqueue_disk_op(s, d, YES, NULL);
    [_mountedDisks removeObjectForKey:@(slot)];
}

- (NSString *)mountedDiskPath:(GSDiskSlot)slot {
    return _mountedDisks[@(slot)];
}

#pragma mark - Save state

- (BOOL)saveStateToPath:(NSString *)path {
    // Minimal save state: dump entire RAM + soft switches + CPU state
    extern int ios_save_state(const char *path);
    return ios_save_state(path.fileSystemRepresentation) == 0;
}

- (BOOL)loadStateFromPath:(NSString *)path {
    extern int ios_load_state(const char *path);
    return ios_load_state(path.fileSystemRepresentation) == 0;
}

#pragma mark - Frame capture

- (UIImage *)snapshotImage {
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        gFrameBuffer, kFrameWidth, kFrameHeight, 8, kFrameWidth * kBytesPerPx, cs,
        kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(cs);
    if (!ctx) return nil;
    CGImageRef img = CGBitmapContextCreateImage(ctx);
    CGContextRelease(ctx);
    if (!img) return nil;
    UIImage *ui = [UIImage imageWithCGImage:img];
    CGImageRelease(img);
    return ui;
}

@end

// ---------------------------------------------------------------------------
// Delegate hooks called from the iOS KEGS driver

extern "C" void ios_bridge_notify_disk_light(int motorOn, int slot, int drive, int track) {
    @autoreleasepool {
        id<EmulatorBridgeDelegate> d = gBridgeInstance.delegate;
        if (d && [d respondsToSelector:@selector(emulatorDidChangeDiskLight:slot:drive:track:)]) {
            [d emulatorDidChangeDiskLight:(motorOn != 0) slot:slot drive:drive track:track];
        }
    }
}
