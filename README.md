<picture>
  <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-dark.svg">
  <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-light.svg">
  <img alt="SwiftVLC" src="https://raw.githubusercontent.com/harflabs/SwiftVLC/main/Assets/logo-light.svg" width="260">
</picture>

[![Tests](https://github.com/harflabs/SwiftVLC/actions/workflows/test.yml/badge.svg)](https://github.com/harflabs/SwiftVLC/actions/workflows/test.yml)
[![codecov](https://codecov.io/gh/harflabs/SwiftVLC/branch/main/graph/badge.svg)](https://codecov.io/gh/harflabs/SwiftVLC)
[![Swift versions](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fharflabs%2FSwiftVLC%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/harflabs/SwiftVLC)
[![Platforms](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fharflabs%2FSwiftVLC%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/harflabs/SwiftVLC)

A Swift wrapper around [libVLC](https://www.videolan.org/vlc/libvlc.html) for iOS, macOS, tvOS, visionOS, and Mac Catalyst.

## Why?

AVFoundation is excellent for Apple's native media stack, but its
container, codec, subtitle, and network-protocol support is limited to
what Apple ships. Apps that need MKV, SSA/ASS subtitles, SMB,
UPnP, or other VLC-backed formats and protocols need a broader engine.

[VLC](https://www.videolan.org/)'s engine, **libVLC**, supports a broad set of codecs, containers, subtitles, and network protocols through embeddable C APIs.

VideoLAN's Apple wrapper, [VLCKit](https://code.videolan.org/videolan/VLCKit), is written primarily in Objective-C. It uses delegates, KVO, `NSNotificationCenter`, and manual thread management, which is a faithful reflection of the era it was designed in.

**SwiftVLC** wraps libVLC 4.0 directly in Swift, with no Objective-C layer in between. It is built for `@Observable`, `async/await`, and `VideoView(player)`.

## SwiftVLC vs VLCKit

| | SwiftVLC | VLCKit |
|---|---|---|
| **Language** | Swift 6 | Objective-C |
| **Bindings** | Direct C → Swift | C → Objective-C → Swift bridging |
| **State management** | `@Observable`, drives SwiftUI directly | KVO, `NSNotificationCenter`, and delegates |
| **Concurrency** | `@MainActor`, `Sendable`, `async/await` | Manual thread dispatch, no isolation |
| **Video rendering** | `VideoView(player)` | App-supplied view setup plus drawable configuration |
| **Errors** | Library failures use `throws(VLCError)`, typed and exhaustive | `NSError` codes |
| **Events** | `AsyncStream<PlayerEvent>` with multiple consumers | `NSNotificationCenter` |
| **libVLC generation** | 4.0 | 3.x stable line; 4.0 alpha packages exist |
| **SwiftUI PiP** | iOS via libVLC's native AVKit-backed drawable path; macOS private backend is SPI opt-in | App-supplied integration |
| **Swift 6 safe** | Yes, with strict concurrency | No |

## Features

- `@Observable` player: state, current time, duration, tracks, and volume drive SwiftUI directly.
- `VideoView(player)` handles the rendering lifecycle in a single SwiftUI view.
- Library failures use typed `throws(VLCError)` instead of error codes.
- Asynchronous media parsing: `try await media.parse()` with cancellation support.
- 10-band equalizer with libVLC's built-in presets.
- A-B looping, playback rate control, and subtitle and audio delay.
- Picture-in-Picture on iOS with full playback controls; macOS native PiP is available only through an explicit private-API SPI opt-in.
- Media discovery and renderer discovery through services exposed by the bundled libVLC plugins.
- 360° video with full viewpoint control over yaw, pitch, roll, and field of view.
- Asynchronous thumbnail generation at arbitrary timestamps.
- `MediaListPlayer` for playlist playback with loop and repeat modes.

## Requirements

- Swift 6.3+ / Xcode 26.4+
- iOS 18+ / macOS 15+ / tvOS 18+ / visionOS 2+ / Mac Catalyst 18+

## Installation

In Xcode, choose **File → Add Package Dependencies**, paste the repo
URL, and Xcode will pick up the latest release automatically:

```
https://github.com/harflabs/SwiftVLC.git
```

From a `Package.swift` manifest, add a dependency and pin to the
current release. The version string lives on the
[releases page](https://github.com/harflabs/SwiftVLC/releases).

```swift
.package(url: "https://github.com/harflabs/SwiftVLC.git", from: "1.0.0")
```

The pre-built libVLC xcframework downloads automatically via SPM. It's a large binary (multi-GB unstripped; the release zip is a few hundred MB).

## Quick Start

```swift
import SwiftUI
import SwiftVLC

struct PlayerView: View {
  @State private var player = Player()

  var body: some View {
    VideoView(player)
      .onAppear {
        try? player.play(url: URL(string: "https://example.com/video.mp4")!)
      }
  }
}
```

`Player.play(url:)` expects a direct media stream or file URL. It does
not auto-resolve `.pls` or classic `.m3u` playlist containers; use
`MediaListPlayer` or fetch and parse the playlist to its inner stream
URL before passing it to `Player`. HLS `.m3u8` URLs are supported here
because they are streaming manifests rather than playlists of separate
media URLs.

### Common Operations

```swift
// Playback
let player = Player()
try player.play(url: videoURL)
player.pause()
player.stop()
try player.seek(to: PlaybackPosition(0.5)) // Seek to 50%
try player.setPlaybackRate(1.5)            // Request 1.5x control rate
try player.setAudioVolume(0.8)             // 80% volume
player.isMuted = true

// Tracks
player.selectedSubtitleTrack = player.subtitleTracks[1]

// Metadata
let media = try Media(url: videoURL)
let metadata = try await media.parse()
print(metadata.title, metadata.duration)

// Events
for await event in player.events {
  switch event {
  case .stateChanged(let state): ...
  case .timeChanged(let time): ...
  default: break
  }
}
```

Playback-rate application is asynchronous inside VLC. A successful setter
return confirms immediate request acceptance, not that the active input kept
that rate. On extension-v7 builds, `PlayerEvent.rateChanged` reports the
effective control state without claiming request correlation or measured
throughput; `player.rate` remains the authoritative live value.

## Documentation

The API reference for the latest published release is hosted on Swift Package
Index. The unversioned link follows the most recent tag that the service has
finished building:
**[swiftpackageindex.com/harflabs/swiftvlc/documentation](https://swiftpackageindex.com/harflabs/swiftvlc/documentation)**

## Showcase Apps

The `Showcase/` directory contains separate folders, targets, and schemes for each showcase lane:

- **iOS.** Full-featured app target, also enabled for Mac Catalyst.
- **macOS.** Native macOS app target with the same showcase coverage, adapted into sidebar-driven Mac UI.
- **tvOS.** Native tvOS showcase app target with TV-focused focus navigation and Siri Remote controls.
- **visionOS.** Native visionOS app target with a focused simple playback showcase.

Every showcase target accepts an app-wide test stream URL. The override is
kept in memory for the current app session, redacted to its scheme, host, and a
hidden path in the UI, and used by showcases that otherwise load bundled or
public sample media. HTTP, HTTPS, UDP, and other URL schemes supported by
the bundled libVLC are accepted, including HLS through its `.m3u8` HTTP(S)
URL.

- **iOS and Mac Catalyst:** open **Set App-Wide Stream URL** in the **Test Stream** section on the first screen.
- **macOS:** use **Test Stream** in the toolbar or **Test Stream URL** in the sidebar's **Configuration** section.
- **tvOS:** select **Set App-Wide Stream URL** on the first screen and enter the URL with the on-screen keyboard or a paired device.
- **visionOS:** use the **Test Stream** button beside the simple playback controls.

The development showcase targets allow arbitrary network loads so user-entered
HTTP hosts work with libVLC. This broad App Transport Security exception is for
the Showcase apps only. Applications embedding SwiftVLC should define the
narrowest transport policy appropriate for their own media sources.

Showcase UI tests live under `Showcase/UITests/`. `iOSUITests` covers
the broad showcase flows, `macOSUITests` covers native macOS PiP, and
`tvOSUITests` is a placeholder target. The visionOS showcase does not
have a UI-test target.

## Testing

The core package uses a comprehensive
[Swift Testing](https://developer.apple.com/xcode/swift-testing/) suite
against the real libVLC binary, so regressions in the C bridge surface
immediately rather than hiding behind a fake. Showcase UI tests use
XCTest separately. Every pull request to `main` runs lint and policy checks,
the package suite with behavior/skip accounting, an iOS test-target compile,
and an iOS Showcase build. The slower four-platform Showcase matrix, tvOS
simulator run, and sanitizers run after merge or when manually requested;
sanitizers also run weekly. Real playback and system-PiP acceptance stays in
the local physical-device checklist instead of consuming hosted CI minutes.

```bash
swift test
```

Before a release candidate, connect a trusted, unlocked physical iPhone or iPad
with Developer Mode enabled and run the human-facing device checklist:

```bash
./scripts/qualification/qualify.sh full --device "My iPhone" --require-stable
```

The approximately one-hour `full` profile reports broad functional confidence
without pretending it ran the multi-hour endurance matrix. The `release`
profile retains those real durations and must be run for each required device
row before the stable release gate can pass. Neither command publishes a
release. See [the device qualification guide](scripts/qualification/README.md)
for profiles, evidence, and checklist status semantics.

See [ARCHITECTURE.md](ARCHITECTURE.md#testing-strategy) for test tags,
fixtures, and structure.

## Development Setup

```bash
git clone https://github.com/harflabs/SwiftVLC.git
cd SwiftVLC
./scripts/setup-dev.sh
swift test
```

`main` records an exact libVLC release URL and checksum. `setup-dev.sh` verifies
that tag against the GitHub asset digest, downloads that exact artifact into
`Vendor/`, and flips `Package.swift` plus the Showcase package reference to
repo-local sources. It never follows GitHub's mutable “latest” pointer.

| `setup-dev.sh` flag | Effect |
|---|---|
| *(none)* | Install the exact release declared by `Package.swift`; replace an unverified or stale `Vendor/` copy. |
| `vX.Y.Z` *(positional)* | Pin to a specific release tag. |
| `--force` | Re-download even if `Vendor/` already exists. |
| `--skip-download` | Only flip local references (`Package.swift` and the Showcase app). Expects `Vendor/` to already exist, which is useful after running `build-libvlc.sh`. |

## Building libVLC from Source

Needed only when bumping `VLC_HASH`, modifying build patches, or preparing a release. Day-to-day Swift development doesn't require it.

```bash
brew install autoconf automake libtool cmake pkg-config gettext
./scripts/build-libvlc.sh --all
```

Expect a full `--all` build to take tens of minutes on Apple Silicon. The script clones VLC at a pinned commit into `scripts/.build-libvlc/`, applies the source patches below, builds every contrib (FFmpeg, dav1d, x264, libass, …) per slice, and assembles the result into `Vendor/libvlc.xcframework`.

A clean all-platform build needs roughly 100 GiB of working space. The script
checks the volume that contains the repository before compiling and fails early
when it is too small. Keep the checkout on an external SSD when internal disk
space is constrained: the VLC source, contrib trees, architecture builds, and
assembled libraries all remain under `scripts/.build-libvlc/` on that volume.

### Platform selection

| Flag | Platforms |
|---|---|
| *(default)* | iOS device + simulator |
| `--all` | iOS, tvOS, visionOS, macOS, Mac Catalyst (eight slices) |
| `--ios-only` / `--tvos-only` / `--visionos-only` / `--macos-only` / `--catalyst-only` | Replaces `Vendor/` with that single platform |
| `--tvos` / `--visionos` / `--macos` / `--catalyst` | Adds a platform to the default set |
| `--clean` / `--clean-build` | Wipe `scripts/.build-libvlc/` (the latter rebuilds afterwards) |
| `--hash=<sha>` | Override the pinned VLC commit |

> `*-only` flags **replace** the xcframework; any slices already in `Vendor/` are lost.

### Build adjustments and source patches

VLC master requires several build adjustments for SwiftVLC's supported Apple
toolchains. The script applies them in-tree on every invocation, idempotently:

1. **Mac Catalyst.** Teaches VLC's build system the `macabi` target triple and guards OpenGLES-only code paths.
2. **visionOS deployment target.** Adds the `xros` target triple so object files are stamped with visionOS 2.0 instead of the installed SDK version.
3. **Xcode 26 LDFLAGS.** Adds `-isysroot` to linker invocations so libSystem resolves.
4. **libtool 2.5 OBJC tag.** Adds `_LIBTOOLFLAGS = --tag=CC` to the `Makefile.am` files that contain `.m` sources. Older libtool versions inferred the tag; 2.5 refuses.
5. **Rust contribs disabled.** VLC's contribs pin `cargo-c 0.9.29`, which pulls `time 0.3.31` and fails type inference under the supported Rust toolchain. The only Rust contrib on Apple is `rav1e` (AV1 *encoder*); `dav1d` handles decoding.
6. **`dup3` / `pipe2`.** Forced unavailable via autoconf cache vars. iOS Simulator SDK 26 exports these Linux-only syscalls from libSystem, fooling configure into using them.

The script also applies these checked-in VLC source patches in order:

1. **[Chromecast hardening](scripts/patches/0001-chromecast-hardening.patch).** Enables the supported subtitle burn-in path and rejects unreachable receivers cleanly instead of routing playback into a dead cast session.
2. **[Sample-buffer aspect handling](scripts/patches/0002-samplebufferdisplay-aspect.patch).** Maps VLC fitting modes to the correct layer gravity and avoids OpenGLES-only configuration on Mac Catalyst.
3. **[Sample-buffer lifetime and placement](scripts/patches/0003-samplebufferdisplay-lifetime-placement.patch).** Backports upstream fixes that detach the display view from the vout lifetime and keep native placement updates consistent.
4. **[PiP safety and geometry](scripts/patches/0004-samplebuffer-pip-safety-geometry.patch).** Adds the retained media snapshots and pixel-buffer bridge used to keep asynchronous PiP frame delivery and geometry safe.
5. **[UPnP initialization teardown](scripts/patches/0005-upnp-init-failure-teardown.patch).** Balances cleanup only for initialization stages that completed, preventing a failed UPnP startup from hanging during teardown.
6. **[MP4 roll seek point](scripts/patches/0006-mp4-roll-seek-point.patch).** Keeps AAC decoder preroll metadata from resetting an MP4 seek to the start of the stream.

`git reset --hard` only runs when HEAD is not at `VLC_HASH`, so the patches and per-platform build dirs survive repeated runs.

## Releasing

Releases advance `main`, but stable releases can only consume an immutable,
previously prepared and device-qualified candidate. `setup-dev.sh` flips a
working checkout back to local sources for day-to-day development.

```bash
./scripts/build-libvlc.sh --all          # produces Vendor/libvlc.xcframework
./scripts/release.sh X.Y.Z --dry-run     # strip + zip + checksum, no push
./scripts/release.sh X.Y.Z --prepare /absolute/path/to/candidate
./scripts/check-qualification.sh X.Y.Z /absolute/path/to/candidate/libvlc.xcframework
./scripts/release.sh X.Y.Z --candidate /absolute/path/to/candidate
# Optional beta: strict SemVer pre-releases are published as unqualified pre-releases.
./scripts/release.sh X.Y.Z-beta.1
```

Release mode comes from the validated SemVer tag. A version containing a
pre-release component (for example `1.1.0-beta.1`) is always marked unqualified
and published as a GitHub pre-release. A stable version cannot use
`--unqualified`; it must consume a prepared candidate and pass the complete
device and feature gates.

What `release.sh` does:

1. Verifies all eight platform slices are present in the xcframework.
2. In `--prepare` mode, strips and zips once, then records complete-tree, zip,
   provenance, qualification-matrix, and feature-policy digests in an immutable
   candidate directory.
3. Requires physical-device qualification to name that complete post-strip
   tree and satisfy the versioned feature policy; a stable run refuses to
   rebuild, mutate, or substitute the policy bound to the candidate.
4. Verifies the prepared zip expands to the qualified XCFramework and that all
   candidate/provenance checksums still match.
5. Rewrites `Package.swift` to the remote URL and checksum, pins the Showcase
   app to exact version `X.Y.Z`, commits, and tags the result.
6. Uploads the zip, provenance, and candidate manifest to a draft release.
7. Advances `origin/main`; only after that succeeds does it publish the draft.

Candidate preparation and publishing refuse non-`main` branches, any dirty
working tree, a local `main` that differs from `origin/main`, pre-existing tags,
and unauthenticated `gh`. If publication fails after asset upload, the release
remains a non-public draft until it is fixed or removed.

After publication, verify that Swift Package Index has finished building the
tagged API reference and that the unversioned documentation link above resolves
to `1.0.0`. Its documentation build is asynchronous and may temporarily serve
the previous release while the new tag is queued.

## Architecture

For internals, including module design, C interop, the concurrency model, the event system, memory management, and the PiP rendering pipeline, see **[ARCHITECTURE.md](ARCHITECTURE.md)**.

## License

MIT. See [LICENSE](LICENSE).

libVLC is licensed under [LGPLv2.1](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html). Static linking may have licensing implications. See the [VLC licensing FAQ](https://www.videolan.org/legal.html).

## Acknowledgments

SwiftVLC stands on the work of the [VideoLAN](https://www.videolan.org/) community. VLC and libVLC represent decades of media playback work by hundreds of contributors.

Thanks also to [VLCKit](https://code.videolan.org/videolan/VLCKit) for establishing libVLC on Apple platforms.
