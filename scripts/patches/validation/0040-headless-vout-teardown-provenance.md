# Patch 0040: headless video-output teardown deadlock provenance

Status: source-complete candidate, investigated 2026-09-01. This record does
not claim a qualified native artifact. Both clean reproducibility builds and
the physical-device release checklist remain mandatory after this patch lands.

## Identity

- SwiftVLC pinned VLC base:
  `c833c4be000b426d73ff4324bec574065f00e3df`.
- Patch SHA-256:
  `a4945772122ce3d02f9a5c0c7136fa5dae940f251081238260b760b86c834681`.
- Source checker SHA-256:
  `b1d7ad84164f9b28ac24e67c6314a55d1248bdcde4af645cdebb47e37db184d1`.
- Bounded runtime probe SHA-256:
  `4315e376376fc6ccbff83b7c76de06d0b540eb8ccc1bb5914cbea6f9b5dd2fe1`.
- The bug was introduced by SwiftVLC patch
  `0027-strict-frame-step-contract.patch`; it is not present in the pinned VLC
  source or in official VLC master.

## Observed failure

The first clean all-platform native build from SwiftVLC revision
`6d98475d5f1f9610759a4758e52e2df9ffa38c90` compiled all thirteen Apple
architecture targets, assembled the XCFramework, normalized all eight slices,
and passed terminal-playback-failure attribution. It then stopped making
progress in `validate-pip-playback-snapshot.sh` while releasing the player.

The probe intentionally runs as a command-line process without creating
`NSApplication`. The H.264 fixture reached VideoToolbox, after which VLC logged:

```text
cannot create video output window without NSApplication
stream filter error: cannot pre fill buffer
```

The probe's readiness loop is bounded to five seconds. Sampling and a complete
LLDB thread capture after that bound proved that execution was not merely slow:

1. the process main thread was in `libvlc_media_player_release`, through
   `vlc_player_Delete`, waiting to join the player main loop;
2. the input thread was in `End` -> `EsOutUnselectEs` -> `EsOutDestroyDecoder`
   -> `vlc_input_decoder_IsDrainedLocked` -> `vout_IsEmpty`;
3. `vout_IsEmpty` was blocked inside `vout_control_Hold`;
4. live state showed a non-NULL decoder vout with `video.started == false`,
   `display == NULL`, no render-thread handle, `control.yielding == false`, and
   one pending control holder.

No render thread can set `control.yielding` in that state. The wait is therefore
permanent. VideoToolbox was idle and was not in the blocking chain.

## Root cause and upstream comparison

At the pinned VLC commit, `vout_IsEmpty` only checks the decoder picture FIFO.
Official VLC commit
[`a254772e392dd749ca45c67654ddb5f5a1745866`](https://github.com/videolan/vlc/commit/a254772e392dd749ca45c67654ddb5f5a1745866)
later added the missing picture-FIFO lock and unlock, but still did not enter
`vout_control_Hold`. Current official VLC retains that thread-independent
shape.

The decoder-side gate is also established upstream policy, not a SwiftVLC
invention. VLC commit
[`a2d5f9a08e5f9ab2c3d076f406e94fc510f9b0a5`](https://github.com/videolan/vlc/commit/a2d5f9a08e5f9ab2c3d076f406e94fc510f9b0a5),
`decoder: don't control the vout when not started`, introduced the started flag
specifically because Hold-backed vout calls deadlock before the vout starts.
It guarded flush, pause, rate, delay, and delete paths. Upstream's FIFO-only
`vout_IsEmpty` did not need that precondition; SwiftVLC made it Hold-backed in
0027 and therefore must apply the same established started gate to this caller.

VLC's own player tests preserve this lifecycle as a supported case.
[`test_no_outputs`](https://github.com/videolan/vlc/blob/master/test/src/player/outputs.c)
uses a failed video-output configuration, waits for stopping, and synchronously
deletes the player; `test_vout_fail` in
[`next_prev.c`](https://github.com/videolan/vlc/blob/master/test/src/player/next_prev.c)
also exercises `--vout=none`. SwiftVLC's linked libVLC probe tests the same
failure class through the public API and the actual Apple archive.

SwiftVLC patch 0027 extended the predicate to include strict frame-step and
static-filter final-output state. That aggregate must be serialized against a
running render thread, so 0027 added an unconditional `vout_control_Hold`.
`vout_Request` creates the render thread only after window and display creation
succeed. The failed-window lifecycle—non-NULL decoder vout, but
`video.started == false`—was omitted from the new predicate's admission rules.

An A/B control excluded probe misuse. The exact same headless PiP snapshot
probe, linked against the previous committed native archive, logged the same
window failure and VideoToolbox selection and returned `PASS` in approximately
one second. Disassembly of its `vout_IsEmpty` showed the prior direct
FIFO-lock/test/unlock implementation. Linked against the new patch-0027
archive, it entered `vout_control_Hold` and did not return.

## Fix boundary

Patch 0040 uses the decoder's existing FIFO-protected lifecycle authority:

1. if `Decoder_HasStartedVoutLocked(owner)` is false, assert that no strict
   request and no installed final-output observer crossed the stopped boundary,
   then report the output drained without entering its inactive control loop;
2. only for a started vout, preserve 0027's decoder-owned outstanding-work
   check;
3. only after both gates, call the control-serialized `vout_IsEmpty` aggregate.

The stopped gate deliberately precedes the positive `frames_countdown` check.
That field is multiplexed: paused flush uses a positive value internally, and
previous-frame control uses `-1`. A stopped output cannot turn such a count
into final output, and treating it as universally user-owned work would wedge
natural EOF. The patch does not clear the field or synthesize a callback from
this read-only predicate.

Checking `sys->display == NULL` in `vout_IsEmpty` was rejected. The field has
its own lock, and display teardown contains a render-thread-joined,
display-still-non-NULL interval. A null test would either race or retain a
second path into the same permanent wait. Generalizing `vout_control_Hold` to
support inactive control loops would require a new synchronized lifecycle and
changes across every Hold-backed call site; that is unnecessary when the
decoder already owns the exact started gate.

## Regression contract

`headless-vout-teardown-source-check.py` validates the integrated final source,
not just patch text. It requires:

- the canonical `Decoder_HasStartedVoutLocked` predicate under the decoder
  FIFO;
- stopped-vout strict/observer assertions and `return true`;
- ordering of stopped gate, active-output pending-work gate, and
  `vout_IsEmpty` call;
- cancellation-before-stop and reopen-only-after-success ordering at the
  video-output transition;
- the exact single-file patch and bounded runtime probe identities.

Its deliberate mutation suite removes, weakens, or reorders each material
branch and lifecycle invariant. Its executable state matrix distinguishes:

- stopped output with no countdown, and stopped output with an internal or
  legacy positive countdown: drained without consulting the vout;
- active output with pending work: not drained without consulting the vout;
- active output with no decoder-owned work: defer to `vout_IsEmpty`;
- impossible stopped-output strict/observer states: fail the invariant.

The macOS runtime probe deliberately creates no `NSApplication` and runs the
two-second H.264/AAC fixture with dummy audio pacing in two independently
bounded modes:

1. begin playback, request asynchronous stop, and release every libVLC object;
2. observe `Playing`, require a coherent seekable snapshot and at least one
   second of media-time progression, allow natural EOF to reach exact
   `libvlc_Stopped` (an error is not accepted), then release without an explicit
   stop.

The natural-EOF row is essential: an incorrect `!started => false` fix could
allow an explicit stop to flush state while still making EOF poll forever. A
process-local `SIGALRM` exits with status 124 after twenty seconds, so a future
deadlock fails the build rather than consuming an unbounded release run. The
existing PiP playback-snapshot probe carries the same watchdog.

## Adjacent finding and residual risk

Investigation found a separate lifecycle ambiguity in the legacy, uncorrelated
frame-next path: unlike strict frame requests, it can currently enter while
`video.started == false` during a reconfiguration window. Merely clearing its
positive countdown is unsafe because the same field represents paused-flush
work. Patch 0040 does not invent ownership metadata or synthesize terminals for
that ambiguous state. This behavior needs a separately modeled follow-up if
legacy frame-next admission is tightened.

After patch 0040, both clean native builds must restart from the final commit;
the otherwise complete `6d98475` archive was built without this fix and cannot
be promoted. Physical iPhone qualification remains a distinct release gate.
