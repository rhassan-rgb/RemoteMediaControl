//
//  MediaRemote.mm
//

#import "MediaRemote.h"
#import "PlayerConfig.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <IOKit/hidsystem/ev_keymap.h>

// -----------------------------------------------------------------------------
// Private symbol typedefs
// -----------------------------------------------------------------------------

typedef void (*MRSendCommandFn)(int command, NSDictionary *userInfo);
typedef void (*MRGetNowPlayingInfoFn)(dispatch_queue_t queue,
                                      void (^handler)(CFDictionaryRef info));
typedef void (*MRGetNowPlayingPIDFn)(dispatch_queue_t queue,
                                     void (^handler)(int pid));

// -----------------------------------------------------------------------------
// Framework loader
// -----------------------------------------------------------------------------

static void *gHandle                    = NULL;
static MRSendCommandFn       gSendCmd   = NULL;
static MRGetNowPlayingInfoFn gGetInfo   = NULL;
static MRGetNowPlayingPIDFn  gGetPID    = NULL;

static NSString *const kTitle    = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kArtist   = @"kMRMediaRemoteNowPlayingInfoArtist";
static NSString *const kAlbum    = @"kMRMediaRemoteNowPlayingInfoAlbum";
static NSString *const kDuration = @"kMRMediaRemoteNowPlayingInfoDuration";
static NSString *const kElapsed  = @"kMRMediaRemoteNowPlayingInfoElapsedTime";

static void MRLoadFramework(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gHandle = dlopen(
            "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
            RTLD_LAZY);
        if (!gHandle) {
            NSLog(@"[MR/mr] dlopen failed: %s", dlerror());
            return;
        }
        gSendCmd = (MRSendCommandFn)dlsym(gHandle, "MRMediaRemoteSendCommand");
        gGetInfo = (MRGetNowPlayingInfoFn)dlsym(gHandle,
                     "MRMediaRemoteGetNowPlayingInfo");
        gGetPID  = (MRGetNowPlayingPIDFn)dlsym(gHandle,
                     "MRMediaRemoteGetNowPlayingApplicationPID");
        NSLog(@"[MR/mr] loaded. send=%p getInfo=%p getPID=%p",
              gSendCmd, gGetInfo, gGetPID);
    });
}

// -----------------------------------------------------------------------------
// Fallback: post a media-key HID event (works without private-symbol access,
// but needs the user to have granted the binary Accessibility permission).
// -----------------------------------------------------------------------------

static void MRPostHIDKey(int keyCode) {
    auto post = ^(bool down) {
        NSEvent *ev = [NSEvent
            otherEventWithType:NSEventTypeSystemDefined
                      location:NSZeroPoint
                 modifierFlags:(down ? 0xa00 : 0xb00)
                     timestamp:0
                  windowNumber:0
                       context:nil
                       subtype:8
                         data1:((keyCode << 16) | ((down ? 0xa : 0xb) << 8))
                         data2:-1];
        CGEventPost(kCGHIDEventTap, [ev CGEvent]);
    };
    post(true);
    post(false);
}

// -----------------------------------------------------------------------------

@implementation MediaRemote

+ (BOOL)isAvailable {
    MRLoadFramework();
    return gSendCmd != NULL || gGetInfo != NULL;
}

+ (BOOL)sendCommand:(MRCommand)command {
    MRLoadFramework();
    if (gSendCmd) {
        gSendCmd((int)command, @{});
        return YES;
    }
    // Fallback via HID keys
    int key = -1;
    switch (command) {
        case MRCommandPlay:
        case MRCommandPause:
        case MRCommandTogglePlayPause: key = NX_KEYTYPE_PLAY;     break;
        case MRCommandNextTrack:       key = NX_KEYTYPE_NEXT;     break;
        case MRCommandPreviousTrack:   key = NX_KEYTYPE_PREVIOUS; break;
        case MRCommandStop:            key = NX_KEYTYPE_PLAY;     break;
    }
    if (key < 0) return NO;
    MRPostHIDKey(key);
    return YES;
}

// -----------------------------------------------------------------------------
// AppleScript-driven now-playing path.
// The private MediaRemote symbols (getInfo/getPID) were removed in macOS
// 15.4 (Sequoia), so by default we drive known players via AppleScript
// per the list in players.yaml. The old dlsym path is kept as a
// secondary fallback for anyone still running 12–14.
// -----------------------------------------------------------------------------

// TTL in seconds for the FindActivePlayer() cache. The iOS client polls at
// roughly 2s intervals and issues two lookups per tick (getSong + getPlayer,
// or now a single combined getState). A 1.5s TTL is long enough that the
// two halves of one poll never re-run the search, but short enough that the
// UI notices a playback change within one poll cycle after it happens.
static const NSTimeInterval kActivePlayerCacheTTL = 1.5;

// Find the first configured player that's both running *and* reporting
// "playing". Returns nil if nothing is playing. Must run on main queue.
//
// Results are cached for kActivePlayerCacheTTL seconds so two lookups
// inside the same poll tick don't re-walk every configured player and
// re-run the `isPlaying` AppleScript for each — this is the single most
// expensive thing this server does per poll. Access to the cache is on
// the main queue only (all callers come through the main-queue hop in
// MediaRemote class methods), so no extra locking is needed.
static PlayerConfig *FindActivePlayer(void) {
    static PlayerConfig *cachedPlayer = nil;
    static NSTimeInterval cachedAt = 0;

    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (cachedPlayer && (now - cachedAt) < kActivePlayerCacheTTL) {
        // Still valid. But if the cached app was quit since we cached
        // it, drop the cache — isRunning is a cheap NSWorkspace lookup
        // and it's less wrong than returning a stale bundle id.
        if ([cachedPlayer isRunning]) return cachedPlayer;
        cachedPlayer = nil;
    }

    PlayerConfig *found = nil;
    for (PlayerConfig *p in [PlayerConfig load]) {
        if (![p isRunning]) continue;
        if (![p isPlaying]) continue;
        found = p;
        break;
    }
    cachedPlayer = found;
    cachedAt = now;
    return found;
}

+ (void)getNowPlayingInfo:(void (^)(NSDictionary *))completion {
    // NSAppleScript must be driven on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        PlayerConfig *p = FindActivePlayer();
        if (p) {
            // isPlaying succeeded, so we're committed to returning via
            // this player even if individual metadata scripts fail
            // (e.g. Automation denied for some fields).
            NSMutableDictionary *out = [NSMutableDictionary new];
            if (NSString *v = [p title])    out[@"title"]    = v;
            if (NSString *v = [p artist])   out[@"artist"]   = v;
            if (NSString *v = [p album])    out[@"album"]    = v;
            if (NSNumber *v = [p duration]) out[@"duration"] = v;
            if (NSNumber *v = [p elapsed])  out[@"elapsed"]  = v;
            if (p.name.length)              out[@"source"]   = p.name;
            completion(out.count ? out : nil);
            return;
        }

        // Legacy fallback: private-framework path (macOS 12–14).
        MRLoadFramework();
        if (!gGetInfo) { completion(nil); return; }
        gGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
            if (!raw) { completion(nil); return; }
            NSDictionary *src = (__bridge NSDictionary *)raw;
            NSMutableDictionary *out = [NSMutableDictionary new];
            if (id v = src[kTitle])    out[@"title"]    = v;
            if (id v = src[kArtist])   out[@"artist"]   = v;
            if (id v = src[kAlbum])    out[@"album"]    = v;
            if (id v = src[kDuration]) out[@"duration"] = v;
            if (id v = src[kElapsed])  out[@"elapsed"]  = v;
            completion(out.count ? out : nil);
        });
    });
}

+ (void)getNowPlayingApplication:(void (^)(NSString *, NSString *))completion {
    dispatch_async(dispatch_get_main_queue(), ^{
        PlayerConfig *p = FindActivePlayer();
        if (p) { completion(p.bundleId, p.name); return; }

        // Legacy fallback: private-framework path (macOS 12–14).
        MRLoadFramework();
        if (!gGetPID) { completion(nil, nil); return; }
        gGetPID(dispatch_get_main_queue(), ^(int pid) {
            NSRunningApplication *app =
                [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
            if (!app) { completion(nil, nil); return; }
            completion(app.bundleIdentifier, app.localizedName);
        });
    });
}

+ (void)getNowPlayingState:(void (^)(NSDictionary *, NSString *, NSString *))completion {
    // One main-queue hop; one FindActivePlayer() call. The call is served
    // from the TTL cache if we ran it recently, so a fresh `getState` tick
    // costs at most one full walk even though it returns both halves.
    dispatch_async(dispatch_get_main_queue(), ^{
        PlayerConfig *p = FindActivePlayer();
        if (p) {
            NSMutableDictionary *out = [NSMutableDictionary new];
            if (NSString *v = [p title])    out[@"title"]    = v;
            if (NSString *v = [p artist])   out[@"artist"]   = v;
            if (NSString *v = [p album])    out[@"album"]    = v;
            if (NSNumber *v = [p duration]) out[@"duration"] = v;
            if (NSNumber *v = [p elapsed])  out[@"elapsed"]  = v;
            if (p.name.length)              out[@"source"]   = p.name;
            completion(out.count ? out : nil, p.bundleId, p.name);
            return;
        }

        // Legacy fallback: private-framework path. We need two calls here
        // because the old API is also split into info + PID; the MR 12–14
        // path is untouched from the separate handlers above.
        MRLoadFramework();
        if (!gGetInfo && !gGetPID) { completion(nil, nil, nil); return; }

        // Grab PID first so the displayName is available regardless of
        // whether getInfo returns metadata.
        if (gGetPID) {
            gGetPID(dispatch_get_main_queue(), ^(int pid) {
                NSRunningApplication *app = (pid > 0)
                    ? [NSRunningApplication runningApplicationWithProcessIdentifier:pid]
                    : nil;
                NSString *bid  = app.bundleIdentifier;
                NSString *name = app.localizedName;
                if (!gGetInfo) { completion(nil, bid, name); return; }
                gGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
                    if (!raw) { completion(nil, bid, name); return; }
                    NSDictionary *src = (__bridge NSDictionary *)raw;
                    NSMutableDictionary *out = [NSMutableDictionary new];
                    if (id v = src[kTitle])    out[@"title"]    = v;
                    if (id v = src[kArtist])   out[@"artist"]   = v;
                    if (id v = src[kAlbum])    out[@"album"]    = v;
                    if (id v = src[kDuration]) out[@"duration"] = v;
                    if (id v = src[kElapsed])  out[@"elapsed"]  = v;
                    completion(out.count ? out : nil, bid, name);
                });
            });
        } else {
            gGetInfo(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
                if (!raw) { completion(nil, nil, nil); return; }
                NSDictionary *src = (__bridge NSDictionary *)raw;
                NSMutableDictionary *out = [NSMutableDictionary new];
                if (id v = src[kTitle])    out[@"title"]    = v;
                if (id v = src[kArtist])   out[@"artist"]   = v;
                if (id v = src[kAlbum])    out[@"album"]    = v;
                if (id v = src[kDuration]) out[@"duration"] = v;
                if (id v = src[kElapsed])  out[@"elapsed"]  = v;
                completion(out.count ? out : nil, nil, nil);
            });
        }
    });
}

@end
