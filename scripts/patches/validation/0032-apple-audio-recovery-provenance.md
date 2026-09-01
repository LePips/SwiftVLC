# Apple audio media-services recovery provenance (patches 0032–0033)

## Source baseline

- VLC source pin: `c833c4be000b426d73ff4324bec574065f00e3df`.
- Patch 0032 is generated after SwiftVLC patches 0001–0031 and owns the
  media-services Lost/Reset graph rebuild, causal playback gate, resource-wide
  command broker, read-only recovery evidence, broker-serialized Apple graph
  destruction, ARC-correct orphan snapshot ownership, and safe retirement of
  stale reset-epoch lease records.
- Patch 0033 owns the process-wide AVAudioSession management policy and the
  exact-token application/PiP ownership lease. It does not weaken patch 0032's
  user-action gate under application-managed policy.
- Frozen patch SHA-256 values after a clean pinned-series replay are:
  - `0032-audio-media-services-reset.patch`:
    `299dcf69856805872e803c44e84826d95c39e4eea5876bf1cc0d01de3f99b8c4`
  - `0033-apple-audio-session-policy-leases.patch`:
    `2b8f68dd496463bc69d915b05feb6f484ddeb674af991405faa5205c2204db74`

## Primary platform requirements

- Apple documents `mediaServicesWereResetNotification` as requiring apps to
  rebuild audio objects and restore session configuration, while explicitly
  forbidding playback, recording, or processing from restarting before user
  action:
  <https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification>
- Apple Technical Q&A QA1749 calls the old objects orphaned, requires their
  disposal and recreation, says the session must not become active without
  user action, and identifies Settings > Developer > Reset Media Services as
  the physical test mechanism:
  <https://developer.apple.com/library/archive/qa/qa1749/>
- Apple describes `mediaServicesWereLostNotification` as an earlier optional
  cue. Most apps only need Reset, so physical release evidence records Lost but
  gates on Reset plus the native reset epoch/quarantine:
  <https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswerelostnotification>

## Pinned-source audit findings

1. `avsamplebuffer` has audio-output priority 100 and is the default Apple
   output; `audiounit_ios` has priority 99. Both paths therefore require the
   same reset quarantine and retry semantics.
2. Neither output observed Lost/Reset or rebuilt its invalid Apple graph.
3. Core playback can remain `PLAYING` across a media-services reset. Decoder
   `Pause(false)`, interruption-ended, route changes, Start after output
   restart, and buffered data are not proof of post-reset user intent.
4. A media player can own a cached output and additional busy outputs. A
   callback aimed only at `HoldAout()` cannot recover every participant.
5. AVAudioSession is process-global. Per-module static reference counts and
   direct `setActive:NO` calls can deactivate another live player; the old
   static reference count also began with a phantom owner.
6. AudioUnit render callbacks and AVSampleBuffer queue blocks can outlive
   Stop/Close unless their refCon/object access is invalidated and drained.
7. A snapshot followed by direct AudioUnit/ARC/CF destruction is not a safe
   Lost boundary: publication can race the final release. In addition,
   `AudioComponentInstanceDispose` can fail while the unit still owns its
   render refCon, so freeing the invalidated context on failure is a UAF.

## Frozen native contract

- A libvlccore Darwin broker assigns one nonzero monotonic epoch to each unique
  Lost/Reset notification and coalesces the same notification object across
  the broker and every output observer.
- Lost immediately silences the output and makes Apple graph calls unavailable.
  Invalid objects closing during Lost are transferred to the broker and
  released only after Reset.
- The serialized process broker is the sole final-destruction boundary for
  AudioUnit and AVSampleBuffer graph objects. AudioUnit Stop, failed Start,
  Close, and reset teardown invalidate and transfer the unit/context pair;
  AVSampleBuffer detaches renderer, synchronizer, format description, and time
  observer under its lifecycle lock and transfers explicit +1 references.
- A failed `AudioComponentInstanceDispose` retains the already-invalidated
  unit and render context together and attempts it at most once per later
  Reset. Only successful disposal destroys the context. This intentionally
  prefers a bounded, retryable safe leak over freeing callback state still
  owned by Apple.
- Reset reconstructs the graph inactive and arms a persistent
  `waiting for explicit resume` latch. The latch survives output Stop→Start,
  media-player Stop/new media, media-list activity, renderer changes, and
  output reincarnation through an input-resource-scoped causal command broker.
- Only an accepted public Play, `set_pause(0)`, or resume-direction toggle may
  publish an exact `(generation, reset_epoch)` token. Dispatch occurs after the
  player lock is released and broadcasts to every live output. Internal pause,
  teardown, automatic playlist progression, and decoder activity invalidate or
  fail closed without authorizing recovery.
- Each output consumes one attempt. Activation, graph start, or exact-token
  acknowledgement failure retains quarantine and requires a newer user command.
- A terminally failed command can never become acknowledged merely because its
  final output unregisters. The video-only/no-output acknowledgement remains
  bounded to a nonterminal exact generation and is revoked if an output joins.
- `--apple-audio-session-management=library|application` is registered in the
  core configuration on every slice. Application-managed mode performs no
  category, mode, preference, activation, or deactivation mutation, but still
  rebuilds the invalid graph and enforces the reset user-action latch.
- Library-managed native outputs and SwiftVLC's video-only/PiP lease share one
  broker owner domain. Leases are opaque, owner-bound, epoch-bound, one-shot,
  and immune to stale, foreign, or duplicate release. A serialized acquire
  retires stale records from older epochs so repeated Reset/reacquire cycles do
  not grow the opaque-token table.
- AVSampleBuffer interruption work transfers its callback lifetime to a
  dedicated serial queue before taking the output lifecycle lock. This keeps
  synchronous AVAudioSession notification re-entry out of the broker/output
  lock order and avoids sharing a queue with reset callback drains.
- The v8 read-only snapshot is safe with no output and never starts, activates,
  or rebuilds playback. Callers must initialize its exact version and size;
  unsupported or unstable layouts fail closed without writes.

## Verification boundary

Validation asset pins for the composed version/archive proof are:

- `audio-media-services-reset-source-check.py`:
  `790cdcda875ea0d63afe4feabb7842059c4a83302123556b50ace549e9c74365`
- `validate-audio-media-services-reset.sh`:
  `410817cf391d1f0ce726b02eb29a2e5cdf78996521e1b4c3955f138f02df1622`
- `pip_extension_version.py`:
  `98adb898d64ed8c8a57bbc883bf10dd96eeb399a2f7671c1d2fceb262fad63b5`
- `native-extension-version-probe.c`:
  `8f5ddbc3858ba25242a6a72e3e4253a1d3fb3b82603536e0e0f5013eabaa610c`
- `validate-native-extension-contract.sh`:
  `90b7fb271c616ceb2211b8d98937da8fb67af34d017c19214e1da68942389ce0`

The source validator performs structural checks, one deliberate negative
mutation per gate, ABI parity checks, bounded-exhaustive two-owner/two-output
state exploration, and long deterministic retry/reset sequences. The shell
wrapper adds exact ARC-enabled Apple Objective-C/C syntax against a configured
slice. `build-libvlc.sh` runs the portable proof before architecture
compilation and repeats it with configured Apple syntax as a postflight; it
does not replace the physical oracle.

The ordered patch manifest owns extension version 8 and separately requires
the patch 0033 audio-session lease refinement. A shared source-composition
resolver proves every additive group from version 4 through version 8, exact
vendored-header parity, the literal version implementation, and the complete
lease declaration/implementation/export group. Its adversarial suite rejects
partial groups, duplicates, gaps, comment/string decoys, computed or
side-effecting version returns, unknown successors and a whole missing 0033
group when leases are required.

After the final archive mutation, the artifact gate inventories every library
and architecture declared by the XCFramework `Info.plist`. Each must contain
exactly one strong text definition of every symbol owned through version 8,
the complete required lease group, and no partial or future group. The host
macOS slice additionally executes a signature-checked version probe that
strong-links every entry point. Release preparation requires that exact
version-8-plus-leases contract again. The source replay, clean build and
release paths also verify the exact hash and executable-mode inventory of
every validator asset before using it as evidence.

Release credit additionally requires operator-retained evidence from a real
iPhone using Settings > Developer > Reset Media Services. Evidence must show
the Reset notification, a newer native reset epoch, quarantine with no buffer
advancement before fresh intent, the exact dispatched/acknowledged command,
successful graph reconstruction, and buffer advancement only after that intent.
Lost count and ordering are recorded but are not a release gate because Apple
documents Lost as optional for most applications.
