//
//  CommandHandler.h
//  MediaRemoteServer
//
//  Parses a single line of text (as received over the socket) and dispatches
//  it to the underlying MediaRemote / VolumeControl helpers. Returns the reply
//  string that should be written back to the client.
//
//  Wire protocol (newline-delimited, ASCII):
//      Request : <cmd>[ <arg>]\n
//      Response: OK[ <payload>]\n
//                ERR <reason>\n
//
//  Supported commands:
//      playpause                 -> OK
//      next                      -> OK
//      previous                  -> OK
//      setVol <0.0-1.0|0-100>    -> OK
//      getVol                    -> OK <0.0-1.0>
//      getSong                   -> OK <json>   (or: ERR no_song)
//      getPlayer                 -> OK <bundleId> <displayName>   (or ERR none)
//      ping                      -> OK pong
//      quit                      -> (closes connection, returns OK bye)
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CommandHandler : NSObject

/// Parse `line` and produce a single-line reply (without trailing newline).
/// `completion` is always invoked on the main queue exactly once.
+ (void)handleLine:(NSString *)line
        completion:(void (^)(NSString *reply, BOOL closeConnection))completion;

@end

NS_ASSUME_NONNULL_END
