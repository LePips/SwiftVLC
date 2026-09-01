# Patch 0031: effective playback-rate event

## Identity

- VLC base commit: `c833c4be000b426d73ff4324bec574065f00e3df`
- Required preceding SwiftVLC series: patches `0001` through `0030`
- Patch: `0031-effective-playback-rate-event.patch`
- Patch SHA-256:
  `ad1d63a33126407431bc7f099918ca3b084c81e3443b2743aab845284a2df4ee`
- Patch manifest SHA-256 after adding 0031:
  `1db5409978cdda3a1ec53d8b71158f9de48ca7263ae83ae990737d1c40c97fb4`
- The machine-local external build prefix is normalized below as
  `<external-build-root>`; the recorded replay-directory suffixes are unchanged.
- Exact `0001`–`0030` incremental base:
  `<external-build-root>/Tmp/rate-event-series.JTMD97/vlc`
- Clean manifest replay through `0031`:
  `<external-build-root>/Tmp/rate-event-replay-final.dpccbF/vlc`

The patch was generated from a clean `c833` checkout after applying the exact
manifest-pinned `0001`–`0030` series. Its three native files are limited to the
public event declaration, the extension-version documentation, and the
libVLC media-player callback bridge.

## Contract

Version 7 appends `libvlc_MediaPlayerRateChanged` after the existing
SwiftVLC strict frame-step event and before the independently numbered
`0x200` media-list range. Its payload is exactly:

```c
struct
{
    float new_rate;
} media_player_rate_changed;
```

The released `libvlc_event_t` envelope remains 40 bytes, its union remains 24
bytes at offset 16, and the preceding strict frame-step payload retains all
offsets. No v1–v6 function, callback, payload, or symbol changes.

`lib/media_player.c` now wires `vlc_player_cbs.on_rate_changed` to a public
libVLC event. The callback runs with the player lock held and intentionally
reads `vlc_player_GetRate(player)` rather than trusting its callback argument.
For a successfully queued active input, VLC first clamps or substitutes the
request, allows access/demux rate control to modify or reject it, stores the
resulting input rate, and then invokes the callback; the getter returns that
resolved input value. With no input, the getter returns the saved global
control state. If active-input control queueing fails, core still invokes the
callback with the requested/global argument, but the public bridge ignores it:
the getter returns the unchanged active input rate, so the event may repeat the
effective state instead of misreporting the unapplied request. The payload is
therefore VLC's effective control rate at notification time, not measured
decode, presentation, network, or cast throughput.

This is deliberately not a request-completion protocol. The event carries no
request ID. A successfully queued active-input request that resolves to the
rate already in effect does not emit another notification. No-input requests
and active-input enqueue failures notify immediately and may repeat the
effective value. Rapid overlapping requests can produce only the resolutions
core actually reports; callers cannot infer one completion per request.

SwiftVLC preserves the synchronous, throwing `setPlaybackRate(_:)` signature.
A successful return continues to mean only that the immediate native call did
not report an error. `PlayerEvent.rateChanged(Float)` exposes effective
transitions, and the internal lossless event consumer invalidates the live
`Player.rate` observable. `Player.supportsEffectivePlaybackRateEvents` is
gated by extension version 7; an older archive stays linkable through the
existing weak version shim and reports the event unavailable.

## Validation pins

- `effective-playback-rate-event-source-check.py`:
  `9325d0dbeae8e65486f93788865d91b651e94c9be7fbf3e0132166bbe926ea6c`
- `pip_extension_version.py`:
  `98adb898d64ed8c8a57bbc883bf10dd96eeb399a2f7671c1d2fceb262fad63b5`
- `effective-playback-rate-event-abi.c`:
  `cc824316f4cd8044e5976ed36dba61a9dbaff8f2125b5ba1674f342efc5cb94b`
- `effective-playback-rate-event-abi.cpp`:
  `ded305b206534bd1324a5fb9d1d6800ba9f3e01360eca2da5e602dcaaa92a369`
- `effective-playback-rate-event-probe.c`:
  `865d8e90392a4a569ccd4bb3537e0e639940af50908fde62d83bbeeb89373443`
- `validate-effective-playback-rate-event.sh`:
  `293294dabd0cef290473871f562fa8cc14377a6a2d101c11d5c9f7ceb54b584e`

The source checker proves append-only enum placement, the frozen event
envelope, the callback's locked-player contract, authoritative getter payload,
and VLC's active-input/no-input/enqueue-failure resolution paths. It shares the
fail-closed extension resolver used by the preceding native contracts: the
integrated tree must resolve exactly and contain version 7 or newer, while the
ordered patch manifest supplies the exact version intended by a clean replay
or build. Negative mutations cover enum aliasing, payload growth, callback
removal, requested-value substitution, wrong event identity, stale or partial
extension composition, and bypassing the input-resolved rate.

The C11 and C++17 probes compile and execute against the public header. The
linked probe, which the all-slice build hook runs after a new macOS archive is
produced, verifies idle delivery and same-value repetition, active-input
delivery and same-value silence, and effective getter agreement. A separate
central archive probe also requires the exact manifest-owned extension version
and every strong symbol through that version, preventing a newer header from
masking an older linked archive.

## Focused evidence (2026-09-01)

All compiler, SwiftPM, and temporary output was placed under
`<external-build-root>`.

- Patch-manifest hashes and ordering: PASS, 31 patches.
- Clean `0001`–`0031` replay and `git diff --check`: PASS.
- Effective-rate source and seven negative-mutation gates: PASS.
- Public C11 and C++17 ABI compile/execution with `-Wall -Wextra -Werror`:
  PASS.
- Exact `lib/media_player.c` syntax against the configured macOS arm64 VLC
  headers: PASS.
- Updated v6 vmem source/mutation, ABI, source-syntax, and immutable-generation
  race-syntax gates under integrated version 7: PASS.
- Updated strict frame-step source gate under integrated version 7: PASS.
- Full Swift package/test-target compilation: PASS (372 build steps).
- Focused Swift event mapping, availability, ordered stream, observable
  invalidation, description, and shipped-header tests: PASS, 7/7.
- Linked native rate-event playback probe: PENDING a rebuilt version-7 macOS
  archive. The existing released archive predates 0030/0031 and is not valid
  evidence for the new event.

## Scope boundary

This patch makes the effective control state observable. It does not guarantee
that an arbitrary source supports every requested rate, measure achieved media
throughput, or create request-correlated settlements. Release qualification
must still exercise rate changes on physical-device local, HLS, live, and cast
paths and compare media-clock/visible-motion behavior separately from this
control event.
