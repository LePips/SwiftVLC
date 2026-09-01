# Device qualification records

System Picture in Picture, native video output, audio teardown and real libVLC
playback cannot be validated by CI. It compiles the iOS tests but never executes
system PiP on hardware, and the sanitizer job links a *released* xcframework
rather than the engine under test. The physical-device matrix and versioned
feature policy therefore form the acceptance gate, and `release.sh` refuses to
publish a stable artifact unless both are complete.

## Running the matrix

For day-to-day and release-candidate use, start with the profile runner. It
resolves and pins one connected physical device, invokes the candidate-bound
runner below, and writes machine-readable, Markdown, and standalone HTML
feature checklists beside the raw report:

```bash
./scripts/qualification/qualify.sh --list-profiles
export SWIFTVLC_DEVELOPMENT_TEAM=ABCDE12345  # team shown in Xcode Settings
./scripts/qualification/qualify.sh smoke --device "My iPhone"
./scripts/qualification/qualify.sh full --device "My beta iPhone" --exploratory-current-only
./scripts/qualification/qualify.sh full --device "My iPhone" --require-stable
./scripts/qualification/qualify.sh release --device "My iPhone"
```

The profiles make different claims rather than treating every green command as
a release qualification:

| Profile | Typical current-iPhone time | Claim |
|---|---:|---|
| `smoke` | ~15 minutes | Fast real-device confidence while developing. |
| `full` | ~60 minutes | Broad functional release rehearsal on one device. Endurance, receiver, and other unexecuted features remain visibly `NOT RUN` or `BLOCKED`. |
| `release` | ~8.5 hours | Every automated matrix lane applicable to that stable device, including the unshortened performance and two-hour soak requirements. |

Times are planning estimates, not timeouts. The release profile automatically
omits `iphone-current`-only lanes on other matrix devices; it does not weaken or
shorten them. Its validator derives every automated runner lane from the
feature manifest and adds the mandatory analyzer, UI/support, performance, and
endurance lanes, so editing the profile cannot silently omit one. Run it for
every required hardware/OS row and assemble the
candidate-bound reports as described below. A passing run proves its selected
device only. It neither sets the repository-wide release gate nor publishes a
release. Unlike `smoke` and `full`, the `release` command also exits non-zero
when any applicable required feature is failed, not run, or blocked. Known
receiver and lifecycle gaps therefore keep it red until trustworthy evidence
exists; completing only the currently automated rows is not enough.

`smoke` and `full` may run on a beta OS for exploratory feedback. Add
`--require-stable` when the environment itself must qualify. The `release`
profile always requires a stable OS that matches `matrix.json`; it rejects an
exploratory device before building. A future iPhone OS can exercise current-only
lanes with `--exploratory-current-only`, but the resulting report remains
ineligible for release.

### Ninety-second cadence semantics probe

Before spending ten minutes on the candidate-bound cadence row, run the
isolated physical probe against the connected iPhone. First choose a writable
root on your external SSD:

```bash
export SWIFTVLC_QUALIFICATION_ROOT="/absolute/path/on/your/external-ssd/SwiftVLC-Qualification"

./scripts/qualification/run-device-tests.sh \
  --only cadence-semantics-probe \
  --development-team ABCDE12345 \
  --device "My beta iPhone" \
  --exploratory-current-only \
  --derived-data "$SWIFTVLC_QUALIFICATION_ROOT/DerivedData" \
  --work-root "$SWIFTVLC_QUALIFICATION_ROOT/Tmp" \
  --fixtures "$SWIFTVLC_QUALIFICATION_ROOT/Fixtures" \
  --output "$SWIFTVLC_QUALIFICATION_ROOT/Cadence-Probe-Results"
```

This is a report-only engineering probe. It samples exact five-second windows
for 24@0.5x, 60@1x, 30/50/59.94/60@2x, and VFR@0.5/1/2x after settling. The
retained JSON contains exact monotonic boundaries, effective player and
control-timebase rates, the lossless native PTS-delta histogram, callback
submission/rejection conservation, renderer and libVLC counters, and three
uptime-bound SpringBoard frames per window. The runner requires this scenario
to execute alone, refuses `--require-stable`, never materializes a qualification
row, and marks both its attachment and top-level report as non-release-credit.

Each session contains `session.json` plus the device runner's `report.json`,
`feature-checklist.json`, `feature-checklist.md`, and
`feature-checklist.html`. `PASS` means the requested candidate-bound evidence
was observed; `FAIL` means an executed requirement failed; `NOT RUN` means the
profile did not execute it; and `BLOCKED` means trustworthy automation or an
external prerequisite such as a real receiver is not yet available. These
states are intentionally distinct so a skipped or unimplemented feature can
never become a false pass.

An existing per-device report or assembled release record can be rendered
again without rerunning hardware:

```bash
python3 scripts/qualification/feature-checklist.py \
  --input /absolute/path/to/report.json \
  --output-dir /absolute/path/to/checklist
```

Add `--require-complete` only when checking whether every applicable required
feature passed; the renderer still writes all three reports before returning a
non-zero status. `matrix.json` is the fail-closed scenario and evidence policy;
`feature-manifest-v1.json` is the higher-level product promise policy.
`check-qualification.sh` enforces both for a stable release. The canonical set
of required feature IDs is also immutable in the shared release policy (for
example, `frame-step-exact-presentation` cannot be deleted or downgraded to
advisory by editing the manifest alone).

The feature manifest also carries a dated `upstreamRiskReview`. Each known VLC
or VLCKit regression maps to one or more required checklist features, so a
closed upstream issue cannot be mistaken for candidate evidence and an open
issue cannot disappear from the release conversation. Generated Markdown and
HTML checklists link those risks beside the affected feature. Cheap binary
invariants live under `staticControls`; the renderer/Chromecast archive and
native extension-version controls run in CI and in every beta,
candidate-preparation, and stable release path. The latter binds patch intent,
final native source, vendored headers, and exactly one strong definition of
every version-owned symbol in every declared XCFramework slice and
architecture; an older migration artifact may remain usable through shims but
cannot satisfy candidate evidence for a newer extension version.
The 1.1 policy also sets `requiresFreshUpstreamRiskReview`: validation fails
after the manifest's review-age limit, forcing another upstream scan if the
release work extends beyond the evidence's useful lifetime.

Refresh the snapshot deliberately from VideoLAN's official API:

```bash
python3 scripts/qualification/audit-upstream-risks.py
```

The command fails on issue state or identity drift. Read every changed issue
and adjust its required feature obligations before updating `reviewedOn`; the
date is a review attestation, not an automated timestamp.

`matrix.json` lists the required scenarios and hardware. A scenario without a
`hardware` list runs on every hardware row; focused performance, soak, and
failure scenarios name the exact hardware they require. The immutable release
policy pins every canonical scenario/hardware tuple. Simulator runs never
satisfy a row: PiP is force-disabled there, and a simulator can report PiP
active while its window stays black.

The matrix covers the device-only acceptance criteria of every open v1.1.0
milestone issue, not only the original functional PiP matrix. Long-running
scenarios declare `minimumDurationSeconds`, and performance/failure scenarios
declare the non-empty fields their evidence JSON must contain. This makes the
release gate reject a brief smoke run or an evidence attachment that omits the
metric the issue asked us to qualify.

The matrix can also constrain the meaning of evidence, not just its presence.
`expectedEvidenceValues` requires an exact value (for example zero crashes),
while `allowedEvidenceValues` accepts one of a documented set (for example a
replacement session must be either preserved or boundedly re-engaged). This
prevents a passing row from carrying evidence that actually records an
unsupported feature, a regression, or a failed acceptance condition.
The original cross-device PiP rows apply the same rule to each control,
lifecycle order, recovery path, and stop reason; a top-level `result: "pass"`
cannot mask a failed pause, missing restoration, or unsuccessful recovery.

### Physical-device lane

Once a device is connected, unlocked, trusted, and has Developer Mode enabled,
the smoke and regression lanes are unattended except for the explicitly
operator-assisted media-services reset row described below. They do not
require iPhone Mirroring or ask an operator to copy observations out of the
app.
The host needs Xcode command-line tools, Python 3, `jq`, and FFmpeg/FFprobe;
FFmpeg is used both to create fixtures and to decode-sample the release oracles
before any device result can be accepted:

The verifier does not trust descriptive fixture-manifest claims by themselves.
It applies hard-coded probe and decode contracts to every release-significant
class: VOD, live, audio, transport-stream and fragmented-MP4 HLS, a large
content-coded progressive MP4 with a fixed ten-second GOP and byte-size floor, real
1080p60/4K60 performance media, CFR/VFR cadence, text/ASS/bitmap/forced/live
subtitles, and HDR signalling. The exact fixture-manifest checksum is carried
from candidate metadata through every report, evidence attachment, and final
record. For example, relabelling a 640x360@10 fps file as 4K60 fails before
device evidence can be accepted.

```bash
./scripts/qualification/run-device-tests.sh \
  --development-team ABCDE12345 \
  --derived-data /absolute/path/to/device-build \
  --work-root /absolute/path/to/temporary-work \
  --output /absolute/path/to/evidence
```

The profile wrapper forwards the same storage controls:

```bash
export SWIFTVLC_QUALIFICATION_ROOT="/absolute/path/on/your/external-ssd/SwiftVLC-Qualification"

./scripts/qualification/qualify.sh full \
  --development-team ABCDE12345 \
  --derived-data "$SWIFTVLC_QUALIFICATION_ROOT/DerivedData" \
  --work-root "$SWIFTVLC_QUALIFICATION_ROOT/Tmp" \
  --fixtures "$SWIFTVLC_QUALIFICATION_ROOT/Fixtures" \
  --output "$SWIFTVLC_QUALIFICATION_ROOT/Results"
```

`--development-team` configures only the disposable exported project. It uses
team-scoped bundle identifiers, enables Xcode's automatic provisioning for that
build, and carries the actual signed app and test-runner identifiers through
the xctestrun, device-container access, candidate metadata, and audio-focus
evidence policy. `SWIFTVLC_DEVELOPMENT_TEAM` is the equivalent environment
setting. The volunteer validator detects an Xcode team and forwards it
automatically; it never rewrites the checked-out project.

DerivedData, generated fixtures, evidence, and disposable source snapshots
default to ignored directories beside the repository. A checkout on an
external SSD therefore keeps the complete qualification workload on that SSD;
the paths remain individually overrideable for other machines.

That default path builds the app and runner from a clean checkout, embeds the
source commit and release-source digest in the signed app, and creates its
candidate metadata automatically. It builds a disposable `HEAD` export against
the exact local `Vendor/libvlc.xcframework`, so remote package resolution cannot
silently substitute an older wrapper or engine. A reused `--candidate-app` or `--skip-build`
requires `--candidate-metadata`; metadata creation succeeds only for an app
that was built with the `SwiftVLCSourceCommit` and
`SwiftVLCReleaseSourceDigest` Info.plist keys. The signed app also embeds
`SwiftVLCArtifactDigest`, and metadata creation rejects it unless that value
matches the complete XCFramework tree supplied to the runner. Use
`candidate-metadata.py source` before an external build to obtain those values,
then `candidate-metadata.py create` after signing to bind them to the app-tree
digest. Candidate metadata also records and verifies the complete XCFramework
tree digest; a signed app cannot be paired with evidence naming a different
engine artifact.

Format-version 2 candidate metadata also binds the actual signed candidate and
UI-test-runner bundle identifiers, the complete signed UI-test runner tree, the
one embedded `.xctest` bundle, the selected base `.xctestrun` file, and the
exact non-empty leaf-test catalog enumerated for the pinned physical device. If
the build produces more than one `.xctestrun`, the runner fails unless
`--xctestrun` selects one explicitly. Reused/prebuilt candidates are not trusted
from their metadata: all of these trees, files, catalogs, and policy manifests
are recomputed before testing.

`matrix.json` owns the immutable runner contracts that map each runner lane to
its exact XCTest selection, qualification scenarios, and attachment names.
Every qualification scenario has exactly one authorized producer. The general
`ui-suite` selection is the candidate catalog minus matrix-owned device-test
class prefixes; the shell derives its `-skip-testing` arguments from that same
contract, and report validation recomputes the exact resulting leaf catalog.
Each output also names its authorized XCTest leaf or leaves. The host validates
the attachment manifest's `testIdentifier` and `testIdentifierURL`, normalizes
the current Xcode short-name/URL pair to a full leaf identity, and rejects a
missing, conflicting, sibling, or cross-output owner. An unrelated passing
XCTest, a substituted runner, or a catalog absent from the candidate catalog
cannot underwrite a qualification row.

The command identifies the physical device and OS release type, generates and
serves deterministic local media, installs the exact signed candidate and UI
test runner, executes the analyzer, general UI stress suite, native/direct live
PiP, same-player continuity, capability convergence, terminal outcomes, the
adaptive HLS soak, both direct-PiP performance rows, HLS seek, and the
current-iPhone seek/frame oracle lane, then
pulls app logs and writes a machine-readable `report.json`. It retains every
attempt log and xcresult,
records and verifies candidate metadata that binds the app tree digest to its
source commit, release-source digest, and XCFramework digest, and retries only
a small allowlist of structured Xcode/device-launch infrastructure failures.
Every scenario, including the analyzer, has a preflight-selected leaf catalog;
after execution its xcresult must contain exactly that same non-empty catalog
and count, with every test passed. Every run reinstalls both exact signed apps;
retry requires a readable structured xcresult that proves no intended Test
Case began. A missing/unreadable result, assertion, fatal/crash/sanitizer or
test-process/product signal remains terminal even when its log also contains
an allowlisted word such as `Busy`. A passing xcresult never overrides a fatal,
crash, abort, signal, sanitizer, assertion, precondition, uncaught-exception,
heap-corruption, or memory-corruption signature in its retained attempt log.
The same immutable product-failure scan covers the complete structured
xcresult, including sibling diagnostics outside the passed Test Case. There
are no free-form harmless-substring exceptions. Each runner has one dedicated
attempt-artifact root; the report binds every ordinal log and xcresult by type,
size, and content/tree digest and rejects missing, extra, renamed, symlinked,
or unreferenced attempt artifacts. A later pass cannot erase an earlier
product failure. The analyzer lane owns the five host-only XCTest classes; the
general UI lane therefore contains only tests that launch the candidate. Every
runner except that analyzer must retain a rebuildable device JSONL inventory;
support runners receive no logless exemption. The host binds that inventory's
exact XCTest catalog one-to-one to filename families derived from the canonical
bundle/class/method leaf IDs and one invocation UUID. Every base file, and every
policy-recognized per-cycle child file, must be nonempty, contain only complete
structured JSONL records, and include the exact synchronous
`swiftvlc.qualification.log-mirror` / `mirror-start/v1` health record with an
ISO-8601 timestamp. Missing-leaf, unknown-owner, empty, truncated, unmarked, or
undeclared child logs fail. The host also inventories every pulled JSONL file
by retained root, raw-file size and digest, injected action or phase, exact
normalized module/message fingerprint, and occurrence count.
Report validation reopens that retained directory and rebuilds the inventory
from bytes; a missing, renamed, added, swapped, symlinked, or type-confused file
fails.
Terminal/adaptive attachments must consume that inventory exactly in both
directions and satisfy an exact structured module-attribution allowlist; an
extra raw diagnostic or a test-only record with no raw counterpart rejects the
evidence.

Raw XCUI motion evidence uses one immutable analyzer contract. The exact video
crop is scaled to 64x36 row-major 8-bit sRGB RGB (no alpha); lowercase SHA-256
hashes cover the `swiftvlc-rgb8-64x36-v1\0` domain prefix, big-endian 64/36
dimensions, and RGB bytes. At least three distinct frames are retained. For
each adjacent pair a pixel changes when any channel differs by at least 12;
the ratio divides changed pixels by 2,304, and the observation score is the
minimum adjacent ratio. Every adjacent ratio must therefore meet the 1%
motion floor—one early change cannot hide a later frozen surface. Derived
adaptive, cadence, and performance motion summaries must reconcile exactly to
these raw hashes and ratios.

The live-media lane runs both native and direct PiP against the same indefinite
local stream. For each backend it verifies ordered start/stop events, AVKit's
unbounded linear-playback policy, three start/stop cycles, sustained real
system-PiP motion while backgrounded, foreground recovery, continued decoded
pictures, and zero library errors. It emits one combined `live-media` row so a
passing backend cannot hide a failure in the other.

The background-audio lane samples libVLC's native audio-output counter twice
inside a timed interval while the application state is actually backgrounded
and native PiP is active. A row is emitted only when played audio buffers
increased during that interval, PiP remained active with ordered lifecycle
events, and the app and host logs contain no library error records.

The continuity lane performs one focused VOD-to-live replacement and a second
VOD-to-live-to-VOD sequence on the same player while native PiP is active. It
records the successor generation, AVKit playback-policy snapshot, first video
and audio output gaps, PiP motion, ordered lifecycle, and any stale successor
event that escaped generation filtering. The two tests materialize independent
`replacement` and `replacement-continuity` rows from the same device run on
`iphone-current`. Other hardware runs only the matrix-wide `replacement` test
and row. Multi-row evidence is committed to the report only after every
expected attachment materializes successfully.

The iPhone-current-only capability-convergence lane runs VOD-to-live-to-VOD
transitions while PiP is active on both the native drawable and direct
sample-buffer backends. A
qualification-only fault injector drops raw length and seekability callbacks
from both independent Player and PiP-controller event consumers, forcing
Player's native polling to publish the capability. The test requires
finite seekable VOD to become interactive, unbounded live media to remain
linear, the successor VOD to become interactive again, the real AVKit skip
path to settle and advance playback, sustained system-PiP motion, and zero
library errors before emitting the combined `capability-convergence` row. The
default run omits this lane on other hardware rows, and an explicit unsupported
request fails before testing rather than producing evidence for an unknown row.

The VOD-controls lane runs on every hardware row and exercises both native
drawable and direct sample-buffer PiP with the real system window active.
Play and pause enter through the backend-specific control bridge, forward and
backward skips wait for their native landed outcome, and an absolute scrub
must settle on the public timeline without stopping PiP. Each backend also
issues a dynamically computed negative relative seek that extends ten seconds
beyond the current position, proves a landing in the 0...2 second boundary
window with a presentation-counter advance, and then proves a subsequent
+3-second command still lands. The host derives every claimed status from the
two retained backend-specific raw clock and presentation-counter records;
top-level pass strings cannot substitute for those observations. Each backend is then
backgrounded and must show sustained system-PiP motion before a programmatic
stop completes the ordered lifecycle. One combined `vod-controls` attachment
is emitted only when every control passes on both backends with zero library
errors or unexpected stops.

The `playback-foreground-displaylayer-recovery` lane runs on
`iphone-current` using the native drawable path. It pauses a real candidate,
uses the OS Home/background/foreground transition (never synthetic
notifications), and requires the same nonzero display generation to observe an
actual resource revocation and complete a balanced recovery. Host policy
decodes the v1 native flags, recomputes every counter delta, enforces the native
counter relationships, and requires the renderer to end current, healthy, and
holding a recovery sample with no permanent failure. An independent XCUI
oracle retains exactly three timestamped canonical 64x36 RGB8 captures of the
real system PiP window. The host replays their domain-separated hashes and
delta-12 changed-pixel scores, so producer-authored checks or mechanics alone
cannot qualify the row.

The long-stall lane also runs on every hardware row. Its local fixture keeps a
continuous MPEG-TS connection flowing until the candidate has entered real
system PiP, then an explicit in-app trigger stalls every active connection for
twelve seconds. Both native and direct backends must publish either the public
stalled/recovered pair or the expected buffering/healthy transition, remain in
PiP, resume moving system-PiP pixels, and complete ordered teardown without
library errors. The app samples its own
resident memory throughout the fault and rejects growth beyond a 96 MiB bound;
the combined attachment records the raw per-backend timings and memory values
as well as the matrix-required recovery and bounded-memory outcomes.

The dismissal lane materializes the matrix-wide `restore` and `close` rows in
one hardware run. For native and direct backends, it starts real system PiP,
uses the moving-pixel oracle to locate the window, reveals SpringBoard's
controls, and taps the restore or close corner by normalized coordinates. This
avoids localized system labels while still exercising the real affordances.
Evidence is emitted only when restore invokes the host callback exactly once,
close invokes it zero times, and public lifecycle events report ordered
`restoreRequested` or `userClosed` reasons respectively. Each of the four app
launches writes a separate library log so an earlier backend/action error
cannot be overwritten by a later cycle.

The interruptions lane runs both PiP backends on every hardware row. The
separately installed XCTest runner activates a non-mixable playback audio
session while the candidate is backgrounded in real system PiP, then returns
focus with `notifyOthersOnDeactivation`; the candidate must observe a balanced
system interruption pair, recover playback, retain PiP, and render moving
pixels. Its libVLC played-audio-buffer counter must also advance beyond the
pre-interruption value, proving audio resumed rather than merely leaving the
player in a nominal playing state. Route-loss behavior is a distinct, explicitly labelled deterministic
injection: the candidate posts an `oldDeviceUnavailable` route-change
notification through the same shared `AVAudioSession` object observed by the
library. SwiftVLC must pause without closing PiP, accept an explicit resume,
and finish with ordered teardown. Evidence records both sources verbatim so a
controlled notification is never misrepresented as a physical Bluetooth
disconnect.

The audio-session ownership lane is a separate physical proof, included in
`smoke`, `full`, and `release`. Every attempt receives its own tokenized,
seekable four-hour HLS timeline, so a retry cannot reuse source state and a
short fixture cannot turn ownership teardown into an end-of-stream result. The
format-version 3 contract first creates idle players without media. It then
runs two library-managed cycles, AudioUnit then AVSampleBuffer and the inverse
AVSampleBuffer then AudioUnit order. Each cycle must show the exact native
owner sequence `0 -> 1 -> 2 -> 1 -> 0`, no lease, no deactivation on the
non-final release, continued media-time and played-audio-buffer progress by the
surviving player, and exactly one successful deactivation on the final release.

The candidate next activates a fully recorded host-configured
`AVAudioSession` and runs both AudioUnit and AVSampleBuffer in
application-managed mode. Category, mode, options, route-sharing policy,
preferred sample rate, preferred I/O buffer duration, preferred channel
counts, ownership, and deactivation counters must remain unchanged while each
module produces real audio progress and tears down. A separately signed XCTest
runner first activates its own runner application into the foreground, then
performs five staged, cross-process non-mixable focus probes: after idle
construction, after each of the two library-managed final releases, and after
each of the two application-managed module releases. Evidence must name the
exact runner bundle, prove the runner was foreground while the candidate was
background, and prove the candidate returned to the foreground afterward;
this prevents a background runner's `cannotInterruptOthers` failure from being
mistaken for product behavior. The runner never treats a background app's
Accessibility snapshot as evidence. Instead, the candidate durably records
each interruption notification on the shared system-uptime clock; host policy
proves every `began` occurred after probe activation and before deactivation,
and every matching `ended` occurred after deactivation and before the
foreground observation. The first three probes must
produce no candidate interruption; the two application-managed probes must
each produce one balanced interruption pair, proving the host-owned session
remained active. After the host explicitly deactivates that session, a sixth
host-release focus probe must produce no new interruption. Retained child logs
must prove selection and successful opening of the exact AudioUnit or
AVSampleBuffer module for all six playback instances, so fallback output or a
relabelled default cannot satisfy the counter checks. The XCTest process never
reads fixture telemetry: local-network permission belongs to each signed app,
so doing that could fail independently of candidate playback. After XCTest has
terminated the candidate, the Mac runner reads the final attempt-token metrics
twice, requires byte-identical quiescent snapshots, and retains the raw JSON
with its SHA-256 and size. Host materialization then requires at least six
successful high-variant MPEG-TS segment requests from the exact four-hour
source namespace and binds that raw file to the same final attempt.

The media-services reset lane is intentionally operator-assisted and runs at
the end of `full` and `release`. It starts simultaneous forced AudioUnit
audio-only playback and forced AVSampleBuffer video playback in native system
PiP, presses Home, and proves the system PiP window is moving. Only after the
test publishes its attempt-token readiness marker does the runner display the
prominent operator instruction. On the connected device, open **Settings >
Developer**, run **Reset Media Services**, and return to the showcase app. The
test waits up to ten minutes for the real reset notification and a new native
broker reset epoch; posting a synthetic notification cannot advance that
epoch. After candidate termination, the Mac runner's retained, double-read
quiescent attempt-token metrics must prove real master, media-playlist, and at
least two successful high-variant MPEG-TS segment requests. The final evidence
binds the raw metrics file, digest, size, attempt ordinal, and token, so merely
receiving the URL or fabricating an XCTest attachment cannot qualify. Apple's
[reset guidance](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification)
defines the reset notification as the recovery signal. The earlier
[media-services-lost notification](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswerelostnotification)
is retained, ordered, and counted when the OS sends it, but is not required.
Before either player receives fresh intent, three seconds of retained counters
must remain frozen with zero owners and leases and an undispatched invalidating
command. One explicit resume must then rebuild both native outputs,
acknowledge the exact reset epoch, restore audio/video counter progress, and
leave the real system PiP window visibly moving. The host independently
replays every notification, epoch, generation, counter, and child-log
invariant before granting the row. A beta-OS run is useful exploratory evidence
but never satisfies a stable release row.

The iPhone-current-only deferred-pause-rejection lane drives the exact AVKit
playback command entry point while a qualification SPI changes only libVLC's
native pause-capability answer. It proves a permanently unpausable input
settles to `rejected` within the production retry bound without a late pause,
a transient three-probe rejection issues exactly one native pause, and newer
play, media replacement, and stop commands cancel pending work. The attached
evidence includes the individual counters and requires truthful AVKit/player
controls, zero endless tasks, zero duplicate pauses, and zero library errors.
The default run omits this lane on other hardware rows, and an explicit
unsupported request fails before testing.

The iPhone-current-only `accepted-start-delayed-failure` evidence row uses the
direct sample-buffer backend to issue a real AVKit start request, requires the
immediate result to be `accepted`, and then sends a deterministic asynchronous
failure through the installed AVKit delegate path. The candidate passes only
when the failure arrives before `didStart`, is the terminal recorded event, and
retains the controller and media generations captured at request time. The
attached evidence records those identities, ordered events, and injected error
domain. This row is materialized only for the iPhone-current hardware row (or
as explicitly non-qualifying future-iPhone exploratory evidence).

The same XCTest always emits both the matrix-wide `failed-start` attachment and
the focused `accepted-start-delayed-failure` attachment. The matrix therefore
owns one `failed-start` runner with an exact `allOutputs` emission contract:
the retained xcresult must contain both attachments from the authorized XCTest
leaf, even on hardware where only the all-hardware row applies. The narrower
record requires exactly one surfaced failure, no successful start, and ordered
events; the additional controller/media attribution fields remain reserved for
the iPhone-current row. `--only failed-start` runs the exercise once and
materializes every applicable row; there is no duplicate runner invocation.

The HLS seek lane is another complete machine-readable matrix slice. It
executes forward, backward, and absolute seeks, measures the return of decoded
video, checks ordered PiP continuity, samples real system-PiP motion after each
seek, verifies inline recovery, and exports an XCTest JSON attachment. The host
materializes that attachment under `evidence/`, adding artifact, source, and
hardware identity fields that the test process is forbidden to provide. The
matching row appears under `qualificationRows` in `report.json`; beta-OS rows
remain exploratory and are rejected by `check-qualification.sh`.

The `seek-frame-oracles` lane runs one exact XCTest on `iphone-current` against
host-served sparse-GOP and all-intra fixtures. It cross-checks typed seek and
frame-request terminals against content-coded frames decoded independently
from video-surface screenshots. The immutable host policy checks absolute seek
targets and clock/pixel agreement, exact +1 and +20 frame relationships, every
submitted frame timestamp, resume-clock agreement, final-frame EOF/no-frame
ordering, complete replacement supersession, and zero library errors. A
self-consistent attachment with shifted targets or frame indices therefore
cannot qualify.

The `progressive-http-range-seek` lane runs on every canonical phone/tablet
row against two tokenized views of the same candidate-bound, 120-second MP4.
The Range endpoint advertises byte seeking and the no-Range endpoint ignores a
Range header, returns 200, and omits byte-range capability. The fixture is at
least 50 MB and is throttled so the command marker's host-measured byte
snapshot proves it was not fully prefetched. The candidate app, not XCTest,
publishes an origin-bound same-attempt marker immediately before its strict
request. The first Range media request begun after that marker must be a
non-empty 206 beginning at or beyond byte 10,000,000; a later qualifying request
cannot hide an earlier probe or pre-seek request. The candidate must publish one
generation-bound strict seek (`pending` then `settled`) and advance native clock
and decoded/displayed output. Three replayable 64x36 RGB8 captures use bounded
pre/post screenshot-uptime intervals rather than pretending the synchronous
screenshot return time is the pixel time. The host reconciles each interval,
native clock, and pixel timeline; intervals longer than one second fail closed.
The fixture carries a second-minute-only cycle block, so 43.5-second pixels
cannot be substituted with the otherwise similar 103.5-second frame. The
no-Range command must throw the exact typed
`invalidState("current media is not seekable")` without dispatching a native
media request, while native clock/output and moving pixels continue.
Every retry gets a separate attempt token/transcript; missing, extra, stale,
cross-attempt, fully-prefetched, pre-marker-only, or post-rejection requests
fail materialization and final record validation.

The `local-file-matrix` and `audio-only-playback` lanes run on every canonical
phone/tablet hardware row. The fixture generator pins five video combinations
(H.264/AAC MP4, fragmented MP4, and Matroska; VP9/Opus WebM; MPEG-2/MP2 TS)
and six audio-only combinations (AAC, ALAC, MP3, FLAC, Opus, and PCM). FFprobe
metadata, decoder output, moving video frames, non-silent audio, and fragmented
MP4 boxes are verified before the manifest is signed. The installed candidate
then downloads the exact manifest bytes, hashes and persists them inside its
own app container, and plays only the resulting `file:` URL. Each attachment
retains the immutable fixture identity, SHA-256/size, one exact media-generation
advance, native state/time/statistics snapshots, and zero library errors from
the host-reopened per-test JSONL. Video results additionally retain three raw
64x36 RGB8 XCUI captures. Their boot-clock timestamps must fall strictly inside
the same fixture's app-measured native-counter window; the host recomputes every
domain-separated frame hash, adjacent delta-12 ratio, and minimum motion score.
Audio results must advance real played-buffer counters and must produce no
video decode/display counters. Labels and self-authored `pass` summaries cannot
satisfy either row.

The `adaptive-hls-soak` lane defaults to 7,200 seconds and runs only on the
`iphone-current` row. Its local origin constructs VOD, event, and sliding-live
playlists from deterministic low/high TS and fragmented-MP4 representations.
It injects discontinuities and one-shot HTTP failures, advances live windows,
and records successful retry, representation-transition, segment, and playlist
telemetry under a unique run token. The candidate cycles every mode without an
operator, samples Mach resident memory and Darwin malloc-zone totals every 30
seconds, and retains the active mode plus read-byte, decoded-frame, and
displayed-picture counters. Every adjacent same-mode sample pair must have a
positive, exactly recomputed progress window; an independently captured XCUI
video-surface observation (three canonical 64x36 RGB frames, SHA-256 hashes,
and both adjacent changed-pixel ratios) must prove motion at least every 60
seconds in every mode. A positive summary beside flat retained counters or
unchanged raw UI frames is rejected. The host attaches Instruments' Allocations template with a rolling
15-minute stack-provenance window once the unique run token proves the exact
candidate has begun playback. The trace tree digest and table of contents are
added by the host to the candidate-bound evidence. The retained `xctrace export`
summary must identify the exact app process/device, contain target-owned rows,
and cover the soak rather than merely contain a non-empty trace directory;
inability to capture or export it fails the row. The app scans native diagnostics for sanitizer signatures and fails on a
20-second unbounded recovery or more than 128 MiB final resident growth. The
attachment explicitly records whether ASan instrumentation was present; a zero
finding never pretends that a normal signed device build was ASan-instrumented.
`SWIFTVLC_ADAPTIVE_SOAK_SECONDS` may shorten an exploratory harness run, but
the matrix rejects any row shorter than 7,200 seconds.

The `pip-render-performance-1080p60` and
`pip-render-performance-4k60` lanes each run for 900 seconds on
`iphone-current`. The fixture generator creates short, local 60 fps H.264
sources at the real decoded dimensions; single-item `MediaListPlayer` loop mode drives
the same underlying `Player` continuously for the run. XCTest
starts direct sample-buffer PiP, backgrounds the app, locates the moving system
window, and repeatedly double-taps its normalized center to exercise the real
SpringBoard resize affordance. The candidate records Mach task CPU time, RSS,
thermal state, source and target geometry, conversion counts, presentation
rate, drops, bounded-pool failures, and the total, average, and maximum measured
wall time of the real Core Image conversion calls while replacing media on the
same player. Conversion timing is qualification-only and adds no clock reads to
the normal client hot path.
The runner sequentially attaches Instruments Game Performance, Power Profiler,
and Time Profiler captures, exports each table of contents, and binds every raw
trace tree digest into the evidence. The raw trace bundles and their exported
tables of contents are retained with the final qualification record and their
digests, target-owned numeric tables, sampling span, and maximum sampling gaps
are revalidated during assembly. GPU average/maximum is capped at 75%/95% for
1080p60 and 90%/100% for 4K60; energy-impact average/maximum is capped at
15/50 and 25/80 respectively. Average CPU is capped at 3 and 5 cores;
conversion average/maximum is capped at 8/25 ms and 16/50 ms. Only nominal or
fair thermal samples qualify. Periodic raw XCUI frame hashes and adjacent-pixel
ratios must reconcile exactly to the motion summary throughout all 900 seconds.
A missing trace, a target that never
changes, altered source geometry, more than 5% drops, less than 54 presented
frames per second, more than 160 MiB RSS growth, or any renderer failure rejects
the row. The app-side GPU/energy placeholders cannot satisfy the gate: host
augmentation removes them only after all three traces are verified.

The `cadence-matrix` lane runs for 600 seconds on `iphone-current`. Its local
origin serves deterministic 23.976, 24, 25, 29.97, 30, 50, 59.94, and 60 fps
H.264 sources plus a true 24/60 fps VFR source. Direct sample-buffer PiP stays
active while the app replaces all nine sources and performs pause/resume and
0.5x/1x/2x rate transitions. XCTest backgrounds the candidate and repeatedly
uses the real SpringBoard resize affordance. Evidence includes exact renderer
duration state, delivered/dropped/backpressure counters, generation-scoped
post-filter vmem output-attempt PTS, replacement and resize targets, and
compact raw samples. This timestamp is explicitly the post-filter,
vout-selected `picture_t.date` at the vmem callback seam; it is not lossless
decoded-source cadence. Each five-second window must retain one playback and
vout generation, a lossless signed PTS-delta histogram, exact callback
conservation (`callback = submitted + Swift-rejected + in-flight`), zero
invalid/backward/overflow evidence, and positive decoded/displayed runtime
counter movement. The PTS span must match the actual applied rate within 15%
relative error. Submitted throughput has a 90% lower bound based on
`min(sourceFPS * appliedRate, 60)` but no false 60 fps upper cap; legitimate
source-picture skips are represented as exact rational interval multiples and
zero deltas are retained as redisplays. The verified VFR fixture has an
absolute zero PTS origin and repeating 2s@24 + 2s@60 phases, so its lower bound
is integrated from the retained absolute window endpoints rather than inferred
from observed callback counts.

Each cadence window also binds an exact raw XCUI three-frame motion
observation. The attachment retains the corresponding three canonical 64x36
RGB8 byte streams plus exact uptime and compatibility elapsed timestamps; the
host decodes them, recomputes the domain-separated SHA-256 hashes and both
delta-12 changed-pixel ratios, and requires every capture to fall strictly
inside its native-counter window. Profile totals must exactly derive their
renderer-stage drop and presentation rates, contain no renderer copy/consume
failure, and cover retained renderer counters without equating them to the
earlier vmem callback stage. Transition evidence has the exact nine-profile
rate, pause, replacement, and render-target counts, while an independent UI-owned
`springboardResizeGestures` count proves at least `max(4, duration / 90)` real
SpringBoard resize gestures. A missing reported CFR cadence, fabricated
duration, backward PTS, broken callback conservation, incomplete
transition, forged frame summary, or unchanged render target rejects the row.
Every cadence fixture has a real 120-second timeline, so phase completion does
not depend on media options unsupported by the pinned media-player API.
`SWIFTVLC_CADENCE_SECONDS` may shorten exploratory runs, but the matrix rejects
release evidence shorter than 600 seconds.

The `native-subtitle-matrix` lane runs for at least 900 seconds on
`iphone-current`. Deterministic grayscale fixtures exercise text, styled ASS,
forced, DVB bitmap, repeated live DVB, adaptive-resolution text, 10-bit
BT.2020/PQ HDR text, and marquee OSD composition. The bitmap stream is the
exact SHA-256-pinned FFmpeg FATE filtered VideoLAN sample, so fixture drift
fails generation. Every finite subtitle phase has a real 120-second seekable
timeline; adaptive VOD reuses deterministic segments across explicit HLS
discontinuities instead of relying on unsupported media repeat options. Native
PiP remains active across media replacements,
pause/resume, seek, and adaptive low/high transitions. XCTest measures the
actual SpringBoard PiP pixels against the grayscale baseline and requires each
supported overlay at both real PiP sizes. Host augmentation must also bind
non-empty Time Profiler, Game Performance, and Metal System Trace recordings
to the same candidate run. A missing subtitle track, absent overlay pixels,
failed resize, more than 10% lost pictures, incomplete transition, wrong HDR
metadata, shortened duration, or missing trace rejects the row.

The `timebase-vod-soak` and `timebase-live-soak` lanes each hold direct PiP
active for at least 7,200 seconds. Rates 0.5x, 1x, and 2x divide the measured
interval into three long phases. The candidate also performs pause/resume,
VOD seek (or records the live non-applicability), replacement, a bounded
two-worker thermal load, a real cross-process audio-session interruption, and
periodic SpringBoard PiP resizing. One-second clock, audio-output, and frame
samples plus every control-timebase write are appended to recoverable JSONL;
only a 60-second compact series travels through XCTest. The host rejects a
short raw capture, any non-exact nested clock/audio/frame/correction schema,
disagreeing elapsed/generation/media clocks, correction-sequence gaps, or a mismatch
between compact and raw corrections, then binds its SHA-256 and a full Audio
System Trace export to the candidate evidence. Played/lost audio-buffer and
delivered/decoded/content-presentation clocks must advance in every playback
generation with no gap over 15 seconds; lost buffers are capped at 1%. Both
video clocks must follow the requested 0.5x/1x/2x slope, including after the
interruption generation. The Audio System Trace must contain target-owned
render rows spanning the run with the same 15-second maximum gap. The audio series is explicitly a
latency-adjusted presentation estimate paired with the system audio trace; it
never relabels libVLC media time as an audio timestamp. A 60-180 second
AVPlayer comparison uses the same URL and device, including
`AVPlayerItemVideoOutput` presentation time. Backward frame presentation,
more than 2.1 seconds of observed drift/correction, missing transitions,
unbalanced interruption, static/failed system PiP, or absent trace/raw data
rejects either row.

The release durations are policy constants, not matrix or environment tuning
knobs: adaptive and both timebase lanes require 7,200 seconds, both performance
lanes require 900 seconds, cadence requires 600 seconds, and native subtitles
requires 900 seconds. `--require-stable` rejects shorter overrides before
testing. Stable evidence must contain the positive duration observed by the
device and the full retained sample/raw timeline. Host attempt wall time may
trail that device clock by at most 300 seconds (or lead it by at most five
seconds for integer-boundary sampling); setup, export, a hang, or wall time
accumulated across retries cannot turn a shortened device run into a qualifying
soak.

The VOD lane uses a deterministic four-hour HLS timeline backed by the cached
two-second transport-stream segments. Discontinuities bind every segment wrap
into one finite, seekable timeline; the lane does not depend on libVLC input
repeat behavior and cannot exhaust its media during the rate schedule.

Use `--require-stable` for release evidence. It fails before testing if the
device is a simulator, runs beta or unknown software, or does not match a
hardware row in `matrix.json`. Without that option, the same command is useful
for exploratory beta-OS testing, but its report remains ineligible for release.
On an iPhone running an OS newer than the matrix's `iphone-current` row,
`--exploratory-current-only` also exercises the longer current-device lanes.
The policy rejects matching/older OS versions, iPads, and qualification-mode
devices; all resulting evidence remains exploratory and cannot satisfy a row.

This lane is intentionally fail-closed: its current automated scenarios are a
candidate qualification subset, not a claim that every canonical qualification
row passed. The harness has prepared automated coverage for every current row.
This is not a claim that any newly prepared row passed: `report.json` keeps
`releaseGateSatisfied` false until a matrix runner has produced complete
candidate-bound evidence for every required hardware/OS row described below.

Qualification is bound to both halves of the shipped package. The
XCFramework tree digest identifies the native engine and headers, while the
release-source digest identifies every release-significant tracked file in the
Swift wrapper worktree. The latter deliberately excludes only the record for
the version being qualified and its `evidence/<version>/` attachments. It also
normalizes the narrowly validated Package.swift binary reference and Showcase
package reference, because candidate testing uses repo-local wiring and the
release commit deterministically replaces those fields with the final URL and
version. Any other tracked or untracked source, test, release-script, or matrix
change produces a different identity and requires a new candidate and device
run.

Record the results as `scripts/qualification/<version>.json`:

```json
{
  "formatVersion": 2,
  "version": "1.1.0",
  "artifactDigestAlgorithm": "swiftvlc-tree-v1",
  "artifactDigest": "…",
  "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
  "candidateAppDigest": "…",
  "sourceCommit": "…",
  "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
  "releaseSourceDigest": "…",
  "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
  "testRunnerDigest": "…",
  "testBundleRelativePath": "PlugIns/SwiftVLCPackageTests.xctest",
  "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
  "testBundleDigest": "…",
  "baseXCTestRunDigestAlgorithm": "sha256",
  "baseXCTestRunDigest": "…",
  "baseXCTestRunName": "SwiftVLCPackageTests.xctestrun",
  "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
  "testCatalogDigest": "…",
  "testCatalogCount": 1,
  "testCatalog": ["SwiftVLCShowcaseUITests.SmokeTests/testPlayback"],
  "qualificationMatrixChecksum": "…",
  "featureManifestChecksum": "…",
  "qualificationProfilesChecksum": "…",
  "fixtureManifestChecksum": "…",
  "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
  "qualificationPolicyDigest": "…",
  "rows": [
    {
      "scenario": "vod-controls",
      "hardware": "iphone-current",
      "device": "iPhone 15 Pro",
      "deviceFamily": "iPhone",
      "productType": "iPhone16,1",
      "osVersion": "26.6",
      "osBuild": "23G80",
      "osReleaseType": "stable",
      "fixture": "qualification-fixtures:<fixtureManifestChecksum>",
      "duration": "2m14s",
      "durationSeconds": 134,
      "evidence": "evidence/v1.1.0/iphone-current-vod-controls.json",
      "result": "pass",
      "notes": "optional; put log excerpts or anomalies here"
    }
  ]
}
```

Every evidence file is a JSON object tied to the exact artifact and row:

```json
{
  "artifactDigest": "…",
  "candidateAppDigest": "…",
  "releaseSourceDigest": "…",
  "fixtureManifestChecksum": "…",
  "scenario": "vod-controls",
  "hardware": "iphone-current",
  "testExecution": {
    "expected": {
      "digestAlgorithm": "swiftvlc-test-catalog-v1",
      "digest": "…",
      "testCount": 1,
      "testIdentifiers": ["SwiftVLCShowcaseUITests.VODTests/testControls"]
    },
    "executed": {
      "digestAlgorithm": "swiftvlc-test-catalog-v1",
      "digest": "…",
      "testCount": 1,
      "testIdentifiers": ["SwiftVLCShowcaseUITests.VODTests/testControls"]
    },
    "identityAndCountMatch": true,
    "allPassed": true
  },
  "events": {
    "started": true,
    "unexpectedStopCount": 0,
    "order": "pass"
  },
  "controls": {
    "pause": "pass",
    "scrub": "pass",
    "skipForward": "pass",
    "skipBackward": "pass"
  }
}
```

Scenario-specific required fields use dotted paths such as `metrics.cpu` or
`backendResults.native`. Zero is a valid recorded value (for example zero
crashes or frame drops); missing, null, empty strings, and empty collections
are not. Exact and allowed-value constraints use the same dotted-path syntax.
JSON types are strict: a boolean does not satisfy a numeric zero or one, even
inside an array or object. Durations must also be finite positive numbers;
`NaN` and infinity are rejected before minimum soak time is evaluated.
Evidence may contain any additional raw samples, logs, Instruments exports,
fixture hashes, or notes needed to make the result reproducible.

`artifactDigest` is a path-independent SHA-256 over the complete XCFramework
tree: libraries, headers, `Info.plist`, relative paths, symlinks, and modes.
Get it for the exact, already-stripped artifact you are about to qualify with:

```bash
./scripts/artifact-tree-digest.py Vendor/libvlc.xcframework
```

Do not strip, rewrite headers, or otherwise mutate the XCFramework after this
digest is recorded. A header-only ABI mismatch can be just as unsafe as a
library change.

Candidate preparation records the source and app identities; the signed runner,
embedded bundle, selected xctestrun, and full leaf-test catalog; and checksums
for the matrix, feature manifest, profiles, fixtures, and qualification policy
in `release-candidate.json`. Those bindings are retained without substitution
in every report, evidence file, and assembled record. `check-qualification.sh`
recomputes the repository policies itself and rejects stale source, a weakened
or expanded matrix, manifest drift, mixed app reports, a record from another
candidate, or evidence captured against another wrapper revision.

Candidate-bound rows from separate device runs can be accumulated without
hand-editing JSON. Pass every retained `report.json` to the assembler, along
with the candidate metadata used by the device runner:

```bash
python3 scripts/qualification/assemble-record.py \
  --version 1.1.0 \
  --candidate-metadata /absolute/path/to/candidate-metadata.json \
  --matrix scripts/qualification/matrix.json \
  --report /absolute/path/to/iphone-results/report.json \
  --report /absolute/path/to/ipad-results/report.json \
  --output scripts/qualification/1.1.0.json
```

The assembler rejects exploratory or beta-OS reports, identity mismatches,
unknown or duplicate rows, failures, unsafe evidence paths, and evidence from a
different artifact, source, scenario, or hardware row. Before copying anything,
it re-exports the authorized qualification attachments from the final retained
passing xcresult, reconciles their exact names, XCTest owners, payloads, sizes,
and digests with the retained export and host-enriched evidence, and applies the same scenario required-field,
expected-value, allowed-value, duration, provenance, and exact-XCTest checks as
the final release gate. It copies accepted attachments under
`evidence/<version>/`, retains each complete source report tree under
`reports/<version>/` with a tree digest, and writes the record atomically. The
record validator reopens those reports, all attempt artifacts, and retained
raw JSONL before reconciling their rows and evidence with the copied record. It
also aggregates the exact executed runner inventory and requires every release
profile support/endurance lane independently for each applicable hardware row;
coverage on one device cannot satisfy another device. A
partial record is
allowed so multiple devices can be accumulated over time; only
`check-qualification.sh` is the complete final gate. It continues to reject the
record until all required rows and scenario-specific evidence pass, then also
rejects it if any required product feature is failed, not run, or blocked.

## Checking before release

```bash
./scripts/check-qualification.sh 1.1.0
```

It fails when the record is absent, describes a different app/runner/bundle/
xctestrun/catalog or engine artifact, is for another version, omits a required
row, contains a row that did not pass, or has a row missing device identity,
stable OS build, fixture, duration, evidence, or result. Duplicate JSON keys
are rejected. Evidence paths are resolved beneath the record directory; each
file must exist, parse as JSON, preserve the complete identity and exact XCTest
execution, and contain the fields that scenario requires with the required
semantic values. It also rejects an undersized soak, fixture-manifest drift, an
iPhone recorded for an iPad row, the wrong OS major, and beta/unknown or
conflicting OS release signals. After those scenario checks pass, it evaluates
the assembled record against `feature-manifest-v1.json` and rejects any
applicable required feature that is failed, incomplete, not run, or blocked.

The digest is recomputed from the artifact on disk rather than trusted from the
record — a record can claim any digest, and only a recomputed one can contradict
it. That is what stops a stale qualification from carrying forward onto a
rebuilt engine.
