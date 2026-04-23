# MediaRemoteServer

Menu-bar-only macOS app. Listens on `~/.media-remote/sock` (socket inside
a `0700` directory, file itself `0600`) and translates line-based
commands into MediaRemote.framework calls and CoreAudio volume changes.

## Build

Requires Xcode Command Line Tools (`xcode-select --install`). No Xcode
project, no Swift Package, nothing to configure — everything goes through
the Makefile:

```sh
cd MediaRemoteServer
make            # build/MediaRemoteServer.app (release; no tracing logs)
make DEBUG=1    # same, but with verbose [MR] / [MR/cmd] / [MR/cfg] NSLog
make run        # build and launch, with logs on stdout
make install    # copy to /Applications/
make autostart  # install + a LaunchAgent that runs at login (KeepAlive)
```

If you later want to edit in Xcode, `open Sources/main.mm` and create a new
Cocoa App target pointing at the `Sources/` and `Resources/` folders.

## First-run permissions

macOS will prompt for a few permissions the first time each relevant
command is exercised.

1. **Accessibility** — needed on macOS 15.4+ where
   `MRMediaRemoteSendCommand` has been neutered. The server falls back to
   posting HID media-key events and that requires Accessibility.
   *System Settings → Privacy & Security → Accessibility → add
   `MediaRemoteServer.app`.*
2. **Automation** — required on macOS 15.4+ for `getSong` / `getPlayer`.
   The server drives Music.app (and QuickTime Player / VLC) via
   AppleScript, and macOS will prompt the first time each app is
   queried. *System Settings → Privacy & Security → Automation →
   MediaRemoteServer → check `Music`, `QuickTime Player`, `VLC`.*
   Denying Automation surfaces as `ERR no_song` / `ERR none`; to see
   the underlying AppleScript error rebuild with `make DEBUG=1` and
   look for `[MR/cfg] AppleScript error:` in the log.

Volume changes do **not** require any special permission.

## Configuring supported players

`getSong` and `getPlayer` walk a compiled-in table of AppleScript
snippets covering **Music**, **QuickTime Player**, and **VLC**. To add
or modify a player, edit the table in `Sources/PlayerConfig.mm` and
rebuild — there is no on-disk config. (Previous versions read
`~/.config/media-remote/players.yaml`; that path was removed because a
user-writable config lets anything with unprivileged write-as-user
access piggyback on the server's Accessibility + Automation TCC grants
to execute arbitrary AppleScript. See `SECURITY_REVIEW.md` M-2.)

## Testing locally

With the server running, from another shell on the Mac:

```sh
$ echo ping   | nc -U ~/.media-remote/sock
OK pong
$ echo getVol | nc -U ~/.media-remote/sock
OK 0.520
$ echo 'setVol 0.3' | nc -U ~/.media-remote/sock
OK
$ echo getSong | nc -U ~/.media-remote/sock
OK {"title":"Protection","artist":"Massive Attack","album":"Protection","duration":472.1,"elapsed":58.7}
```

The server half-closes its write side after each reply (`shutdown(SHUT_WR)`),
which macOS's built-in `nc` interprets as EOF and exits cleanly. You'll
get one command per connection; for a second command, reconnect. The
server also applies a **30-second idle timeout** per connection and
rejects any unterminated line larger than **8 KiB**.

Or from another machine, once SSH is enabled:

```sh
ssh macbook.local "echo getSong | nc -U ~/.media-remote/sock"
```

## Layout

| File                        | Purpose                                              |
|-----------------------------|------------------------------------------------------|
| `Sources/main.mm`           | NSApplication entry point                            |
| `Sources/AppDelegate.mm`    | NSStatusItem (menu-bar icon) + server lifecycle      |
| `Sources/SocketServer.mm`   | Unix domain socket + GCD I/O                         |
| `Sources/CommandHandler.mm` | Parses a line, calls into the other modules          |
| `Sources/MediaRemote.mm`    | AppleScript path (default) + dlsym wrappers for the private framework + HID fallback |
| `Sources/PlayerConfig.mm`   | Compiled-in list of AppleScript snippets per player  |
| `Sources/VolumeControl.mm`  | CoreAudio default-device volume get/set              |
| `Resources/Info.plist`      | `LSUIElement=YES` (no Dock icon)                     |
| `Makefile`                  | Build / install / autostart helpers                  |

## Autostart at login

`make autostart` creates a `~/Library/LaunchAgents/com.ragab.MediaRemoteServer.plist`
that keeps the server alive and relaunches it at login. Logs go to
`~/Library/Logs/MediaRemoteServer.log` and `.err` (owner-only, not
world-readable like `/tmp`). Remove it with `make unautostart`.

## Overriding the socket path

Set `MEDIA_REMOTE_SOCKET` in the environment before launching:

```sh
MEDIA_REMOTE_SOCKET=$HOME/.media-remote-test/sock \
  ./build/MediaRemoteServer.app/Contents/MacOS/MediaRemoteServer
```

The server will create (or tighten) the parent directory to `0700` and
will refuse to start if the directory exists with a different owner or
wider permissions. Useful for testing multiple instances.
