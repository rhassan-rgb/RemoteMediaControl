//
//  SocketServer.mm
//

#import "SocketServer.h"
#import "CommandHandler.h"

#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>

// Verbose tracing. Controlled by the Makefile's DEBUG=1 flag; defaults
// to off in release builds so we don't leave a chatty log behind.
#ifndef MR_TRACE
#define MR_TRACE 0
#endif
#if MR_TRACE
#  define MR_LOG(fmt, ...) NSLog(@"[MR] " fmt, ##__VA_ARGS__)
#else
#  define MR_LOG(...) do {} while (0)
#endif

// --- Limits ----------------------------------------------------------------
//
// We speak a line-based protocol; a well-behaved client sends a command
// and waits for the reply. These limits exist to contain a buggy or
// hostile local client that has somehow made it past the unix-perm
// gate — they stop us from allocating without bound (kMaxLineBytes) and
// from tying up a server slot forever (kIdleTimeoutSeconds).
//
// 8 KiB is >100x the largest real command we generate (a handful of
// bytes plus maybe a track title echoed back), and still small enough
// that an attacker can't exhaust RAM across many connections.
static const NSUInteger kMaxLineBytes        = 8 * 1024;
// 30s with no bytes sent/received closes the connection. A real remote
// session sends commands within a couple of seconds of being opened.
static const NSTimeInterval kIdleTimeoutSecs = 30.0;

@interface SocketServer () {
    int _listenFd;
    dispatch_source_t _listenSource;
    dispatch_queue_t _queue;
    NSInteger _connectedClients;
    // GCD sources must be retained for their entire lifetime. Local vars
    // get dropped by ARC at the end of the method, so client sources go
    // in here and are removed only when the source is cancelled.
    NSMutableSet<dispatch_source_t> *_clientSources;
}
@end

@implementation SocketServer

- (instancetype)initWithSocketPath:(NSString *)path {
    if ((self = [super init])) {
        _socketPath = [path copy];
        _listenFd = -1;
        _queue = dispatch_queue_create("com.ragab.mediaremote.socket",
                                       DISPATCH_QUEUE_SERIAL);
        _clientSources = [NSMutableSet new];
    }
    return self;
}

- (NSInteger)connectedClients {
    @synchronized (self) { return _connectedClients; }
}

- (void)setConnectedDelta:(NSInteger)delta {
    NSInteger nowConnected;
    @synchronized (self) {
        _connectedClients += delta;
        nowConnected = _connectedClients;
    }
    // Fire the callback on the main queue so the app delegate can
    // touch AppKit state (the status item button) without extra
    // thread-hopping on its end.
    void (^cb)(NSInteger) = self.onClientCountChanged;
    if (cb) {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(nowConnected);
        });
    }
}

// ---------------------------------------------------------------------------

- (BOOL)start:(NSError **)errorOut {
    // We can't use `goto` here because Obj-C++ forbids jumping past C++
    // variable initialisations. A little lambda keeps the cleanup
    // localised and avoids the gotos entirely.
    auto fail = [errorOut]() -> BOOL {
        if (errorOut) *errorOut = [NSError errorWithDomain:NSPOSIXErrorDomain
                                                      code:errno
                                                  userInfo:nil];
        return NO;
    };

    const char *path = _socketPath.fileSystemRepresentation;
    if (strlen(path) >= sizeof(((struct sockaddr_un *)0)->sun_path)) {
        errno = ENAMETOOLONG;
        return fail();
    }

    // Ensure the parent directory exists and is 0700. We *don't* trust
    // whatever may already be at that path if it's not a plain directory
    // owned by us with the right mode — bail rather than silently widen
    // the permissions (see SECURITY_REVIEW.md Server M-1).
    NSString *dir = [_socketPath stringByDeletingLastPathComponent];
    if (dir.length > 0) {
        const char *cdir = dir.fileSystemRepresentation;
        struct stat st = {};
        if (lstat(cdir, &st) == 0) {
            if (!S_ISDIR(st.st_mode)) {
                errno = ENOTDIR;
                return fail();
            }
            if (st.st_uid != geteuid()) {
                errno = EPERM;
                return fail();
            }
            if ((st.st_mode & 0777) != 0700) {
                // Tighten a too-loose directory we own; anything else is
                // a setup bug worth surfacing.
                if (chmod(cdir, 0700) != 0) return fail();
            }
        } else if (errno == ENOENT) {
            if (mkdir(cdir, 0700) != 0) return fail();
        } else {
            return fail();
        }
    }

    // Remove any stale socket file from a previous run — but only if
    // it's actually a socket. We don't want a symlink planted by another
    // user to redirect our unlink() somewhere interesting.
    {
        struct stat sst = {};
        if (lstat(path, &sst) == 0 && S_ISSOCK(sst.st_mode)) {
            unlink(path);
        }
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return fail();

    // Non-blocking + close-on-exec.
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path, sizeof(addr.sun_path) - 1);

    // Tighten umask around bind() so the socket is created 0600 from
    // the outset. chmod()-after-bind has a (tiny) race window where
    // another local process could connect() with default perms. Restore
    // the previous umask immediately afterwards. (Server M-1.)
    mode_t oldMask = umask(0177);
    int bindRc = bind(fd, (struct sockaddr *)&addr, SUN_LEN(&addr));
    int bindErr = errno;
    umask(oldMask);
    if (bindRc < 0) {
        close(fd); errno = bindErr;
        return fail();
    }
    // Belt-and-braces: enforce the mode even if umask was ignored for
    // some reason (e.g. the path is on a filesystem that does its own
    // thing with permissions).
    chmod(path, S_IRUSR | S_IWUSR);

    if (listen(fd, 8) < 0) {
        int e = errno; close(fd); unlink(path); errno = e;
        return fail();
    }
    _listenFd = fd;

    _listenSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ,
                                           (uintptr_t)fd, 0, _queue);
    __weak SocketServer *weakSelf = self;
    dispatch_source_set_event_handler(_listenSource, ^{
        [weakSelf acceptConnection];
    });
    dispatch_resume(_listenSource);

    MR_LOG(@"listening on %@ (fd=%d)", _socketPath, fd);
    return YES;
}

- (void)stop {
    if (_listenSource) {
        dispatch_source_cancel(_listenSource);
        _listenSource = nil;
    }
    if (_listenFd >= 0) {
        close(_listenFd);
        _listenFd = -1;
    }
    // Only remove the file if it's still *our* socket — i.e. a socket
    // node. If someone swapped it for a regular file or symlink we'd
    // rather leak the entry than unlink arbitrary state. (L-1.)
    const char *p = _socketPath.fileSystemRepresentation;
    struct stat sst = {};
    if (lstat(p, &sst) == 0 && S_ISSOCK(sst.st_mode)) {
        unlink(p);
    }
}

// ---------------------------------------------------------------------------

- (void)acceptConnection {
    while (YES) {
        int cfd = accept(_listenFd, NULL, NULL);
        if (cfd < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) break;
            // Not MR_LOG: accept() failure on a listening socket is a
            // rare and genuinely worrying event — surface it in Console
            // even in release builds. MR_TRACE gets the chatty per-line
            // stuff; this gets the pager-worthy ones.
            NSLog(@"[MR] accept() failed on %@: %s",
                  _socketPath, strerror(errno));
            break;
        }
        int flags = fcntl(cfd, F_GETFL, 0);
        fcntl(cfd, F_SETFL, flags | O_NONBLOCK);
        [self setConnectedDelta:+1];
        MR_LOG(@"accepted fd=%d (total clients=%ld)",
               cfd, (long)self.connectedClients);
        [self serviceClient:cfd];
    }
}

// Service a single client on its own read dispatch_source, buffering until
// we see a newline, then handling the line.
- (void)serviceClient:(int)fd {
    NSMutableData *buffer = [NSMutableData data];
    dispatch_source_t src = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, (uintptr_t)fd, 0, _queue);

    // Per-client idle timer. Each time we make progress (reading bytes
    // or writing a reply) we bump its next-fire forward; if it fires we
    // cancel the read source and close. See kIdleTimeoutSecs.
    dispatch_source_t idleTimer = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);

    // Retain the sources so they aren't deallocated the moment this
    // method returns; removed in the cancel handler.
    NSMutableSet<dispatch_source_t> *sources = _clientSources;
    @synchronized (sources) {
        [sources addObject:src];
        [sources addObject:idleTimer];
    }

    __weak SocketServer *weakSelf = self;
    dispatch_queue_t q = _queue;
    // Strong ref captured by the blocks so the source stays alive while
    // events are pending. Nil'd in the cancel handler to break the cycle.
    __block dispatch_source_t strongSrc   = src;
    __block dispatch_source_t strongTimer = idleTimer;
    __block __weak dispatch_source_t weakSrc = src;

    // These two __block vars are *only ever touched on `q`* — the socket's
    // serial queue — so no extra locking is needed. They coordinate the
    // read-EOF vs write-reply race:
    //
    //   • `peerClosed` = we've seen the client's FIN on the read side
    //   • `pending`    = number of command-replies still in flight
    //
    // We may only tear the fd down once `peerClosed && pending == 0`.
    __block BOOL peerClosed = NO;
    __block NSInteger pending = 0;

    // Helper: bump the idle timer forward. Runs on q, so the timer and
    // its deadline are touched in the same serial context.
    void (^bumpIdle)(void) = ^{
        dispatch_source_set_timer(
            strongTimer,
            dispatch_time(DISPATCH_TIME_NOW,
                          (int64_t)(kIdleTimeoutSecs * NSEC_PER_SEC)),
            DISPATCH_TIME_FOREVER,
            (uint64_t)(0.25 * NSEC_PER_SEC));
    };

    dispatch_source_set_event_handler(idleTimer, ^{
        // Always log idle closes. Under normal use a client that wants
        // to stay open polls at a few-second interval, so landing on
        // this branch means either the client forgot to poll or the
        // network dropped the connection without a TCP reset — useful
        // to see in release builds.
        NSLog(@"[MR] fd=%d idle timeout after %.0fs, closing",
              fd, kIdleTimeoutSecs);
        [weakSelf closeClient:fd source:weakSrc];
    });
    bumpIdle();
    dispatch_resume(idleTimer);

    dispatch_source_set_event_handler(src, ^{
        // Once we've seen EOF from the peer, the source will keep firing
        // forever (read-EOF is always "readable") until we cancel — which
        // we defer until any pending replies have been written. Skip
        // those interim firings cheaply.
        if (peerClosed) return;

        char tmp[1024];
        ssize_t n = read(fd, tmp, sizeof(tmp));
        if (n < 0) {
            if (errno == EAGAIN) { MR_LOG(@"fd=%d read EAGAIN", fd); return; }
            MR_LOG(@"fd=%d read error: %s", fd, strerror(errno));
            [weakSelf closeClient:fd source:weakSrc];
            return;
        }
        if (n == 0) {
            MR_LOG(@"fd=%d EOF from peer (pending=%ld)",
                   fd, (long)pending);
            peerClosed = YES;
            if (pending == 0) {
                [weakSelf closeClient:fd source:weakSrc];
            }
            return;
        }
        MR_LOG(@"fd=%d read %zd bytes", fd, n);
        [buffer appendBytes:tmp length:n];
        bumpIdle();

        // Guard against an uncooperative client that never sends a
        // newline: once the unparsed buffer exceeds our cap, drop the
        // connection rather than grow forever. (SECURITY_REVIEW M-3.)
        if (buffer.length > kMaxLineBytes) {
            // Always log oversize drops. Well-behaved clients never hit
            // this; if it trips we want to know about it in release.
            NSLog(@"[MR] fd=%d oversized line (%lu bytes > cap %lu), closing",
                  fd, (unsigned long)buffer.length,
                  (unsigned long)kMaxLineBytes);
            [weakSelf closeClient:fd source:weakSrc];
            return;
        }

        // Consume any complete lines we have.
        while (true) {
            const char *bytes = (const char *)buffer.bytes;
            NSUInteger len = buffer.length;
            NSUInteger nlIdx = NSNotFound;
            for (NSUInteger i = 0; i < len; ++i) {
                if (bytes[i] == '\n') { nlIdx = i; break; }
            }
            if (nlIdx == NSNotFound) break;

            NSData *lineData = [buffer subdataWithRange:NSMakeRange(0, nlIdx)];
            [buffer replaceBytesInRange:NSMakeRange(0, nlIdx + 1)
                              withBytes:NULL
                                 length:0];

            NSString *line = [[NSString alloc] initWithData:lineData
                                                   encoding:NSUTF8StringEncoding];
            if (!line) line = @"";
            MR_LOG(@"fd=%d line=<<%@>>", fd, line);

            pending += 1;
            MR_LOG(@"fd=%d dispatching to CommandHandler", fd);
            // Run handlers on the socket's serial queue. The only
            // commands that genuinely require the main thread are
            // AppleScript-bearing ones (getSong/getPlayer/getState),
            // and MediaRemote does its own `dispatch_async(main)` hop
            // internally for those. Everything else (transport,
            // volume, ping) is happy off main, so we avoid stalling
            // fast commands behind a slow AppleScript.
            [CommandHandler handleLine:line
                            completion:^(NSString *reply, BOOL closeIt) {
                MR_LOG(@"fd=%d reply=<<%@>> closeIt=%d",
                       fd, reply, (int)closeIt);
                NSString *out = [reply stringByAppendingString:@"\n"];
                NSData *data  = [out dataUsingEncoding:NSUTF8StringEncoding];

                // Hop back to the socket queue so the write and any
                // potential close all serialize with reads + the
                // cancel handler. Non-AppleScript replies are already
                // on `q` and this is effectively a no-op; AppleScript
                // replies come in on main and need the hop.
                dispatch_async(q, ^{
                    const char *b = (const char *)data.bytes;
                    size_t blen   = data.length;
                    size_t sent   = 0;
                    while (sent < blen) {
                        ssize_t w = write(fd, b + sent, blen - sent);
                        if (w < 0) {
                            if (errno == EAGAIN) continue;
                            MR_LOG(@"fd=%d write error: %s",
                                   fd, strerror(errno));
                            break;
                        }
                        sent += (size_t)w;
                    }
                    MR_LOG(@"fd=%d wrote %zu/%zu bytes",
                           fd, sent, blen);
                    bumpIdle();

                    // We used to `shutdown(fd, SHUT_WR)` after every
                    // reply so macOS's built-in `nc -U` would exit
                    // promptly. That forced the client into a
                    // one-command-per-connection pattern, which is
                    // expensive for polling. Now we keep the write
                    // half open and let the client drive the session
                    // lifecycle — multiple commands per connection,
                    // close on explicit `quit`, idle timeout, or
                    // peer EOF. `nc -U` still exits cleanly when the
                    // client closes its own stdin (common cases:
                    // `echo cmd | nc -U`, or stdin redirected from
                    // `/dev/null`), so single-shot callers are
                    // unaffected.
                    pending -= 1;
                    if (closeIt || (peerClosed && pending == 0)) {
                        [weakSelf closeClient:fd source:weakSrc];
                    }
                });
            }];
        }
    });

    dispatch_source_set_cancel_handler(src, ^{
        MR_LOG(@"fd=%d cancel handler, closing", fd);
        close(fd);
        // Tear down the idle timer alongside the read source, otherwise
        // it'd keep firing against a closed fd for the next 30 seconds.
        if (strongTimer) {
            dispatch_source_cancel(strongTimer);
        }
        @synchronized (sources) {
            if (strongSrc)   [sources removeObject:strongSrc];
            if (strongTimer) [sources removeObject:strongTimer];
        }
        strongSrc   = nil;   // break the strong cycle
        strongTimer = nil;
    });
    dispatch_resume(src);
    MR_LOG(@"fd=%d read source resumed", fd);
}

- (void)closeClient:(int)fd source:(dispatch_source_t)src {
    if (src) dispatch_source_cancel(src);
    [self setConnectedDelta:-1];
}

@end
