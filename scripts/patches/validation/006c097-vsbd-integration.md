# Deferred `6c097ec660` VSBD recovery adaptation and qualification

Status: intentionally excluded from patch 0028. The strict-frame/Apple-renderer
adaptation has been implemented and adversarially audited in an isolated VLC
candidate, but it must not be called integrated or release-qualified until the
final 0027 patch is frozen, this adaptation is regenerated in the patch series,
the host gates are rerun against the resulting archives, and the physical-device
rows below pass.

Upstream commit:

- `6c097ec6605a9a19919e620641ad0412cea228e3` — `vout/vsbd: flush if needed and on becoming active`
- Fixes VLC-iOS#2317 and VLCKit#743.
- Rechecked against upstream `master` at
  `2b3db140b49beba2ceb2cb3dfee47f2f049237c7` (2026-08-31): this remains the
  latest change to `VLCSampleBufferDisplay.m`; there is no later upstream
  lifecycle or race correction to fold in.

## Why the upstream change cannot be applied verbatim

The upstream change targets an older `VLCSampleBufferDisplay.m`. SwiftVLC's
patches 0002–0004, 0017, 0023–0024, and especially 0027 replace the relevant
display lifecycle and render path:

- display-layer installation, submission, purge, telemetry, and close are
  serialized with `_displayLayerLock` and `_displayClosed`;
- actual enqueueing uses the final layer's `AVSampleBufferVideoRenderer`;
- overlay refresh can enqueue a bounded transition sample while paused;
- strict frame-step success is allowed only after the production display
  reports a proven submission outcome; and
- rejected strict pictures must never remain reachable from a later generation.

An early `status == Failed` return would bypass strict terminal settlement. A
blind flush/enqueue can discard the target sample, count an invalidated attempt
as success, or let a stale observer act on a replacement renderer. Recovery
therefore has to be part of the same serialized submission transaction as 0027.

## Current adaptation contract

### Renderer identity, observers, and close

1. Install observers only after the final display layer and its
   `sampleBufferRenderer` are installed. Bind every callback to that renderer's
   process-unique display generation and reject callbacks for a closed,
   replaced, or otherwise non-current renderer.
2. Observe both
   `AVSampleBufferVideoRendererRequiresFlushToResumeDecodingDidChangeNotification`
   and `AVSampleBufferVideoRendererDidFailToDecodeNotification`. On iOS, tvOS,
   visionOS, and Catalyst, also recheck the current renderer when the
   application becomes active. macOS remains excluded from the application
   notification, matching upstream.
3. Notification blocks capture the display weakly and use `queue:nil`. A
   notification delivered synchronously from inside `flush` or
   `enqueueSampleBuffer:` must not recursively flush or enqueue; it marks the
   recovery check as deferred and lets the outer transaction re-read live
   state.
4. Close first publishes `_displayClosed`, generation zero, nil observer
   tokens, nil observed renderer/layer, and cleared recovery/base samples under
   `_displayLayerLock`. It then removes the captured observer tokens outside
   that lock. An already-running callback can finish acquiring the lock, but
   its current-renderer check makes it inert. Removing observers while holding
   the same lock would create an avoidable callback/removal deadlock risk.

### Bounded recovery and exact submission truth

1. Bracket the renderer status read with two live
   `requiresFlushToResumeDecoding` reads. Either an observed revoke or an
   ordinary `AVQueuedSampleBufferRenderingStatusFailed` begins one bounded
   recovery-flush episode. A revoke takes precedence when both are present.
2. Re-read the renderer immediately after the flush. A still-revoked renderer
   is retryable. An ordinary Failed status is permanent only if the bounded
   flush did not reset it. Once a ready interval is observed, a later failure
   can begin a new episode; the code must not spin flushes within one contiguous
   observed non-ready interval.
3. Every production enqueue goes through one helper. It performs a preflight,
   applies readiness backpressure to ordinary frames, enqueues under the
   reentrancy guard, and then **always** performs a second bracketed live-state
   evaluation. This unconditional postflight is required because a
   notification on another thread can be blocked on `_displayLayerLock` while
   the renderer's state has already changed.
4. If postflight flushes the just-enqueued sample, resubmit that exact sample
   once. A second revoke/failure returns retryably rather than claiming
   success. Overlay and recovery replay are each a bounded single-sample use;
   Apple documents enqueue while not ready as safe but warns against doing it
   without bound.
5. Increment `successful_submission_count`, replace the recovery sample, and
   publish the latest uncomposited overlay base only after the final postflight
   validates the exact attempt. A flushed, rejected, stale-generation, or
   readiness-blocked attempt must change none of those accepted-only facts.
6. Recovery replay creates a new image-buffer sample with invalid duration,
   PTS, and DTS and sets `kCMSampleAttachmentKey_DisplayImmediately`. It must
   not reuse the cached sample's stale presentation timestamp.
7. Preserve strict-frame ordering: display/submission decision, synchronous
   video-clock update only on proven success, display-lock release, then the
   one terminal callback. A permanent renderer failure reaches the strict
   request as a non-success terminal; it is never a successful drop.

### Purge and discontinuity boundaries

1. A false purge follows a rejected strict/backpressure submission. It resets
   only the immediately preceding submission status. Because rejected samples
   are never cached or published, it preserves the last renderer-accepted
   recovery sample, uncomposited overlay base, base-frame sequence, accepted
   overlay-submission epoch, and any safe in-flight overlay transition.
2. A true seek/reset/replace discontinuity clears both retained recovery
   representations, advances the overlay refresh generation, base-frame
   sequence, and accepted-submission epoch, flushes the renderer queue, and
   resets the recovery boundary. A pre-boundary refresh or delayed UI commit
   must become ineligible before the callback returns.
3. `discontinuity_flush_count` is separate from bounded recovery flushes. A
   release checker must not infer a decoder-resource revoke from a seek/reset
   flush.

### Requested and renderer-accepted overlay modes

1. `overlayCompositionEnabled` is the PiP controller's requested mode;
   `overlayUICompositionEnabled` is the mode represented by the latest
   validated renderer sample. The sibling subtitle view follows the latter,
   not a request whose transition sample was rejected.
2. Publish an uncomposited base only with an accepted normal sample. A paused
   mode change may build one `DisplayImmediately` transition from that base,
   but it must match both the captured base-frame sequence and refresh
   generation while holding `_displayLayerLock` immediately before enqueue.
   The outer generation check alone is insufficient because the block can wait
   on the lock while a newer subtitle snapshot advances the generation.
3. Track an accepted-submission epoch for every validated normal or refresh
   enqueue. Main-thread UI commits bind to this epoch, not just the base-frame
   sequence; multiple paused refreshes can reuse one base, and an older normal
   commit must not overwrite a newer refresh commit.
4. If composition of a nonempty overlay fails, the accepted normal sample is
   explicitly an uncomposited fallback. Commit the accepted UI mode as false so
   the sibling remains visible, then independently schedule one bounded retry
   if the requested mode is still true. Do not hide the sibling merely because
   the renderer accepted the video sample.
5. Only a true discontinuity or close invalidates a safe in-flight accepted
   overlay transition. A routine false purge must not manufacture a missing or
   duplicate subtitle state.

## Public v5 recovery telemetry

`swiftvlc_libvlc_pip_extensions_version()` returns 5. ABI version 1 of
`swiftvlc_sample_buffer_renderer_snapshot_t` is 136 bytes with 8-byte
alignment. Its fields have the following qualification meanings:

- `display_generation` identifies one installed renderer. Never subtract
  counters across generations.
- With multiple supported vouts, the public getter returns the coherent
  snapshot having the newest process-global display generation; it does not
  aggregate unrelated renderer lifetimes.
- `requirement_notification_count` counts all delivered requirement-change
  notifications. `revocation_notification_count` counts callbacks that still
  observed `requiresFlushToResumeDecoding == true` after acquiring the lock.
  A true notification can wait behind a render transaction that already
  observed and flushed the revoke, so the revocation-notification counter is a
  truthful subset, not the sole proof of a real revoke.
- `recovery_episode_count` and `recovered_episode_count` are episode watermarks.
  Equality means no episode remains outstanding after a validated submission
  or reset boundary; it does not itself prove pixels became visible.
- `recovery_flush_count` is the sum of bounded revocation and ordinary-failure
  flush episodes, excluding discontinuity flushes. `revocation_flush_count`
  proves a live requires-flush state initiated the bounded flush;
  `failure_flush_count` covers ordinary Failed status.
- `successful_submission_count` counts postflight-validated enqueue commits
  from normal frames, overlay transitions, or recovery replay. It is **not** a
  displayed-frame or visible-pixel counter.
- `recovery_submission_count` counts validated submission events that close one
  or more outstanding recovery episodes. One event may close multiple episode
  watermarks, so it must not be required to equal `recovery_episode_count`.
- `retryable_submission_count` counts sample-buffer submissions rejected before
  a validated commit. `recovery_sample_failure_count` counts failures to build
  the immediate replay sample. `permanent_failure_count` counts Failed states
  that remained failed after their bounded flush.
- Current-state flags report current renderer identity, live requires-flush and
  Failed state, outstanding recovery, and whether a replay sample is retained.

For a real resource-revocation qualification row, take before/after snapshots
from the same `display_generation`. Require a real requirement notification and
a positive `revocation_flush_count` delta, no new permanent failure, cleared
live Failed/requires-flush/recovery-in-progress flags, and a recovered watermark
that catches the episode watermark. Do not require the callback-time
`revocation_notification_count` to increase if the independently proven
revocation flush won the lock race. A synthetic notification or a foreground
round trip with no OS revoke is not evidence and is inconclusive.

## Audited non-device evidence

The final read-only audit was run against the isolated candidate whose
`VLCSampleBufferDisplay.m` SHA-256 was
`eb2501f56f86aa8612287a1381c4d587953781dc648cf08ab0b39a0f323a1f0e`.
All of the following passed:

- `git diff --check`;
- Objective-C `-fsyntax-only` for 13 slices: macOS arm64/x86_64; Catalyst
  arm64/x86_64; iOS device arm64 and simulator arm64/x86_64; tvOS device arm64
  and simulator arm64/x86_64; visionOS device arm64 and simulator
  arm64/x86_64;
- Clang static analysis of `VLCSampleBufferDisplay.m` on macOS;
- direct syntax checks of `lib/media_player.c` and
  `src/video_output/video_output.c`;
- C11 and C++17 public-ABI probes asserting size 136, alignment 8, flags offset
  4, `permanent_failure_count` offset 128, and the exported function type;
- ASan/UBSan recovery-state execution covering all `6^8 = 1,679,616`
  eight-action paths plus 1,000,000 deterministic randomized actions; and
- a host AVFoundation probe that constructed an image-buffer sample with all
  timing fields invalid, attached `DisplayImmediately`, enqueued it into an
  actual `AVSampleBufferDisplayLayer` renderer, and flushed without a Failed
  status.

The state test validates deterministic mechanics and memory safety against its
model; it does not independently validate AVFoundation's lifecycle. The host
sample probe validates construction and immediate renderer acceptance; it does
not prove on-glass presentation. The primary API authority for these semantics
was the installed Xcode 26.5 SDK's `AVSampleBufferVideoRenderer.h` and
`AVQueuedSampleBufferRendering.h`.

## Release-blocking physical-device checklist

Run these rows against the exact candidate archive and record device model,
exact OS build, asset hash, library/archive hash, start/end snapshots, terminal
events, captured pixels, and logs. A beta-OS iPhone is useful exploratory
evidence, but it is not a stable-OS compatibility row.

1. **Playing revoke/recovery.** Use a numbered, high-contrast frame-fingerprint
   fixture. Background with audio enabled long enough for the OS to revoke
   decoder resources, return active without replacing the `Player`, and prove
   the same-generation telemetry conditions above. Independently capture the
   video surface and require a post-recovery fingerprint advance with no stale
   pre-recovery frame reappearing. If the OS does not revoke resources, mark
   the attempt inconclusive and retry; playback survival alone cannot pass.
2. **Paused revoke and strict step.** Pause on a known fingerprint, force or
   observe a real revoke, return active, and verify the paused image is restored
   without stale PTS delay. Issue one request-correlated strict frame step and
   require exactly one matching terminal plus exactly one next fingerprint.
   Telemetry enqueue deltas are supporting evidence only.
3. **Readiness/backpressure.** Saturate the renderer enough to observe a
   retryable normal submission. Require no success/cache publication for the
   rejected attempt, no late appearance of its fingerprint, bounded CPU, and a
   later independently visible accepted frame. A strict target must receive one
   non-success terminal rather than a fabricated success.
4. **Ordinary Failed status.** Exercise a non-revocation Failed status if a
   deterministic device fault hook is available. Require one failure-flush
   episode, then either recovery after the flush or one permanent-failure count
   and one strict error terminal. Require no flush loop and no success count for
   a postflight-invalidated attempt.
5. **Seek/reset/replace.** Test seek backward/forward, stop/start, media
   replacement, and explicit strict cancellation separately. True boundaries
   must increase the discontinuity-flush counter and prevent every old
   fingerprint and overlay transition from appearing after the new target.
   False purges must not destroy the last accepted paused image or a safe
   in-flight PiP transition.
6. **PiP and overlay ordering.** While playing and paused, enter/exit PiP and
   toggle embedded composition with changing subtitles. Require no duplicate
   sibling/embedded overlay, no missing subtitle after an accepted fallback,
   and no stale snapshot after a newer refresh generation. Inject compositor
   failure if possible: the video fallback may be accepted, the inline sibling
   must remain visible, and only a later accepted composed transition may hide
   it.
7. **Synchronous/reentrant lifecycle stress.** Repeatedly background/foreground,
   enqueue, seek, close, and replace media while notifications are pending.
   Require old-generation callbacks to remain inert, no deadlock, no duplicate
   enqueue, no use-after-free, and a usable replacement renderer. Run with the
   strongest device diagnostics available and retain the crash/hang artifacts.
8. **Multiple vouts.** If the app can create more than one supported vout,
   record each creation/replacement and verify the public getter selects the
   newest display generation exactly as documented. Do not combine counter
   deltas from different generations.

For a paused renderer, `copyDisplayedPixelBuffer` can be used as a direct pixel
oracle where available. Apple's SDK says it returns NULL while the render rate
is non-zero, so playing rows require screen/video capture or another independent
on-device pixel oracle. `successful_submission_count`, VLC displayed-picture
statistics, simulator output, elapsed-time bounds, and source inspection are
never substitutes for decoded physical-device pixels.

Passing the host gates makes the candidate eligible for device qualification.
Passing telemetry without the visible-pixel rows leaves recovery **PENDING
(device-only)** and blocks release qualification.
