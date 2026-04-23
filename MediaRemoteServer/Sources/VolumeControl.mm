//
//  VolumeControl.mm
//

#import "VolumeControl.h"
#import <CoreAudio/CoreAudio.h>

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

static AudioObjectID DefaultOutputDevice(void) {
    AudioObjectID dev = kAudioObjectUnknown;
    UInt32 size = sizeof(dev);
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain,
    };
    OSStatus s = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, NULL, &size, &dev);
    return (s == noErr) ? dev : kAudioObjectUnknown;
}

// Devices expose volume in one of two ways:
//   • A master (kAudioObjectPropertyElementMain/0) channel that covers all.
//   • Separate per-channel volumes. We discover the channel layout via
//     kAudioDevicePropertyPreferredChannelsForStereo.
// The helpers below abstract that.

static BOOL GetVolumeScalar(AudioObjectID dev, Float32 *out) {
    if (dev == kAudioObjectUnknown) return NO;

    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    Float32 v = 0;
    UInt32 size = sizeof(v);

    // Try master element first.
    if (AudioObjectHasProperty(dev, &addr)) {
        if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &v) == noErr) {
            *out = v;
            return YES;
        }
    }

    // Fall back to averaging L+R.
    AudioObjectPropertyAddress chansAddr = {
        kAudioDevicePropertyPreferredChannelsForStereo,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 chans[2] = {1, 2};
    UInt32 cSize = sizeof(chans);
    AudioObjectGetPropertyData(dev, &chansAddr, 0, NULL, &cSize, chans);

    Float32 total = 0;
    int count = 0;
    for (int i = 0; i < 2; ++i) {
        addr.mElement = chans[i];
        if (!AudioObjectHasProperty(dev, &addr)) continue;
        size = sizeof(v);
        if (AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &v) == noErr) {
            total += v;
            count += 1;
        }
    }
    if (count == 0) return NO;
    *out = total / count;
    return YES;
}

static BOOL SetVolumeScalar(AudioObjectID dev, Float32 v) {
    if (dev == kAudioObjectUnknown) return NO;
    v = MAX(0.0f, MIN(1.0f, v));

    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyVolumeScalar,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };

    Boolean writable = false;
    AudioObjectIsPropertySettable(dev, &addr, &writable);
    if (writable) {
        return AudioObjectSetPropertyData(dev, &addr, 0, NULL,
                                          sizeof(v), &v) == noErr;
    }

    // Per-channel fallback.
    AudioObjectPropertyAddress chansAddr = {
        kAudioDevicePropertyPreferredChannelsForStereo,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 chans[2] = {1, 2};
    UInt32 cSize = sizeof(chans);
    AudioObjectGetPropertyData(dev, &chansAddr, 0, NULL, &cSize, chans);

    BOOL ok = NO;
    for (int i = 0; i < 2; ++i) {
        addr.mElement = chans[i];
        if (!AudioObjectHasProperty(dev, &addr)) continue;
        writable = false;
        AudioObjectIsPropertySettable(dev, &addr, &writable);
        if (!writable) continue;
        if (AudioObjectSetPropertyData(dev, &addr, 0, NULL,
                                       sizeof(v), &v) == noErr) {
            ok = YES;
        }
    }
    return ok;
}

// -----------------------------------------------------------------------------

@implementation VolumeControl

+ (float)getVolume {
    Float32 v = 0;
    if (!GetVolumeScalar(DefaultOutputDevice(), &v)) return -1.0f;
    return (float)v;
}

+ (BOOL)setVolume:(float)volume {
    return SetVolumeScalar(DefaultOutputDevice(), (Float32)volume);
}

+ (BOOL)isMuted {
    AudioObjectID dev = DefaultOutputDevice();
    if (dev == kAudioObjectUnknown) return NO;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    UInt32 muted = 0;
    UInt32 size = sizeof(muted);
    if (!AudioObjectHasProperty(dev, &addr)) return NO;
    AudioObjectGetPropertyData(dev, &addr, 0, NULL, &size, &muted);
    return muted != 0;
}

+ (BOOL)setMuted:(BOOL)muted {
    AudioObjectID dev = DefaultOutputDevice();
    if (dev == kAudioObjectUnknown) return NO;
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyMute,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain,
    };
    if (!AudioObjectHasProperty(dev, &addr)) return NO;
    UInt32 val = muted ? 1 : 0;
    return AudioObjectSetPropertyData(dev, &addr, 0, NULL,
                                      sizeof(val), &val) == noErr;
}

@end
