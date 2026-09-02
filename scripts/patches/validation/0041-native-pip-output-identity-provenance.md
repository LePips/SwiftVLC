# Native PiP output identity provenance (patch 0041)

Patch: `0041-native-pip-output-identity.patch`

Reviewed SHA-256: `3587daa9ccd017cf109e3c809315b09e8f378d63b8d17600bd6c0366dbd750c8`

Pinned VLC base: `c833c4be000b426d73ff4324bec574065f00e3df`

## Source boundary

The patch changes exactly these eight PiP-owned paths:

1. `include/vlc/libvlc_media_player.h`
2. `lib/libvlc.sym`
3. `lib/media_player.c`
4. `lib/media_player_internal.h`
5. `modules/video_output/apple/VLCDrawable.h`
6. `modules/video_output/apple/VLCPictureInPictureController.m`
7. `modules/video_output/apple/VLCSampleBufferDisplay.m`
8. `modules/video_output/apple/vlc_pip_controller.h`

It does not overlap patch 0042's demux, adaptive-streaming, MP4, or native-test
paths.

## Identity and ownership contract

- Swift publishes a nonzero, process-unique native-handle identity and a
  nonzero playback generation before an output can open. The native setter is
  idempotent for the exact current pair, rejects a changed handle or generation
  regression, and retains every published immutable snapshot until the media
  player and its outputs have joined.
- `CreatePipController` retains the drawable, copies the immutable playback
  identity, and allocates a process-unique nonzero output identity before module
  mapping. The allocator permanently saturates before `UINT64_MAX`, which is
  reserved as a claimed-token sentinel; it never wraps or reuses history.
- Version-9 module Open requires the complete exact selector surface. A
  preserved controller is claimed before rebind. A fresh controller is claimed
  after successful initialization and is rolled back by its exact unclaimed
  output identity if construction fails. Both flows arm preparation timeout
  ownership before publishing `p_sys`.
- Delayed presentation captures an immutable controller plus all three identity
  scalars. Preparation and handoff use separate exact CAS tokens. Ready,
  cancel, close, and timeout validate the controller and complete triple, so a
  late predecessor cannot mutate or wake its successor.
- The v9 module never falls back to generation-only readiness or the former
  time-window seek permit. Invalid identity or missing lifecycle selectors fail
  Open closed.

## Deterministic source and race proofs

Run the source proof against a clean replay after applying the complete ordered
patch series:

```sh
python3 -B scripts/patches/validation/native-pip-output-identity-source-check.py \
  /path/to/replayed/vlc \
  scripts/patches/0041-native-pip-output-identity.patch
```

The proof locks the patch digest and eight-path inventory, checks the
transaction and ordering invariants above, and must reject all 24 adversarial
source mutations.

The portable C11 race model stress-tests concurrent unique allocation,
permanent allocator saturation, ready-versus-preparation-timeout,
successor-take-versus-handoff-timeout, delayed predecessor timeout, and
close-before-prepare exactly-once behavior:

```sh
cc -std=c11 -O2 -Wall -Wextra -Werror -pthread \
  scripts/patches/validation/native-pip-output-identity-race.c \
  -o /tmp/native-pip-output-identity-race
/tmp/native-pip-output-identity-race
```

Both proofs are also invoked by `scripts/validate-native-patch-series-source.sh`.
