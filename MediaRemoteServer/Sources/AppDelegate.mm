//
//  AppDelegate.mm
//

#import "AppDelegate.h"
#import "SocketServer.h"
#import "MediaRemote.h"
#import "PlayerConfig.h"
#import "VolumeControl.h"

// Socket path layout (see SECURITY_REVIEW.md Server M-1 / L-1):
//
//   ~/.media-remote/            <- 0700 directory owned by the user
//   ~/.media-remote/sock        <- 0600 Unix domain socket
//
// Having the socket live *inside* an owner-only directory matters
// because:
//   • The parent dir's perms gate any stat/connect attempt, so a local
//     attacker can't probe the socket even during the small window
//     between bind() and chmod().
//   • `stop` can safely `unlink` a fixed path — the attacker would have
//     had to win a rename race inside a dir they can't write to.
static NSString *DefaultSocketDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".media-remote"];
}
static NSString *DefaultSocketPath(void) {
    return [DefaultSocketDir() stringByAppendingPathComponent:@"sock"];
}

@interface AppDelegate ()
@property (nonatomic, strong) NSStatusItem  *statusItem;
@property (nonatomic, strong) SocketServer  *server;
// Menu item we rewrite as "N clients connected" / "No clients connected"
// so the user can see at a glance whether the phone is talking to us.
@property (nonatomic, strong) NSMenuItem    *clientsItem;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    [self installStatusItem];

    // Resolve socket path. Allow override via env var for testing.
    NSString *path = NSProcessInfo.processInfo.environment[@"MEDIA_REMOTE_SOCKET"]
                     ?: DefaultSocketPath();
    self.server = [[SocketServer alloc] initWithSocketPath:path];
    NSError *err = nil;
    if (![self.server start:&err]) {
        NSLog(@"[AppDelegate] failed to start server: %@", err);
        NSAlert *a = [NSAlert new];
        a.messageText = @"Media Remote Server failed to start";
        a.informativeText = err.localizedDescription ?: @"Unknown error";
        [a runModal];
        [NSApp terminate:nil];
        return;
    }

    // Light up the menu-bar icon whenever a remote is connected. The
    // callback runs on the main queue (SocketServer guarantees that),
    // so it's safe to touch AppKit directly.
    __weak AppDelegate *weakSelf = self;
    self.server.onClientCountChanged = ^(NSInteger count) {
        [weakSelf refreshStatusForClientCount:count];
    };
    [self refreshStatusForClientCount:0];

    NSLog(@"[AppDelegate] MediaRemote private framework: %@",
          [MediaRemote isAvailable] ? @"yes" : @"no (transport uses HID fallback)");
    NSArray *players = [PlayerConfig load];
    NSLog(@"[AppDelegate] AppleScript players: %lu loaded from %@",
          (unsigned long)players.count,
          [PlayerConfig activeConfigPath] ?: @"(none)");
}

- (void)applicationWillTerminate:(NSNotification *)n {
    [self.server stop];
}

// ----- status bar UI -------------------------------------------------------

- (void)installStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar
        statusItemWithLength:NSVariableStatusItemLength];

    NSImage *img = [NSImage imageWithSystemSymbolName:@"dot.radiowaves.left.and.right"
                             accessibilityDescription:@"Media Remote"];
    // Note: `.template = YES` doesn't parse in Obj-C++ because `template`
    // is a C++ reserved word. Use the setter instead.
    [img setTemplate:YES];
    self.statusItem.button.image = img;
    // Empty title by default; `refreshStatusForClientCount:` toggles a
    // leading "●" dot when a remote is connected.
    // self.statusItem.button.title = @"";

    NSMenu *menu = [NSMenu new];

    NSMenuItem *status = [[NSMenuItem alloc]
        initWithTitle:@"Media Remote Server" action:nil keyEquivalent:@""];
    status.enabled = NO;
    [menu addItem:status];

    self.clientsItem = [[NSMenuItem alloc]
        initWithTitle:@"No clients connected" action:nil keyEquivalent:@""];
    self.clientsItem.enabled = NO;
    [menu addItem:self.clientsItem];

    NSMenuItem *pathItem = [[NSMenuItem alloc]
        initWithTitle:[NSString stringWithFormat:@"Socket: %@",
                       DefaultSocketPath()]
               action:nil keyEquivalent:@""];
    pathItem.enabled = NO;
    [menu addItem:pathItem];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Copy socket path"
                    action:@selector(copySocketPath:)
             keyEquivalent:@"c"].target = self;

    [menu addItemWithTitle:@"Test: toggle play/pause"
                    action:@selector(testPlayPause:)
             keyEquivalent:@""].target = self;

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Quit"
                    action:@selector(terminate:)
             keyEquivalent:@"q"];

    self.statusItem.menu = menu;
}

- (void)copySocketPath:(id)sender {
    NSPasteboard *pb = NSPasteboard.generalPasteboard;
    [pb clearContents];
    [pb setString:DefaultSocketPath() forType:NSPasteboardTypeString];
}

- (void)testPlayPause:(id)sender {
    [MediaRemote sendCommand:MRCommandTogglePlayPause];
}

// Updates the status item UI to reflect the current connected-client
// count. Called from SocketServer's callback (on the main queue) every
// time a client connects or disconnects.
//
// We take a two-pronged approach: a small "●" prefix on the status
// button title gives a glance-visible indicator, and the first menu
// item gets a human-readable count so the user can confirm details
// without opening Console.
- (void)refreshStatusForClientCount:(NSInteger)count {
    if (count > 0) {
        // self.statusItem.button.title = @" ●";
        self.clientsItem.title = (count == 1)
            ? @"1 client connected"
            : [NSString stringWithFormat:@"%ld clients connected", (long)count];
    } else {
        // self.statusItem.button.title = @"";
        self.clientsItem.title = @"No clients connected";
    }
}

@end
