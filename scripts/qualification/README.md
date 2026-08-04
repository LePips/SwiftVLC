# Device qualification records

System Picture in Picture, native video output, audio teardown and real libVLC
playback cannot be validated by CI. It compiles the iOS tests but never executes
system PiP on hardware, and the sanitizer job links a *released* xcframework
rather than the engine under test. The physical-device matrix is therefore the
acceptance gate, and `release.sh` refuses to package an artifact without one.

## Running the matrix

`matrix.json` lists the required scenarios and hardware. A scenario without a
`hardware` list runs on every hardware row; focused performance, soak, and
failure scenarios name the exact hardware they require. The current matrix has
53 required rows. Simulator runs never satisfy a row: PiP is force-disabled
there, and a simulator can report PiP active while its window stays black.

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

### Unattended physical-device lane

Once a device is connected, unlocked, trusted, and has Developer Mode enabled,
the smoke and regression lane is unattended. It does not require iPhone
Mirroring and does not ask an operator to copy observations out of the app:

```bash
./scripts/qualification/run-device-tests.sh \
  --derived-data /absolute/path/to/device-build \
  --output /absolute/path/to/evidence
```

That default path builds the app and runner from a clean checkout, embeds the
source commit and release-source digest in the signed app, and creates its
candidate metadata automatically. It builds a disposable `HEAD` export against
the exact local `Vendor/libvlc.xcframework`, so remote package resolution cannot
silently substitute an older wrapper or engine. A reused `--candidate-app` or `--skip-build`
requires `--candidate-metadata`; metadata creation succeeds only for an app
that was built with the `SwiftVLCSourceCommit` and
`SwiftVLCReleaseSourceDigest` Info.plist keys. Use
`candidate-metadata.py source` before an external build to obtain those values,
then `candidate-metadata.py create` after signing to bind them to the app-tree
digest.

The command identifies the physical device and OS release type, generates and
serves deterministic local media, installs the exact signed candidate and UI
test runner, executes the analyzer, general UI stress suite, native/direct live
PiP, same-player continuity, and HLS seek lanes, then pulls app logs and writes
a machine-readable `report.json`. It retains every attempt log and xcresult,
records and verifies candidate metadata that binds the app tree digest to its
source commit and release-source digest, and retries only a small allowlist of
Xcode/device-launch infrastructure failures. Every run reinstalls both exact
signed apps; an assertion, product failure, or provenance mismatch is never
retried into a pass.

Use `--require-stable` for release evidence. It fails before testing if the
device is a simulator, runs beta or unknown software, or does not match a
hardware row in `matrix.json`. Without that option, the same command is useful
for exploratory beta-OS testing, but its report remains ineligible for release.

This lane is intentionally fail-closed: its current automated scenarios are a
candidate smoke/regression subset, not a claim that all 53 qualification rows
passed. `report.json` therefore keeps `releaseGateSatisfied` false until a
matrix runner has produced the complete candidate-bound records described
below. Long soaks, performance captures, interruption/route-change coverage,
subtitle-format coverage, and every required hardware/OS row must still be
represented by automated evidence before the stable gate can open.

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
  "version": "1.1.0",
  "artifactDigestAlgorithm": "swiftvlc-tree-v1",
  "artifactDigest": "…",
  "sourceCommit": "…",
  "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
  "releaseSourceDigest": "…",
  "qualificationMatrixChecksum": "…",
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
      "fixture": "demo.mkv",
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
  "releaseSourceDigest": "…",
  "scenario": "vod-controls",
  "hardware": "iphone-current",
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

Candidate preparation records the source commit, release-source digest, and
matrix checksum in `release-candidate.json`. Copy those values into the
qualification record and each evidence file. `check-qualification.sh` computes
the current identities itself and rejects stale source, a weakened or expanded
matrix, a record from another candidate, or evidence captured against another
wrapper revision.

## Checking before release

```bash
./scripts/check-qualification.sh 1.1.0
```

It fails when the record is absent, describes a different artifact, is for
another version, omits a required row, contains a row that did not pass, or has
a row missing device identity, stable OS build, fixture, duration, evidence, or
result. Evidence paths are relative to the record; each file must exist, parse
as JSON, name the same artifact/scenario/hardware, and contain the fields that
scenario requires with the required semantic values. It also rejects an
undersized soak, an iPhone recorded for an iPad row, the wrong OS major, and
beta OS software.

The digest is recomputed from the artifact on disk rather than trusted from the
record — a record can claim any digest, and only a recomputed one can contradict
it. That is what stops a stale qualification from carrying forward onto a
rebuilt engine.
