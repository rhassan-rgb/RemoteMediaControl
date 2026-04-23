//
//  VolumeControl.h
//  MediaRemoteServer
//
//  Get/set the system's default output device volume via CoreAudio. Values
//  are in the range 0.0 ... 1.0. Channels are averaged on read and applied
//  uniformly on write so this works for stereo as well as multi-channel
//  outputs (USB DACs, etc.).
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface VolumeControl : NSObject

/// Current output volume (0.0 - 1.0). Returns -1 on error.
+ (float)getVolume;

/// Set output volume (0.0 - 1.0). Returns YES on success.
+ (BOOL)setVolume:(float)volume;

/// Mute state
+ (BOOL)isMuted;
+ (BOOL)setMuted:(BOOL)muted;

@end

NS_ASSUME_NONNULL_END
