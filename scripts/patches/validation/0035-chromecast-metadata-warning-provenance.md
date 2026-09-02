# Chromecast metadata/warning provenance (patch 0035)

## Source baseline and exact inventory

- VLC source pin: `c833c4be000b426d73ff4324bec574065f00e3df`.
- Patch 0035 applies after SwiftVLC patches 0001–0034 in manifest order. Patch
  0034 and all of its frozen validation artifacts are unchanged.
- Frozen patch: `0035-chromecast-metadata-warning.patch`.
- Patch SHA-256:
  `e14238bd31c42e8fa6b864746beeb3284ef485546228ea9c9f6181adc075983d`.
- Combined stable patch ID:
  `b6d9fd14f65ddbc7cd5c4e82e000db0f66518efd`.
- The patch owns exactly these three VLC paths, in this order:
  - `modules/stream_out/chromecast/cast.cpp`
  - `modules/stream_out/chromecast/chromecast_communication.cpp`
  - `modules/stream_out/dlna/dlna.cpp`

The complete code delta is four `empty()` to `!empty()` predicate corrections
and two moves of the existing `perf_warning_shown = true;` statement. No public
header, build file, Swift source, or patch 0034 artifact changes in 0035.

## Audited upstream objects

The local authoritative VideoLAN Git object database contains both upstream
commits and their parents. Their identities and stable patch IDs were computed
from the objects rather than inferred from a web diff.

1. `d4286710deafdb96e81b25e37e6eb106122cc8a0`, parent
   `6d7920e148e4839155dd61c43cde2ccd84679d3d`, subject
   `chromecast: Include music metadata`, authored by Mattias Hansson on
   2026-02-28 and committed by Felix Paul Kühne on 2026-03-08. Stable patch ID:
   `1a85c79d3f543370d529646767807d14ac7f9c69`. It changes only
   `chromecast_communication.cpp`: non-empty album, album artist, track number,
   and disc number values are emitted in the music metadata JSON. The pinned
   code's inverted predicates emitted those keys only for empty values.
2. `46b09b5208c74bd1ec432b186b78b1c6798edab2`, parent
   `5d680fd2d123a62294a69106446a250a4001e130`, subject
   `chromecast: Fix repeat warning dialog`, authored by Dave Nicolson on
   2026-03-23 and committed by Steve Lhomme on 2026-04-12. Stable patch ID:
   `9c543677b609a857f832ea1a79805dfbb9d1f193`. In both Chromecast and DLNA
   `UpdateOutput`, it records that the conversion warning was shown immediately
   after the dialog returns and before the cancel path returns. Cancelling can
   therefore no longer cause the same warning to appear again during the same
   stream-output lifetime; response 2 remains the only response that persists
   the global `show-perf-warning` preference.

## Semantic and adversarial gate

`chromecast-metadata-warning-source-check.py` is frozen at
`155f6fc4207a160ad6811c8ca56cb96b5b38ce836db9a517b2bc2fb4dac64fdc`.
It rejects any patch path or code delta beyond the six upstream edits, then
binds the desired behavior to the exact production `GetMedia` and both
`UpdateOutput` functions. It proves all four fields are extracted once and
emitted once inside the music branch behind their own non-empty predicates.
For each renderer it proves one initialized latch, one member, one dialog, one
assignment immediately after that dialog and before cancel, and response-2-only
preference persistence.

The checker executes 14 negative source mutations: the four original inverted
metadata predicates, four incorrect JSON keys, and—for both Chromecast and
DLNA—a post-cancel latch, inverted guard, and false assignment. Three patch
mutations separately prove the exact predicate, path inventory, and moved
assignment delta cannot be weakened.

`validate-chromecast-metadata-warning.sh` is frozen at
`f23935ffbf823a31cef8ae3dcc5e293ccd17ae9121b749f6bcfe1b260dde4a62`.
It hash-binds both checker and patch before running the semantic/mutation proof.
The engine build preflight invokes it only when the exact 0035 manifest entry
is listed, since this behavioral backport intentionally adds no public marker.

## Clean replay proof

The complete manifest was replayed from the full pin into the fresh external
SSD worktree (with the machine-local build prefix normalized as
`<external-build-root>`):
`<external-build-root>/Tmp/swiftvlc-0035-replay.aHjtFw/vlc`.
Every patch passed `git apply --check` before application and the resulting tree
passed `git diff --check`. Immediately after 0034, the three 0035-owned blob
IDs were:

- `cast.cpp`: `15e1d2e3df381737351545f02990d9e01642a11d`
- `chromecast_communication.cpp`: `95cb9e79ee010dddf080456f79668e46433ce5ac`
- `dlna.cpp`: `7d55e5e29c173c0317780f8c42c0e85521eaab12`

After 0035 they were exactly:

- `cast.cpp`: `4afe65c680ff359badf55fc0dbcafa9c6e0336f8`
- `chromecast_communication.cpp`: `17c776428bd2d4214b94ad673a4e99bec91f9df6`
- `dlna.cpp`: `62f02b0233ca888ed4b1c9d6a0018fc93576fc72`

Reversing 0035 reproduced all three post-0034 blobs; applying it again
reproduced all three final blobs. Both the initial and replayed final trees
passed the 17-mutation 0035 validator. The frozen 0034 checker and native probe
also passed after 0035 with all 33 of their negative mutations, proving this
small follow-on does not weaken the earlier Chromecast state contract. Patch
0028's source self-test, production source check, linked production Cast probe,
and UPnP lifecycle probe also passed, using the already-built VLC tools bison
3.8.2 and keeping generated validation output on external storage. No libVLC archive or
release artifact was built as part of this proof.

## Physical qualification boundary

This gate proves exact source semantics, not receiver behavior. Release credit
still requires candidate-bound physical receiver evidence that representative
music visibly carries album, album artist, track number, and disc number when
present and omits them when absent. The operator should also force a conversion
warning, cancel it, trigger `UpdateOutput` again in the same playback lifetime,
and observe no second dialog; a new lifetime may show the warning again unless
the operator chose the persistent response. DLNA should receive the analogous
one-lifetime cancel check where the lab has a compatible renderer.
