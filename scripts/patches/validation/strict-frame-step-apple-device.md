# Strict frame-step Apple output qualification

The host-side source and archive probes prove callback ordering, exact terminal
cardinality, vmem submission acknowledgement, and the structural rule that
`VLCSampleBufferDisplay` never retains a sample whose submission result is not
success. They do **not** prove which pixels AVFoundation ultimately presents.
The following physical-device row is therefore a release-blocking qualification
for 1.1.0 and remains pending until it is run against the exact candidate
archive on the paired iPhone.

## Fixture

Use a constant-frame-rate asset whose every video frame contains both:

- a machine-readable frame number in a fixed crop; and
- a unique high-contrast RGB fingerprint derived from that frame number.

The expected frame number and fingerprint must be derivable from the strict
terminal's `request_id`-matched `time_us`; do not infer identity from wall-clock
delay or the player's later generic time getter.

## Missing-layer / reset / immediate-reuse sequence

1. Keep the native sample-buffer display layer absent and accept strict request
   A. Record A's exact terminal ID and require a negative submission status.
2. Perform each causal boundary separately: explicit cancel, seek, stop/start,
   and media replacement. Wait for the documented terminal/barrier where the
   operation has one, but do not insert an arbitrary settling delay.
3. Install the layer and immediately accept request B on the reusable native
   slot. Require exactly one B terminal with status success.
4. Capture the video region from the physical device from the boundary through
   B's terminal and at least two display refreshes after it.
5. Decode every captured frame. A's fingerprint must never appear after its
   negative terminal/boundary. The first newly submitted frame must be exactly
   B's `time_us`-derived fingerprint; no older pending sample may appear before
   or after B.
6. Repeat with overlay composition enabled and disabled. An asynchronous overlay
   refresh must not resurrect A after the purge generation changes.

Run a second race row with A held at the native pre-submission arbitration
boundary. If explicit cancellation wins, require `-ECANCELED`, immediate B
acceptance, and zero A pixels/submissions. If renderer commitment wins, cancel
must return false, B must remain busy until A's exact terminal is delivered,
and A's fingerprint may appear only as the committed A output. A committed
picture must never be relabeled canceled.

Passing requires exact request ID, exact terminal count, exact decoded frame
identity, and zero A pixels after the boundary. Aggregate time bounds,
`displayedPictures`, a source substring check, simulator output, or a short
duplicate-observation window are not substitutes for this device proof.

## Non-device gate status

The source-linked host gate must compile the real Objective-C module and check
the actual production path, not a stand-alone state model:

- missing layer/readiness exits occur before any `latest*` publication;
- the sole `latestUncompositedPixelBuffer` publication follows the exact
  `[renderer enqueueSampleBuffer:]` call under `displayLayerLock`;
- prewarm/overlay refresh can observe only that committed publication;
- rejection, explicit-cancel cleanup, and discontinuity all invoke the real
  `purge_picture_submissions` hook under the display lock; and
- close/purge invalidate `overlayRefreshGeneration`, frame sequence, and the
  retained base buffer before a new generation can submit.

Until the device row above passes, the non-device validator must report Apple
pixel identity as **PENDING (device-only)**. Compiling the Objective-C module and
checking the synchronous purge/no-retention source invariants establishes only
that the candidate is eligible for device qualification.
