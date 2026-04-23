# MediaRemoteApp (iOS)

SwiftUI app for iPhone / iPad. Connects to the Mac over SSH and forwards
line commands to the `MediaRemoteServer`'s Unix socket.

## Build

Prerequisites: macOS with **Xcode 15+**, iOS 17+ on the device/simulator
(required for the `@Observable` macro).

```sh
cd MediaRemoteApp
brew install xcodegen      # one-time
xcodegen generate          # creates MediaRemoteApp.xcodeproj
open MediaRemoteApp.xcodeproj
```

Then in Xcode:

1. Select the `MediaRemoteApp` target, **Signing & Capabilities**, set your
   **Team**.
2. Build & Run on a device or the simulator. The first build resolves the
   **Citadel** SwiftPM dependency (pure-Swift SSH client); that takes a
   couple of minutes.

## Using the app

1. Make sure **Remote Login** is enabled on the Mac
   (System Settings → General → Sharing → Remote Login) so the Mac
   advertises `_ssh._tcp` on Bonjour.
2. Tap the `+` in the top-right. The **Discovered on Wi-Fi** section will
   list any Mac it can see; tap one to auto-fill Name / Host / Port. (You
   can still type those manually if the Mac is somewhere you can't
   browse, like a VPN.)
3. Fill in the **Username** (your macOS login). Authentication is
   **Ed25519 key only** — password auth was removed in this version
   (see `SECURITY_REVIEW.md` iOS H-2). Tap **Generate SSH key**: an
   Ed25519 key pair is created on-device, the 32-byte private seed
   goes into the iOS Keychain, and the public key is shown on screen.
   Tap **Copy install command**, paste it into Terminal on the Mac,
   and press return. That appends the public key to
   `~/.ssh/authorized_keys` and fixes the permissions.
4. Leave *Socket path* as `~/.media-remote/sock` unless you overrode it
   on the Mac side.
5. Tap **Save** — the app will connect, fetch the current player/track,
   and sync volume. On the **first** connection the Mac's SSH host key
   is pinned to the device's local store; subsequent connections will
   refuse if that key changes (prints `host key mismatch` with the
   expected and actual SHA-256 fingerprints).

### How private-key auth is wired up

`SSHKeyManager` generates an Ed25519 key with swift-crypto, stores the
raw private seed as base64 in the Keychain, and renders the OpenSSH
public-key line (`ssh-ed25519 AAAA… comment`). On connect,
`CitadelSSHTransport` decodes the seed back into a
`Curve25519.Signing.PrivateKey`, zeroes the intermediate `Data`
buffer, and calls `.ed25519(username:privateKey:)`. No PEM parsing,
no extra dependencies.

## Layout

```
Sources/
├── MediaRemoteApp.swift        @main entry point
├── RemoteController.swift      view-model + polling loop
├── Models/
│   ├── Device.swift            persisted device record
│   └── TrackInfo.swift         now-playing + player structs
├── Networking/
│   ├── RemoteTransport.swift   protocol + error enum
│   ├── CitadelSSHTransport.swift   concrete SSH impl
│   ├── CommandProtocol.swift   wire-format encoders/parsers
│   ├── NetworkDiscovery.swift  Bonjour browser for _ssh._tcp
│   ├── HostKeyStore.swift      TOFU host-key fingerprint pinning
│   └── SSHKeyManager.swift     Ed25519 keygen + OpenSSH formatter
├── Persistence/
│   ├── DeviceStore.swift       UserDefaults-backed device list
│   └── Keychain.swift          credential storage
└── Views/
    ├── ContentView.swift       single-screen layout
    ├── DeviceSelectorBar.swift top bar + device list sheet
    ├── AddDeviceView.swift     new-device form
    ├── NowPlayingCard.swift    track + player display
    ├── TransportControls.swift prev / play-pause / next
    └── VolumeSlider.swift      bi-directional slider
```

## Behaviour notes

- **Adaptive polling.** `RemoteController` polls the server via `getState`
  every 2 s when a player is active and 8 s when nothing is playing, so
  an idle app isn't waking the radio as often. Each tick is a single
  SSH channel that returns volume, track, and player in one payload.
- **Immediate refresh on action.** Tapping prev / play-pause / next
  kicks an extra `getState` right after the command so the UI doesn't
  wait up to 2 s for the next poll tick to reflect the change.
- **Pull-to-refresh.** Dragging the main screen down calls
  `requestRetry()` — useful after the Mac wakes from sleep, the Wi-Fi
  blips, or an SSH key was rotated.
- **Background-aware reconnect.** When the app returns to the
  foreground, the SSH transport is rebuilt automatically (iOS tears
  the socket down a few seconds after backgrounding). The
  `credentialProvider` hook lets the controller look up the right
  Keychain credential on its own without a fresh view-level
  `connect(to:credential:)`.
- **Structured connection errors.** The status pill under the device
  bar shows `Connecting…`, `Connected`, `Disconnected`, or a short
  failure label (e.g. `Auth failed`, `Host key changed`,
  `Unreachable`). Tapping it on failure surfaces the full NIO/Citadel
  error in an alert with a **Retry** action.
- **Haptics.** Subtle taptics on transport taps (light impact,
  connected-only) and on volume drag-end (selection feedback). No
  mid-drag buzz.

## Security notes

- **Host-key verification** is TOFU ("trust on first use"). The first
  successful handshake to `host:port` pins a fingerprint of the Mac's
  public host key (stored in `UserDefaults` under
  `MediaRemote.hostKeys.v1`). Every subsequent connection recomputes
  the fingerprint and aborts with `host key mismatch` if it differs —
  which is what you'd see if someone were MITM-ing the LAN, *or* if
  you legitimately regenerated the Mac's host key. To recover from the
  latter, tap the device and choose **Forget host key**, then reconnect.
  Caveat: the `SHA256:…` value the app shows is a stable hash of the
  presented key, but it is **not** byte-equal to
  `ssh-keygen -l -E sha256`'s output, because the version of Citadel
  we pin keeps its SSH wire-format writer `internal`. TOFU still
  works (the pin changes iff the key changes); it's just that the two
  strings can't be compared character-for-character against
  ssh-keygen.
- **Password auth has been removed.** Only Ed25519 key auth is
  supported; any old password-auth devices are pruned from the device
  store at first launch.
- Private keys are stored as the raw Ed25519 seed in the iOS Keychain
  with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — they never
  sync to iCloud and don't leave the device. The in-memory buffer
  holding the decoded seed is zeroed immediately after constructing
  the signing key.
- The SSH channel only carries a short command line and a short reply —
  no now-playing artwork, no audio.

## Customisation ideas

- Poll cadence lives in `RemoteController.pollIntervalActive` /
  `pollIntervalIdle` (2 s / 8 s by default). Tweak there if you want a
  snappier update while nothing is playing, or a less chatty one while
  listening.
- Only one device is connected at a time. Adding multi-device "sticky"
  connections would involve keeping a dictionary of `CitadelSSHTransport`
  per selected device.
- The volume slider is continuous from 0 to 1 and only pushes on
  `onEditingChanged(false)`. Swap to a debounced live push if you prefer.
- Each poll tick still opens a fresh Citadel exec channel. A truly
  persistent bidirectional channel (one SSH session that streams
  commands and replies for the whole foreground session) is the
  bigger win left on the table — it's flagged as future work in
  `CitadelSSHTransport.swift` and depends on Citadel exposing a more
  ergonomic exec-stream API.
