//
//  SocketServer.h
//  MediaRemoteServer
//
//  A tiny line-based server on a Unix domain socket. Each accepted connection
//  is serviced by a GCD dispatch_source; each complete line (\n or \r\n) is
//  fed to CommandHandler.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SocketServer : NSObject

/// Absolute filesystem path of the socket (expanded). The default set
/// by AppDelegate is ~/.media-remote/sock — the socket lives inside a
/// 0700 directory so local-user isolation doesn't depend on winning a
/// race between bind() and chmod(). See SECURITY_REVIEW.md Server M-1.
@property (nonatomic, copy, readonly) NSString *socketPath;

/// Number of currently-connected clients.
@property (nonatomic, readonly) NSInteger connectedClients;

/// Invoked on the main queue whenever `connectedClients` changes. Used by
/// the app delegate to refresh the menu-bar status item; nil by default.
@property (nonatomic, copy, nullable)
    void (^onClientCountChanged)(NSInteger count);

- (instancetype)initWithSocketPath:(NSString *)path;

/// Starts listening. Returns NO on failure; `error` is populated with errno.
- (BOOL)start:(NSError **)error;

/// Stop accepting new connections, close existing ones, unlink the socket file.
- (void)stop;

@end

NS_ASSUME_NONNULL_END
