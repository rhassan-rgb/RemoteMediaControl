//
//  PlayerConfig.h
//  MediaRemoteServer
//
//  List of AppleScript-driven media players the server knows about, and
//  runtime helpers for querying them.
//
//  Security note: the script bodies are compiled into the binary — they
//  are NOT read from disk. Reading user-owned config would effectively
//  let anything with unprivileged write-as-user leverage the server's
//  Accessibility + Automation TCC grants to run arbitrary AppleScript.
//  See SECURITY_REVIEW.md Server M-2.
//
//  To add a player, edit the table in PlayerConfig.mm and rebuild.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PlayerConfig : NSObject

// Human-readable display name, e.g. "Music".
@property (nonatomic, copy, readonly) NSString *name;
// macOS bundle identifier, e.g. "com.apple.Music". Used to skip apps
// that aren't running without invoking AppleScript.
@property (nonatomic, copy, readonly) NSString *bundleId;

/// Returns the built-in list of supported players. Never nil; order
/// matches the search order for "currently playing".
+ (NSArray<PlayerConfig *> *)load;

/// Describes where the configuration lives (for logging only).
+ (NSString *)activeConfigPath;

/// YES if the app with our bundleId is currently in
/// NSWorkspace.runningApplications. Cheap; no AppleScript.
- (BOOL)isRunning;

/// Runs the built-in isPlaying script and returns YES iff it returned
/// the literal string "1". All other outcomes (nil, errors, wrong
/// values) are NO. Must be called from the main thread.
- (BOOL)isPlaying;

/// Convenience wrappers around the metadata scripts. Return nil if the
/// script is empty, errored, or produced an empty result.
- (nullable NSString *)title;
- (nullable NSString *)artist;
- (nullable NSString *)album;
- (nullable NSNumber *)duration;
- (nullable NSNumber *)elapsed;

@end

NS_ASSUME_NONNULL_END
