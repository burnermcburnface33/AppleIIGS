// Audio bridge: KEGS produces 16-bit stereo samples at g_audio_rate (44100).
// We push them into a lock-free ring buffer; an AVAudioEngine source node
// drains the ring buffer to the device output.

#import <AVFoundation/AVFoundation.h>
#include <atomic>
#include <stdlib.h>
#include <string.h>

#include "defc.h"
#include "sound.h"
#include "sim65816.h"

// Ring buffer (power-of-two so we can mask). 64K frames = ~1.5s at 44.1kHz.
#define RING_FRAMES_LOG2 16
#define RING_FRAMES      (1 << RING_FRAMES_LOG2)
#define RING_MASK        (RING_FRAMES - 1)

typedef struct {
    int16_t l;
    int16_t r;
} StereoFrame;

static StereoFrame              gRing[RING_FRAMES];
static std::atomic<uint32_t>    gWritePos{0};
static std::atomic<uint32_t>    gReadPos{0};

static AVAudioEngine            *gEngine = nil;
static AVAudioSourceNode        *gSource = nil;
static double                    gSampleRate = 44100.0;
static std::atomic<bool>         gAudioPaused{false};

// Called by KEGS (sound.cpp) to send a buffer of 16-bit stereo samples.
// Declared in sound.h with C++ linkage; match that.
int x_snd_send_audio(byte *ptr, int size) {
    if (gAudioPaused.load()) return size;
    int frames = size / 4; // 2 channels, 2 bytes each
    const int16_t *src = (const int16_t *)ptr;

    uint32_t wpos = gWritePos.load(std::memory_order_relaxed);
    uint32_t rpos = gReadPos.load(std::memory_order_acquire);
    uint32_t avail = RING_FRAMES - (wpos - rpos);

    if (frames > (int)avail) frames = (int)avail;
    for (int i = 0; i < frames; i++) {
        StereoFrame *f = &gRing[(wpos + (uint32_t)i) & RING_MASK];
        f->l = src[i * 2 + 0];
        f->r = src[i * 2 + 1];
    }
    gWritePos.store(wpos + (uint32_t)frames, std::memory_order_release);
    return size;
}

void x_snd_init(word32 *shmem) {
    (void)shmem;
}

void x_snd_shutdown(void) {}

// ---------------------------------------------------------------------------
// AVAudioEngine setup - these are called from Swift/Obj-C so they need C linkage
extern "C" void ios_audio_install(void) {
    if (gEngine) return;

    NSError *err = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryAmbient
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers
                   error:&err];
    if (err) {
        NSLog(@"Audio session category error: %@", err);
    }
    [session setActive:YES error:&err];
    if (err) {
        NSLog(@"Audio session activate error: %@", err);
    }
    gSampleRate = session.sampleRate;
    if (gSampleRate < 22050.0) gSampleRate = 44100.0;

    // Configure KEGS to produce samples at our preferred rate
    g_sound.g_audio_enable = 1;
    g_sound.g_audio_rate   = 44100;

    gEngine = [[AVAudioEngine alloc] init];

    AVAudioFormat *fmt = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:44100.0
                                channels:2];

    AVAudioSourceNodeRenderBlock renderBlock = ^OSStatus(BOOL *isSilence,
                                                         const AudioTimeStamp *timestamp,
                                                         AVAudioFrameCount frameCount,
                                                         AudioBufferList *outputData) {
        float *outL = (float *)outputData->mBuffers[0].mData;
        float *outR = (float *)outputData->mBuffers[1].mData;

        uint32_t rpos = gReadPos.load(std::memory_order_relaxed);
        uint32_t wpos = gWritePos.load(std::memory_order_acquire);
        uint32_t avail = wpos - rpos;

        AVAudioFrameCount toCopy = (avail < frameCount) ? (AVAudioFrameCount)avail : frameCount;
        AVAudioFrameCount silence = frameCount - toCopy;

        const float scale = 1.f / 32768.f;
        for (AVAudioFrameCount i = 0; i < toCopy; i++) {
            StereoFrame *f = &gRing[(rpos + i) & RING_MASK];
            outL[i] = (float)f->l * scale;
            outR[i] = (float)f->r * scale;
        }
        for (AVAudioFrameCount i = 0; i < silence; i++) {
            outL[toCopy + i] = 0.f;
            outR[toCopy + i] = 0.f;
        }
        gReadPos.store(rpos + toCopy, std::memory_order_release);

        if (toCopy == 0) *isSilence = YES;
        return noErr;
    };

    gSource = [[AVAudioSourceNode alloc] initWithFormat:fmt renderBlock:renderBlock];
    [gEngine attachNode:gSource];
    [gEngine connect:gSource to:gEngine.mainMixerNode format:fmt];

    err = nil;
    [gEngine startAndReturnError:&err];
    if (err) {
        NSLog(@"AVAudioEngine start error: %@", err);
    }
}

extern "C" void ios_audio_shutdown(void) {
    if (gEngine) {
        [gEngine stop];
        gEngine = nil;
        gSource = nil;
    }
}

extern "C" void ios_audio_pause(BOOL paused) {
    gAudioPaused.store(paused != NO);
}
