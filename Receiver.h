#pragma once
#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <AudioToolbox/AudioToolbox.h>

FOUNDATION_EXPORT double OBNow(void);
FOUNDATION_EXPORT BOOL OBEnabled(void);
FOUNDATION_EXPORT void OBStart(NSString *bindIP, NSString *allowedPeer);
FOUNDATION_EXPORT void OBStop(void);
FOUNDATION_EXPORT NSString *OBStatus(void);
FOUNDATION_EXPORT NSString *OBWiFiIP(void);
FOUNDATION_EXPORT void OBSetHookStatus(BOOL video, BOOL audio, NSString *detail);
// Mutates the system source's pixel buffer, not an app's capture delegate.
FOUNDATION_EXPORT BOOL OBReplaceVideo(CMSampleBufferRef camera);
FOUNDATION_EXPORT CMSampleBufferRef OBCopyAudio(CMSampleBufferRef mic) CF_RETURNS_RETAINED;
FOUNDATION_EXPORT BOOL OBMixABL(AudioBufferList *abl, UInt32 frames,
                              const AudioStreamBasicDescription *format, double time);
