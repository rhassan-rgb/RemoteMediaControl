//
//  PlayerConfig.mm
//
//  Built-in table of known media players and their AppleScript snippets.
//  Compiled in — NOT read from disk. See SECURITY_REVIEW.md Server M-2
//  for the rationale.
//

#import "PlayerConfig.h"
#import <AppKit/AppKit.h>

#ifndef MR_TRACE
#define MR_TRACE 0
#endif
#if MR_TRACE
#  define PC_LOG(fmt, ...) NSLog(@"[MR/cfg] " fmt, ##__VA_ARGS__)
#else
#  define PC_LOG(...) do {} while (0)
#endif

// -----------------------------------------------------------------------------
// AppleScript runner
// -----------------------------------------------------------------------------

static NSString *RunAppleScript(NSString *src) {
    if (src == nil || src.length == 0) return nil;
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:src];
    NSDictionary *err = nil;
    NSAppleEventDescriptor *desc = [script executeAndReturnError:&err];
    if (err) {
        // AppleScript errors are noisy on first use (Automation prompt);
        // log but don't spam on subsequent calls.
        static NSMutableSet<NSString *> *seen;
        static dispatch_once_t once;
        dispatch_once(&once, ^{ seen = [NSMutableSet new]; });
        NSString *msg = err[NSAppleScriptErrorMessage] ?: @"unknown";
        NSString *key = [NSString stringWithFormat:@"%@|%@",
                         [src substringToIndex:MIN((NSUInteger)40, src.length)],
                         msg];
        @synchronized (seen) {
            if (![seen containsObject:key]) {
                [seen addObject:key];
                PC_LOG(@"AppleScript error: %@", err);
            }
        }
        return nil;
    }
    NSString *s = desc.stringValue;
    if (s.length == 0) return nil;
    return s;
}

// -----------------------------------------------------------------------------
// PlayerConfig
// -----------------------------------------------------------------------------

@interface PlayerConfig ()
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *bundleId;
@property (nonatomic, copy, nullable) NSString *isPlayingScript;
@property (nonatomic, copy, nullable) NSString *titleScript;
@property (nonatomic, copy, nullable) NSString *artistScript;
@property (nonatomic, copy, nullable) NSString *albumScript;
@property (nonatomic, copy, nullable) NSString *durationScript;
@property (nonatomic, copy, nullable) NSString *elapsedScript;
@end

@implementation PlayerConfig

+ (NSArray<PlayerConfig *> *)load {
    static NSArray<PlayerConfig *> *built;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableArray<PlayerConfig *> *list = [NSMutableArray new];

        // -- Music --------------------------------------------------------
        {
            PlayerConfig *p     = [PlayerConfig new];
            p.name              = @"Music";
            p.bundleId          = @"com.apple.Music";
            p.isPlayingScript   = @"tell application \"Music\" to if player state is playing then return \"1\"";
            p.titleScript       = @"tell application \"Music\" to return name of current track";
            p.artistScript      = @"tell application \"Music\" to return artist of current track";
            p.albumScript       = @"tell application \"Music\" to return album of current track";
            p.durationScript    = @"tell application \"Music\" to return (duration of current track) as text";
            p.elapsedScript     = @"tell application \"Music\" to return (player position) as text";
            [list addObject:p];
        }

        // -- QuickTime Player ---------------------------------------------
        {
            PlayerConfig *p     = [PlayerConfig new];
            p.name              = @"QuickTime Player";
            p.bundleId          = @"com.apple.QuickTimePlayerX";
            p.isPlayingScript   = @"tell application \"QuickTime Player\" to if (count of documents) > 0 then if playing of front document then return \"1\"";
            p.titleScript       = @"tell application \"QuickTime Player\" to return name of front document";
            p.artistScript      = nil;
            p.albumScript       = nil;
            p.durationScript    = @"tell application \"QuickTime Player\" to return (duration of front document) as text";
            p.elapsedScript     = @"tell application \"QuickTime Player\" to return (current time of front document) as text";
            [list addObject:p];
        }

        // -- VLC ----------------------------------------------------------
        {
            PlayerConfig *p     = [PlayerConfig new];
            p.name              = @"VLC";
            p.bundleId          = @"org.videolan.vlc";
            p.isPlayingScript   = @"tell application \"VLC\" to if playing then return \"1\"";
            p.titleScript       = @"tell application \"VLC\" to return name of current item";
            p.artistScript      = nil;
            p.albumScript       = nil;
            p.durationScript    = @"tell application \"VLC\" to return (duration of current item) as text";
            p.elapsedScript     = @"tell application \"VLC\" to return (current time) as text";
            [list addObject:p];
        }

        built = [list copy];
        PC_LOG(@"loaded %lu built-in player(s)", (unsigned long)built.count);
    });
    return built;
}

+ (NSString *)activeConfigPath {
    return @"(compiled-in)";
}

- (BOOL)isRunning {
    if (self.bundleId.length == 0) return NO;
    for (NSRunningApplication *a in
         NSWorkspace.sharedWorkspace.runningApplications) {
        if ([a.bundleIdentifier isEqualToString:self.bundleId]) return YES;
    }
    return NO;
}

- (BOOL)isPlaying {
    NSString *r = RunAppleScript(self.isPlayingScript);
    return [r isEqualToString:@"1"];
}

- (NSString *)title    { return RunAppleScript(self.titleScript); }
- (NSString *)artist   { return RunAppleScript(self.artistScript); }
- (NSString *)album    { return RunAppleScript(self.albumScript); }

- (NSNumber *)duration {
    NSString *s = RunAppleScript(self.durationScript);
    if (!s) return nil;
    return @([s doubleValue]);
}
- (NSNumber *)elapsed {
    NSString *s = RunAppleScript(self.elapsedScript);
    if (!s) return nil;
    return @([s doubleValue]);
}

@end
