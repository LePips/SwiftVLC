# Chromecast state-correctness provenance (patch 0034)

## Source baseline and frozen inventory

- VLC source pin: `c833c4be000b426d73ff4324bec574065f00e3df`.
- Patch 0034 is generated after SwiftVLC patches 0001–0033 in manifest order.
- Frozen patch: `0034-chromecast-state-correctness.patch`.
- Frozen patch SHA-256:
  `af7099e0447afbad81720eecb438466e5d3cff55575e6df39b18bdc8263bce54`.
- The patch owns exactly eight VLC paths:
  - `modules/stream_out/Makefile.am`
  - `modules/stream_out/chromecast/chromecast.h`
  - `modules/stream_out/chromecast/chromecast_communication.cpp`
  - `modules/stream_out/chromecast/chromecast_ctrl.cpp`
  - `modules/stream_out/chromecast/chromecast_demux.cpp`
  - `modules/stream_out/chromecast/chromecast_demux_eof.hpp` (new)
  - `modules/stream_out/chromecast/chromecast_protocol.hpp`
  - `modules/stream_out/chromecast/meson.build`

No public libVLC header, Swift shim, patch 0032 audio-reset contract, or patch
0033 audio-session lease contract is changed by 0034.

## Primary protocol and upstream audit

Google's Cast media-message contract is the primary wire reference:
<https://developers.google.com/cast/docs/media/messages>. It defines the
64-KiB transport-message maximum; random nonzero sender request IDs; exact
request/response correlation; spontaneous `MEDIA_STATUS` with request ID zero;
receiver-issued media-session identity; `currentTime`, `playbackRate`, and
player-state semantics; and the four terminal `idleReason` values.

The official VLC master audited on 2026-09-01 was
`2b3db140b49beba2ceb2cb3dfee47f2f049237c7` (2026-08-31). It still used a
single `m_last_request_id`, a 10-KiB fixed receive buffer, and the indefinitely
polling `vlc_tls_Write()` path. No equivalent complete state/attribution/
deadline correction was available to backport.

The official VLCKit master audited on 2026-09-01 was
`6cbc4e7b248aa51ec0906697abb30ecae47194b7`. Its player forwards a retained
`VLCRendererItem` to libVLC, while its discoverer deduplicates renderer items by
friendly name and type. Neither VLCKit nor pinned libVLC exposes a proven
durable physical-receiver identifier. SwiftVLC's current `RendererItem.id` is
therefore only pointer-stable for one retained item. A cross-discovery stable
identity change is deliberately not included in 0034.

## Correctness contract

Patch 0034 makes the following source behavior one coherent contract:

1. Each LOAD, PLAY, PAUSE, STOP, and media GET_STATUS command has its own
   request slot and response deadline. One response cannot clear another
   command's attribution. IDs are nonzero, collision-checked, and numeric JSON
   IDs must be finite integral values in range.
2. Receiver broadcasts update the already-owned media session even when they
   carry request ID zero or another sender's nonzero ID. A session can be born
   only from this sender's exact LOAD response; foreign-only sessions cannot
   replace it.
3. Desired pause is separate from observed PLAYING/PAUSED/BUFFERING state.
   Receiver-originated state is reported instead of being immediately fought;
   only initial-load reconciliation and exact local pause/play replies consume
   the one bounded retry.
4. Receiver clock samples require finite, nonnegative `currentTime` and
   `playbackRate`. PLAYING advances at the reported rate, including 0.5x and
   2x; PAUSED and BUFFERING freeze. A valid zero timestamp remains distinct
   from the pinned VLC invalid-tick sentinel.
5. The heartbeat timeout is exactly 6000 milliseconds, not a VLC-tick value
   passed to a millisecond API. Authentication, connection, launch, commands,
   and playback progress all have explicit finite deadlines.
6. LOADING and BUFFERING share one non-renewable 30-second progress watchdog.
   Repeated LOADING/BUFFERING alternation cannot extend it. Pre-first-play
   expiry is `LoadFailed`; a later rebuffer expiry makes the transport dead.
7. The complete protobuf envelope is accepted through exactly 64 KiB and is
   rejected above that boundary on both send and receive. Header plus payload
   share one total read deadline, so drip-fed bytes cannot reset the timeout.
8. Cast writes bypass pinned VLC's infinite `vlc_tls_Write()` poll. Direct TLS
   writes and POLLOUT waits share one 2000-ms total budget, including partial
   progress, EAGAIN, EINTR, spurious readiness, and a late would-be-successful
   write. A failed partial frame is terminal.
9. Malformed JSON/protobuf, partial-frame interruption/timeout, active CLOSE,
   and checked send failures enter one absorbing terminal state. The control
   worker owns final TLS disconnect; reconnect joins outside the controller
   mutex without publishing a null pointer to the old worker.
10. The Chromecast demux sends EOF only when both `ES_OUT_DRAIN` and
    `ES_OUT_IS_EMPTY` succeed and the latter explicitly writes true. A failed
    or non-writing control cannot inherit a true default.

## Official VideoLAN issue obligations

The feature manifest records all of these as release obligations; the static
gate is not receiver evidence.

- [VLC #28141](https://code.videolan.org/videolan/vlc/-/work_items/28141):
  0034 corrects the timeout unit, keeps paused desired/observed state separate,
  and bounds heartbeat/command failure. It does not prove that a physical
  receiver and network will answer the heartbeat or that a playlist will not
  advance after a real link failure.
- [VLC #24573](https://code.videolan.org/videolan/vlc/-/work_items/24573):
  0034 makes owned-session IDLE reasons deterministic and bounds lack of
  progress across LOADING/BUFFERING. It cannot prevent receiver firmware from
  publishing an erroneous midstream IDLE.
- [VLC #25116](https://code.videolan.org/videolan/vlc/-/work_items/25116):
  0034 accepts receiver-originated owned-session clock/state broadcasts and
  avoids overwriting them with stale pause intent. Physical rewind,
  fast-forward, skip, track editing, and system-control interoperability remain
  unproved.
- [VLC #21751](https://code.videolan.org/videolan/vlc/-/work_items/21751):
  0034 fixes the false-positive EOF classification. Rendering every final
  audio sample and video frame remains a receiver-output requirement.
- [VLC #29654](https://code.videolan.org/videolan/vlc/-/work_items/29654):
  discovery regression and durable renderer identity are outside 0034 and are
  explicit blockers on `cast-discovery-identity`.

## Validation boundary

`chromecast-state-source-check.py` is frozen at
`0bd1b049b103f4a4a2c5ad3f6de23eb97f9fa48be63dcfe65cc460761332704f`.
It binds the helpers to the real controller, communication, demux, and build
inventory and runs 33 deliberate negative mutations.

`chromecast-state-probe.cpp` is frozen at
`09829a7423bfe73e322b504e17c9cb625dfcdfd4b7f98951abcb6bdbb59d6e9b`.
It executes exact attribution/deadline, numeric-ID, receiver-clock, 64-KiB,
non-renewing progress-watchdog, bounded-write, lock-recovery, and drain/empty
helpers. The bounded-write cases include success in chunks, always-EAGAIN,
partial write then timeout, spurious readiness until the deadline, and a
second write that would succeed but must not run after the deadline.

The read-only receiver oracle `scripts/cast-receiver-probe.py` is frozen at
`8e1d1d7bf25d05d51f74e8e56a4822f5e0fa5289f862292c41b1421f12457e5e`.
Its 22 host tests prove the exact 64-KiB boundary plus missing, negative, NaN,
and infinite receiver time/rate rejection. It never writes LOAD, SEEK, PAUSE,
PLAY, STOP, or volume commands.

Strict `-Wall -Wextra -Werror -fsyntax-only` checks compile the real
`chromecast_ctrl.cpp`, `chromecast_communication.cpp`, and
`chromecast_demux.cpp` against a configured pinned tree and generated Cast
protobuf headers. The complete 0001–0034 patch series is replayed from the pin,
and the same source/mutation/native checks run on that clean result. The host
has only Apple bison 2.3, so patch 0028's optional bison-3 linked gate is left
to the subsequent external-SSD all-platform builds. This task does not rebuild
libVLC.

Patch 0028's structural source gate remains active after the controller
redesign. It recognizes 0034's checked boolean heartbeat/media handlers and
reconnect-local communication candidate, while still requiring the sole
allowed already-reconnecting guard before unconditional old-artwork-route
restoration. Its own bypass self-test and the clean 0001–0034 replay both pass.

## Remaining physical release evidence

An iPhone running the available beta OS is acceptable for this candidate's
device lane, but it is not a substitute for receiver-output evidence. Release
credit still requires a real Cast receiver with recorded model/firmware and:

- discovery, removal, rediscovery, and a durable-identity decision;
- load, sustained playback, pause longer than two heartbeat intervals, resume,
  rate/clock checks, seek, receiver-native controls, tracks, stop, and recast;
- receiver power loss, Wi-Fi interruption/recovery, controller takeover, and
  return-to-local behavior;
- representative VOD and live HLS playback;
- final-frame and final-audio fingerprints through drain/EOF; and
- an IPv6-capable discovery/connect/playback route.

Until that evidence is candidate-bound and retained, the relevant casting
features remain external-lab release blockers even though the static contract
passes.
