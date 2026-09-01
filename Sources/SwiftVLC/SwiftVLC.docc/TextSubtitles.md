# Presenting Text Subtitles

Render semantic subtitle regions in your own interface instead of letting
libVLC draw their text over the video.

## Opt in before playback

Call ``Player/textSubtitleStream()`` before the player starts. The first call
installs a callback on that player's native handle and opts it into custom text
presentation. If you never call the method, libVLC keeps its ordinary native
subtitle rendering behavior.

```swift
let player = Player()
let subtitleSnapshots = try player.textSubtitleStream()

let presentation = Task { @MainActor in
    for await snapshot in subtitleSnapshots {
        if snapshot.regions.isEmpty {
            subtitleOverlay.hide()
        } else {
            // Convenient when the overlay does not implement region placement.
            subtitleOverlay.show(snapshot.text)
        }
    }
}

try player.play(Media(url: movieURL))
```

Enabling capture after playback has started throws
``VLCError/invalidState(_:)``. A released libVLC artifact that does not include
SwiftVLC's callback extension throws ``VLCError/operationFailed(_:)``. Capture
stays enabled for the player's lifetime; cancelling every consumer does not
restore native text rendering.

## Use a patched libVLC build

The callback and renderer interception are SwiftVLC extensions to the pinned
libVLC source. Region snapshots and parsed WebVTT placement are one extension
ABI at version 10. Until a published SwiftVLC binary includes that ABI, build
the repository's patched engine and point the package at it:

```bash
./scripts/build-libvlc.sh --all
./scripts/setup-dev.sh --skip-download
```

For a faster macOS-only development build, use `--macos-only` in place of
`--all`. Platform-only builds replace the existing XCFramework rather than
adding a slice. The patch manifest pins the engine revision and applies the
subtitle callback automatically; no manual VLC source edit is required.

## Select an internal track

Track discovery remains the same as normal subtitle playback. Subscribe to
events before starting, refresh after libVLC reports a track change, and select
the embedded track you want:

```swift
let events = player.events
let subtitleSnapshots = try player.textSubtitleStream()
try player.play(Media(url: movieURL))

for await event in events {
    guard case .tracksChanged = event else { continue }
    player.refreshTracks()

    if let english = player.subtitleTracks.first(where: { $0.language == "eng" }) {
        player.selectedSubtitleTrack = english
        break
    }
}
```

Each ``TextSubtitleSnapshot`` contains the complete ordered array of semantic
text regions currently displayed. Each ``TextSubtitleRegion`` carries its own
text and ``TextSubtitlePlacement``. Region order is presentation order and is
also the order used by the snapshot's `text` convenience property, which joins
region text with newline characters.

An empty `regions` array means the cue cleared and the app should remove its
overlay. There is no sentinel region for clearing; `snapshot.text` is `""` for
an empty snapshot. Loading or replacing media, stopping, reaching the end,
encountering an error, and replacing the native player also clear the snapshot.
Native handle replacement reattaches capture without finishing the stream.
Shutdown and deinitialization clear an active snapshot before finishing
existing subscriptions.

## Apply placement by provenance

``TextSubtitlePlacement/automatic`` tells the app to choose ordinary subtitle
layout. SubRip, TTML, `mov_text`, and every other semantic text format use this
case, even if their decoded VLC region happens to carry generic geometry.
SwiftVLC does not infer WebVTT provenance from that geometry.

Only a region explicitly marked by VLC's WebVTT decoder uses
``TextSubtitlePlacement/webVTT(_:)``. Its ``WebVTTPlacement`` is normalized
semantic information parsed from the cue settings rather than post-layout
pixel geometry:

- `horizontalPosition` and `verticalPosition` are normalized video-viewport
  coordinates. Authored settings can place a coordinate outside `0.0 ... 1.0`.
- `horizontalAnchor` and `verticalAnchor` identify the point on the rendered
  cue box placed at those coordinates.
- `maximumWidth` and `maximumHeight` are optional normalized layout limits,
  not promises about the box's final measured size.
- `textAlignment` is the resolved physical alignment: left, center, or right.
- `writingDirection` distinguishes horizontal text from vertical text growing
  left or right.

A WebVTT cue with no placement settings still uses the `.webVTT` case. Its
semantic defaults are bottom-centered horizontal placement at the viewport
edge, centered text, and no explicit maximum width or height. A presenter can
apply its own safe margin and collision avoidance without corrupting authored
percentages or anchors.
When several WebVTT regions are active, apply each region's placement in array
order rather than flattening them first.

```swift
for await snapshot in subtitleSnapshots {
    subtitleOverlay.removeAllRegions()

    for region in snapshot.regions {
        switch region.placement {
        case .automatic:
            subtitleOverlay.addAutomaticallyPlacedText(region.text)
        case .webVTT(let placement):
            subtitleOverlay.addWebVTTText(region.text, placement: placement)
        }
    }
}
```

The overlay calls above stand in for application-specific rendering. SwiftVLC
delivers placement values but does not prescribe a UI framework or text layout
engine.

## Format limits and delivery behavior

This API covers decoded text regions, such as embedded SubRip, WebVTT, TTML,
and `mov_text` cues that reach VLC's semantic text subtitle path. It does not
OCR image subtitles. PGS and VobSub therefore produce no regions. ASS/SSA often
travels through libass as positioned RGBA regions rather than semantic text and
is likewise not exposed by this API. Those bitmap regions remain outside the
custom text path.

libVLC invokes the native callback on an internal subtitle/video-output
pipeline thread. Calls are serialized, but they are not tied to one fixed
thread. The native region array, every text pointer, and its placement records
are callback-owned and valid only until that invocation returns. SwiftVLC
synchronously copies all text and placement fields into `Sendable` Swift value
types before returning; your `for await` body runs on the task's executor, not
inside libVLC.

Every call to ``Player/textSubtitleStream()`` creates an independent
subscription, seeded with the latest snapshot. Equality includes ordered text
and placement, so a placement-only change is delivered even when the flattened
text is unchanged. Identical snapshots are deduplicated and each subscriber
buffers only the newest pending value, so a slow UI does not accumulate stale
cues. This callback does not consume libVLC's media-player time watcher.

## Topics

### Custom presentation

- ``Player/textSubtitleStream()``
- ``TextSubtitleSnapshot``
- ``TextSubtitleRegion``
- ``TextSubtitlePlacement``
- ``WebVTTPlacement``
