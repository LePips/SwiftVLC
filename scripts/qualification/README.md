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
49 required rows. Simulator runs never satisfy a row: PiP is force-disabled
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

Record the results as `scripts/qualification/<version>.json`:

```json
{
  "version": "1.1.0",
  "artifactDigestAlgorithm": "swiftvlc-tree-v1",
  "artifactDigest": "…",
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
  "scenario": "vod-controls",
  "hardware": "iphone-current",
  "events": ["willStart", "didStart", "willStop(userClosed)", "didStop(userClosed)"],
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
