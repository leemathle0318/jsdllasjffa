#import "Receiver.h"
#import "Shared.h"
#import <objc/runtime.h>
#import <substrate.h>
#include <mach-o/dyld.h>
#include <notify.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <unistd.h>
#include <sys/stat.h>

namespace {
using Video3 = void (*)(id, SEL, CMSampleBufferRef, bool, bool);
using Video1 = void (*)(id, SEL, CMSampleBufferRef);
using Audio2 = void (*)(id, SEL, CMSampleBufferRef, id);
Video3 originalVideo3 = nullptr;
Video1 originalVideo1 = nullptr;
Audio2 originalAudio = nullptr;
bool installedVideo = false, installedAudio = false;
dispatch_queue_t controlQueue;
dispatch_source_t statusTimer;
std::atomic<bool> checkQueued{false};
NSString *lastRequest;

void video3(id self, SEL cmd, CMSampleBufferRef buffer, bool controls, bool stills) {
    @autoreleasepool {
        if (OBEnabled()) OBReplaceVideo(buffer);
        originalVideo3(self, cmd, buffer, controls, stills);
    }
}
void video1(id self, SEL cmd, CMSampleBufferRef buffer) {
    @autoreleasepool {
        if (OBEnabled()) OBReplaceVideo(buffer);
        originalVideo1(self, cmd, buffer);
    }
}
void audio2(id self, SEL cmd, CMSampleBufferRef buffer, id input) {
    @autoreleasepool {
        CMSampleBufferRef mixed = OBEnabled() ? OBCopyAudio(buffer) : nullptr;
        originalAudio(self, cmd, mixed ?: buffer, input);
        if (mixed) CFRelease(mixed);
    }
}

const char *unqualified(const char *type) {
    while (*type && strchr("rnNoORV", *type)) ++type;
    return type;
}
bool matches(Method m, unsigned index, char expected) {
    char type[256]{}; method_getArgumentType(m, index, type, sizeof(type));
    const char *p = unqualified(type);
    if (expected == 'B') return *p == 'B' || *p == 'c';
    if (expected == '^') return *p == '^' && strstr(p, "CMSampleBuffer");
    return *p == expected;
}
bool signature(Method m, unsigned count) {
    if (!m || method_getNumberOfArguments(m) != count) return false;
    char result[32]{}; method_getReturnType(m, result, sizeof(result));
    return !strcmp(unqualified(result), "v") && matches(m, 0, '@') && matches(m, 1, ':') && matches(m, 2, '^');
}

void loadControl() {
    NSDictionary *config = [NSDictionary dictionaryWithContentsOfFile:OB_CONFIG];
    if (![config isKindOfClass:NSDictionary.class]) return;
    NSString *request = config[@"RequestID"];
    if (![request isKindOfClass:NSString.class] || [request isEqualToString:lastRequest]) return;
    // Saved enable flags never auto-start after a later reboot. A new command
    // must have been written in Settings in the previous 15 seconds.
    NSDate *date = config[@"RequestDate"];
    if (![date isKindOfClass:NSDate.class] || fabs(date.timeIntervalSinceNow) > 15) return;
    if ([config[@"Enabled"] boolValue]) {
        if (!installedVideo || !installedAudio) return;
        NSString *bind = config[@"BindIP"], *peer = config[@"PCIP"];
        if (![bind isKindOfClass:NSString.class] || ![peer isKindOfClass:NSString.class]) return;
        lastRequest = request; OBStart(bind, peer);
    } else { lastRequest = request; OBStop(); }
}

void checkHooks() {
    @autoreleasepool {
        Class video = objc_getClass("BWFigVideoCaptureStream");
        Class audio = objc_getClass("BWAudioConverterNode");
        SEL modern = sel_registerName("sourceNodeWillEmitVideoSampleBuffer:drivesCameraControls:deliversStills:");
        SEL legacy = sel_registerName("sourceNodeWillEmitVideoSampleBuffer:");
        SEL render = sel_registerName("renderSampleBuffer:forInput:");
        Method vm = video ? class_getInstanceMethod(video, modern) : nullptr;
        Method vl = video ? class_getInstanceMethod(video, legacy) : nullptr;
        Method am = audio ? class_getInstanceMethod(audio, render) : nullptr;
        if (!installedVideo && signature(vm, 5) && matches(vm, 3, 'B') && matches(vm, 4, 'B')) {
            MSHookMessageEx(video, modern, (IMP)video3, (IMP *)&originalVideo3); installedVideo = true;
        } else if (!installedVideo && signature(vl, 3)) {
            MSHookMessageEx(video, legacy, (IMP)video1, (IMP *)&originalVideo1); installedVideo = true;
        }
        if (!installedAudio && signature(am, 4) && matches(am, 3, '@')) {
            MSHookMessageEx(audio, render, (IMP)audio2, (IMP *)&originalAudio); installedAudio = true;
        }
        NSString *detail = [NSString stringWithFormat:@"系统接口检查：视频 %@ / 音频 %@\nV: %s\nA: %s",
            installedVideo ? @"已挂接（待实测）" : @"不匹配/未加载",
            installedAudio ? @"已挂接（待实测）" : @"不匹配/未加载",
            vm ? method_getTypeEncoding(vm) : (vl ? method_getTypeEncoding(vl) : "missing"),
            am ? method_getTypeEncoding(am) : "missing"];
        OBSetHookStatus(installedVideo, installedAudio, detail);
        loadControl();
    }
}
void imageLoaded(const mach_header *, intptr_t) {
    // No Objective-C/FFmpeg work while dyld holds its image loader lock.
    if (!controlQueue || checkQueued.exchange(true)) return;
    dispatch_async(controlQueue, ^{ checkQueued = false; checkHooks(); });
}
}

__attribute__((constructor)) static void OBInitialize() {
    @autoreleasepool {
        controlQueue = dispatch_queue_create("local.xiaoguai.obsbridge.control", DISPATCH_QUEUE_SERIAL);
        int token;
        notify_register_dispatch(OB_NOTIFY, &token, controlQueue, ^(int) { loadControl(); });
        _dyld_register_func_for_add_image(imageLoaded);
        dispatch_async(controlQueue, ^{ checkHooks(); });
        statusTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, controlQueue);
        dispatch_source_set_timer(statusTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC),
                                 2 * NSEC_PER_SEC, NSEC_PER_SEC / 4);
        dispatch_source_set_event_handler(statusTimer, ^{
            @autoreleasepool {
                NSDictionary *status = @{@"Text": OBStatus(), @"Date": [NSDate date],
                                         @"Enabled": @(OBEnabled()), @"PID": @(getpid())};
                if ([status writeToFile:OB_STATUS atomically:YES]) chmod(OB_STATUS.fileSystemRepresentation, 0644);
            }
        });
        dispatch_resume(statusTimer);
    }
}
