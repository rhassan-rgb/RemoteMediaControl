//
//  MediaRemote.h
//  MediaRemoteServer
//
//  Minimal bindings for the private MediaRemote.framework shipped on macOS.
//  We load the framework with dlopen and resolve the few symbols we need with
//  dlsym so the binary does not have to link against the private framework
//  directly. This also lets the server keep running (with limited features) on
//  systems where the private symbols are no longer available.
//
//  Tested against macOS 12–14. On macOS 15 (Sequoia) 15.4+ Apple tightened
//  access to MRMediaRemoteSendCommand; if it fails we fall back to posting
//  HID media-key events via IOKit.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Well-known MediaRemote command ids.
typedef NS_ENUM(int, MRCommand) {
    MRCommandPlay            = 0,
    MRCommandPause           = 1,
    MRCommandTogglePlayPause = 2,
    MRCommandStop            = 3,
    MRCommandNextTrack       = 4,
    MRCommandPreviousTrack   = 5,
};

@interface MediaRemote : NSObject

/// Returns YES if the private framework loaded and the symbols we need exist.
+ (BOOL)isAvailable;

/// Send a transport-control command. Returns YES if the call was dispatched;
/// actual success depends on whether any app is currently registered as the
/// "now playing" app.
+ (BOOL)sendCommand:(MRCommand)command;

/// Fetch the current now-playing track metadata. Calls `completion` on the
/// main queue with a dictionary containing (all optional):
///   title   : NSString
///   artist  : NSString
///   album   : NSString
///   duration: NSNumber (seconds)
///   elapsed : NSNumber (seconds)
/// Passes nil if nothing is playing or the API is unavailable.
+ (void)getNowPlayingInfo:(void (^)(NSDictionary * _Nullable info))completion;

/// Fetch the bundle identifier of the app that currently owns the now-playing
/// session, e.g. "com.apple.Music" or "com.spotify.client". `completion` runs
/// on the main queue; nil means no known player.
+ (void)getNowPlayingApplication:(void (^)(NSString * _Nullable bundleId,
                                           NSString * _Nullable displayName))completion;

/// Combined lookup: resolves the active player once (via the shared
/// FindActivePlayer TTL cache) and returns both the track info and the
/// owning application together. Clients that poll regularly should use
/// this instead of calling `getNowPlayingInfo:` + `getNowPlayingApplication:`
/// separately — it halves the AppleScript work per poll. `completion` runs
/// on the main queue.
+ (void)getNowPlayingState:(void (^)(NSDictionary * _Nullable info,
                                     NSString * _Nullable bundleId,
                                     NSString * _Nullable displayName))completion;

@end

NS_ASSUME_NONNULL_END
