//
//  CommandHandler.mm
//

#import "CommandHandler.h"
#import "MediaRemote.h"
#import "VolumeControl.h"

#import <math.h>

#ifndef MR_TRACE
#define MR_TRACE 0
#endif
#if MR_TRACE
#  define MR_LOG(fmt, ...) NSLog(@"[MR/cmd] " fmt, ##__VA_ARGS__)
#else
#  define MR_LOG(...) do {} while (0)
#endif

static NSString *Escape(NSString *_Nullable s) {
    if (!s) return @"";
    NSData *d = [NSJSONSerialization dataWithJSONObject:s ?: @""
                                                options:NSJSONWritingFragmentsAllowed
                                                  error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

@implementation CommandHandler

+ (void)handleLine:(NSString *)rawLine
        completion:(void (^)(NSString *, BOOL))completion {

    NSString *line = [rawLine stringByTrimmingCharactersInSet:
                      NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (line.length == 0) {
        completion(@"ERR empty", NO);
        return;
    }

    // Split on the first whitespace: [cmd] [argString]
    NSRange sp = [line rangeOfCharacterFromSet:
                  NSCharacterSet.whitespaceCharacterSet];
    NSString *cmd = (sp.location == NSNotFound)
        ? line
        : [line substringToIndex:sp.location];
    NSString *arg = (sp.location == NSNotFound)
        ? @""
        : [[line substringFromIndex:NSMaxRange(sp)]
              stringByTrimmingCharactersInSet:
              NSCharacterSet.whitespaceCharacterSet];

    NSString *lc = cmd.lowercaseString;
    MR_LOG(@"cmd=%@ arg=%@", lc, arg);

    // ---- transport -------------------------------------------------------
    if ([lc isEqualToString:@"playpause"]) {
        BOOL ok = [MediaRemote sendCommand:MRCommandTogglePlayPause];
        completion(ok ? @"OK" : @"ERR media_remote_unavailable", NO);
        return;
    }
    if ([lc isEqualToString:@"play"]) {
        completion([MediaRemote sendCommand:MRCommandPlay] ? @"OK" : @"ERR", NO);
        return;
    }
    if ([lc isEqualToString:@"pause"]) {
        completion([MediaRemote sendCommand:MRCommandPause] ? @"OK" : @"ERR", NO);
        return;
    }
    if ([lc isEqualToString:@"next"]) {
        completion([MediaRemote sendCommand:MRCommandNextTrack] ? @"OK" : @"ERR", NO);
        return;
    }
    if ([lc isEqualToString:@"previous"] || [lc isEqualToString:@"prev"]) {
        completion([MediaRemote sendCommand:MRCommandPreviousTrack] ? @"OK" : @"ERR", NO);
        return;
    }

    // ---- volume ----------------------------------------------------------
    if ([lc isEqualToString:@"getvol"]) {
        float v = [VolumeControl getVolume];
        if (v < 0) { completion(@"ERR volume_unavailable", NO); return; }
        completion([NSString stringWithFormat:@"OK %.3f", v], NO);
        return;
    }
    if ([lc isEqualToString:@"setvol"]) {
        if (arg.length == 0) {
            completion(@"ERR setvol_requires_arg", NO);
            return;
        }
        // Parse strictly. -floatValue returns 0 on garbage, which would
        // silently mute the machine — and it will happily parse "nan",
        // "inf", "1e309" etc. Use NSScanner so we can reject trailing
        // junk, then reject non-finite values explicitly (M-4).
        NSScanner *sc = [NSScanner scannerWithString:arg];
        sc.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        double parsed = 0.0;
        if (![sc scanDouble:&parsed] || !sc.isAtEnd) {
            completion(@"ERR setvol_bad_number", NO);
            return;
        }
        if (!isfinite(parsed)) {
            completion(@"ERR setvol_bad_number", NO);
            return;
        }
        // Accept 0-100 OR 0.0-1.0.
        if (parsed > 1.0) parsed /= 100.0;
        // Clamp to the legal device range; CoreAudio will otherwise
        // reject out-of-range values and we'd rather be predictable.
        if (parsed < 0.0) parsed = 0.0;
        if (parsed > 1.0) parsed = 1.0;
        BOOL ok = [VolumeControl setVolume:(float)parsed];
        completion(ok ? @"OK" : @"ERR setvol_failed", NO);
        return;
    }
    if ([lc isEqualToString:@"mute"]) {
        completion([VolumeControl setMuted:YES] ? @"OK" : @"ERR", NO);
        return;
    }
    if ([lc isEqualToString:@"unmute"]) {
        completion([VolumeControl setMuted:NO] ? @"OK" : @"ERR", NO);
        return;
    }

    // ---- now-playing metadata -------------------------------------------
    if ([lc isEqualToString:@"getsong"]) {
        [MediaRemote getNowPlayingInfo:^(NSDictionary *info) {
            if (!info) { completion(@"ERR no_song", NO); return; }
            NSError *err = nil;
            NSData *data = [NSJSONSerialization
                            dataWithJSONObject:info
                                       options:0
                                         error:&err];
            if (err || !data) { completion(@"ERR json", NO); return; }
            NSString *json = [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding];
            completion([NSString stringWithFormat:@"OK %@", json], NO);
        }];
        return;
    }

    if ([lc isEqualToString:@"getplayer"]) {
        [MediaRemote getNowPlayingApplication:^(NSString *bid, NSString *name) {
            if (!bid && !name) { completion(@"ERR none", NO); return; }
            // JSON-encode so clients can parse a consistent shape.
            NSDictionary *payload = @{
                @"bundleId"   : bid ?: @"",
                @"displayName": name ?: @"",
            };
            NSData *data = [NSJSONSerialization dataWithJSONObject:payload
                                                           options:0 error:nil];
            NSString *json = [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding];
            completion([NSString stringWithFormat:@"OK %@", json], NO);
        }];
        return;
    }

    // Combined snapshot: one reply carries volume, track, and player. This
    // is the only command the iOS client needs on the poll path, which
    // drops per-tick SSH channels from 3 to 1 and per-tick AppleScript
    // player-walks from 2 to 1 (the TTL cache inside MediaRemote makes
    // the remaining walk amortise nicely across back-to-back calls).
    //
    // Reply shape:
    //   OK {"vol": 0.47,
    //       "song": {"title":...,"artist":...,...} | null,
    //       "player": {"bundleId":"...","displayName":"..."} | null}
    if ([lc isEqualToString:@"getstate"]) {
        // Volume is cheap and CoreAudio-backed, so we can grab it up-front
        // without waiting on the main-queue AppleScript hop.
        float v = [VolumeControl getVolume];
        NSNumber *volNum = (v >= 0) ? @(v) : nil;

        [MediaRemote getNowPlayingState:^(NSDictionary *info,
                                          NSString *bid,
                                          NSString *name) {
            NSMutableDictionary *payload = [NSMutableDictionary new];
            payload[@"vol"] = volNum ?: [NSNull null];
            payload[@"song"] = info ?: (id)[NSNull null];
            if (bid || name) {
                payload[@"player"] = @{
                    @"bundleId"   : bid ?: @"",
                    @"displayName": name ?: @"",
                };
            } else {
                payload[@"player"] = [NSNull null];
            }
            NSError *err = nil;
            NSData *data = [NSJSONSerialization
                            dataWithJSONObject:payload
                                       options:0
                                         error:&err];
            if (err || !data) { completion(@"ERR json", NO); return; }
            NSString *json = [[NSString alloc] initWithData:data
                                                   encoding:NSUTF8StringEncoding];
            completion([NSString stringWithFormat:@"OK %@", json], NO);
        }];
        return;
    }

    // ---- meta ------------------------------------------------------------
    if ([lc isEqualToString:@"ping"]) {
        completion(@"OK pong", NO);
        return;
    }
    if ([lc isEqualToString:@"quit"] || [lc isEqualToString:@"bye"]) {
        completion(@"OK bye", YES);
        return;
    }
    if ([lc isEqualToString:@"help"]) {
        NSString *help = @"OK playpause|play|pause|next|previous|"
                         @"getVol|setVol <0-1>|mute|unmute|"
                         @"getSong|getPlayer|getState|ping|quit";
        completion(help, NO);
        return;
    }

    completion([NSString stringWithFormat:@"ERR unknown_command %@",
                Escape(cmd)], NO);
}

@end
