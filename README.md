# Media Remote

A two-part project that turns your iPhone into a multimedia remote for a
MacBook.

```
┌──────────────────┐    SSH     ┌───────────────────┐
│  MediaRemoteApp  │───────────▶│  sshd on the Mac  │
│   (iOS, Swift)   │            └─────────┬─────────┘
└──────────────────┘                      │ spawns
                                          ▼
                              nc -U ~/.media-remote/sock
                                          │
                                          ▼
                        ┌───────────────────────────────┐
                        │   MediaRemoteServer.app       │
                        │   menu-bar, Objective-C++     │
                        │                               │
                        │   • MediaRemote.framework     │
                        │   • CoreAudio volume I/O      │
                        └───────────────────────────────┘
```

- **`MediaRemoteServer/`** — a macOS menu-bar app written in Objective-C++
  that listens on a Unix domain socket and dispatches commands to the
  system's now-playing app (via the private `MediaRemote.framework`) and to
  CoreAudio for volume.
- **`MediaRemoteApp/`** — an iOS SwiftUI app that stores one or more remote
  devices, opens an SSH connection to the selected Mac, and forwards each
  UI action as a short command over that SSH session.

## Why SSH + Unix socket?

The server socket lives inside an owner-only (`0700`) directory at
`~/.media-remote/`, and is itself mode `0600`. The enclosing directory
means nothing outside the owning user's processes can even see or
connect() to the socket; nothing on the LAN can reach it directly. The
iOS app authenticates over SSH with an **Ed25519 key** — password auth
is no longer supported — and verifies the Mac's host key on first use
(TOFU), pinning it thereafter. On the Mac side, any logged-in terminal
session with the same user can test the server by piping commands
through `nc`.

## Wire protocol

Line-oriented ASCII; one command per line, one reply per line.

    Request :  <cmd>[ <arg>]\n
    Reply   :  OK[ <payload>]\n
               ERR <reason>\n

| Command       | Argument       | Reply                                                                 |
|---------------|----------------|-----------------------------------------------------------------------|
| `playpause`   |                | `OK`                                                                  |
| `play`        |                | `OK`                                                                  |
| `pause`       |                | `OK`                                                                  |
| `next`        |                | `OK`                                                                  |
| `previous`    |                | `OK`                                                                  |
| `getVol`      |                | `OK 0.47`                                                             |
| `setVol`      | `0.0–1.0` or `0-100` | `OK`                                                           |
| `mute`/`unmute` |              | `OK`                                                                  |
| `getSong`     |                | `OK {"title":"…","artist":"…","album":"…","duration":…,"elapsed":…}`  |
| `getPlayer`   |                | `OK {"bundleId":"com.apple.Music","displayName":"Music"}`             |
| `getState`    |                | `OK {"vol":0.47,"song":{…},"player":{…}}` (combined snapshot)         |
| `ping`        |                | `OK pong`                                                             |
| `quit`        |                | `OK bye` (server closes the connection)                               |

`getState` is the endpoint the iOS app polls each tick — it collapses
what used to be three separate round-trips (`getVol` + `getSong` +
`getPlayer`) into one reply, so each poll opens a single SSH channel
instead of three. The `song` and `player` keys are `null` when nothing
is playing.

You can test any of these by hand once the server is running:

    ssh macbook.local "printf 'getState\nquit\n' | nc -U ~/.media-remote/sock"

The server keeps each connection open until it receives `quit`, the
peer closes, or the 30-second idle timer fires — so if you just
`echo ping | nc -U …` without a trailing `quit`, `nc` will sit there
until the idle timeout rather than exiting immediately. For one-shot
scripting, always terminate the session with `quit`.

## Getting started

1. **Build the Mac server** — see [`MediaRemoteServer/README.md`](MediaRemoteServer/README.md).
2. **Enable Remote Login** on the Mac (System Settings → General → Sharing
   → Remote Login).
3. **Build the iOS app** — see [`MediaRemoteApp/README.md`](MediaRemoteApp/README.md).
4. Launch the app, tap `+`, and add your Mac: hostname/IP, SSH user, and
   an Ed25519 private key. The first connection pins the Mac's host
   key; subsequent connections will refuse to proceed if it changes.

## Known issues / caveats

- **macOS 15.4+ (Sequoia)** removed the private MediaRemote symbols
  this server originally relied on:
    - `MRMediaRemoteSendCommand` — transport commands fall back to
      posting HID media-key events through `CGEventPost`, which needs
      **Accessibility** permission (*System Settings → Privacy &
      Security → Accessibility*).
    - `MRMediaRemoteGetNowPlayingInfo` /
      `MRMediaRemoteGetNowPlayingApplicationPID` — `getSong` and
      `getPlayer` now drive known apps (Music, QuickTime Player, VLC)
      via AppleScript instead. macOS will prompt for **Automation**
      permission per app on first use. The player table is compiled
      into the binary; to add a player, edit `Sources/PlayerConfig.mm`
      and rebuild. (Previously this was read from a YAML file on disk —
      that file was removed because a user-writable config would let
      any process with unprivileged write-as-user access leverage the
      server's TCC grants to run arbitrary AppleScript.)
- **Host key verification** on first connection is TOFU (trust on
  first use) — the iOS app pins the SHA-256 fingerprint and will
  refuse to connect if it changes. "Forget" a device in the app to
  clear a pinned key.
- This is a personal/hobby project. Do not ship it to the App Store — it
  relies on a private Apple framework and will be rejected.
