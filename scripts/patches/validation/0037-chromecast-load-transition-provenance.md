# Chromecast generation-safe handoff provenance (patch 0037)

## Frozen source boundary

- VLC source pin: 'c833c4be000b426d73ff4324bec574065f00e3df'.
- Patch order: after SwiftVLC patches 0001–0036.
- Isolated 0001–0036 replay commit used to generate the patch:
  '6bb082cc8dd3468c81bcfdcd8b23066411f1a30a'.
  This is a temporary proof commit, not a repository dependency.
- Patch: '0037-chromecast-load-transition-correctness.patch'.
- Patch SHA-256:
  'dd3c672da9b7a6fcd82e6eadd298d1c5f86ce75e55d86800de8fd83683461105'.
- Source checker SHA-256:
  '1d720d36697bb7965d3e8aa333920c2240587addf8b0c30b8a5dfe0127705e0b'.
- Native probe SHA-256:
  '9b34b662485b7932c29c666c5db1e95ba4d9dd2f2f94089f2547d11d0ad64d2a'.
- Standalone validator SHA-256:
  '038f231c6a4fdebcfc2455d609fb5d1f08ac39963bbc572f6b569a5e51eae89b'.
- Post-pin final/predecessor source checker SHA-256:
  '389b89eea8f689953c8ba13110e907895a20f59534e40fed23fc57d916cc0e5a'.
- Post-pin linked/native validator SHA-256:
  'ed284fda619f3fcd174ae8a21114e26a9ec09e80d38149c5553a988f622dd4b3'.
- Frozen inherited 0036 patch SHA-256:
  'd2e040c8db4ff529766be4bab875519e8e16242bed4bc645c4a485e422e47295'.
- Frozen inherited 0036 checker SHA-256:
  '39fcc62fe9ac56359de49dcd22a54601e9f79d8b20b099fff117661be20ba909'.
- Frozen inherited 0036 probe SHA-256:
  'd93ac662e8123d8f81ddb415a8a1e543efcd4df42caf240a1935c5792608d08f'.
- Frozen inherited 0035 patch SHA-256:
  'e14238bd31c42e8fa6b864746beeb3284ef485546228ea9c9f6181adc075983d'.
- Frozen inherited 0035 checker SHA-256:
  '155f6fc4207a160ad6811c8ca56cb96b5b38ce836db9a517b2bc2fb4dac64fdc'.
- Frozen inherited 0034 checker SHA-256:
  '0bd1b049b103f4a4a2c5ad3f6de23eb97f9fa48be63dcfe65cc460761332704f'.
- Frozen inherited 0034 probe SHA-256:
  '09829a7423bfe73e322b504e17c9cb625dfcdfd4b7f98951abcb6bdbb59d6e9b'.
- Native-probe compatibility-header SHA-256:
  '13c06861628085b804a245f62222388d34b841d763c4cb471952b565b0db089f'.

Exact patch path inventory:

1. 'modules/stream_out/chromecast/cast.cpp'
2. 'modules/stream_out/chromecast/chromecast.h'
3. 'modules/stream_out/chromecast/chromecast_common.h'
4. 'modules/stream_out/chromecast/chromecast_communication.cpp'
5. 'modules/stream_out/chromecast/chromecast_ctrl.cpp'
6. 'modules/stream_out/chromecast/chromecast_demux.cpp'
7. 'modules/stream_out/chromecast/chromecast_protocol.hpp'

The patch changes only VLC's internal Chromecast module contract. It does not
change a public libVLC header, Swift API, packaging format, or Apple platform
deployment target.

## Root causes

### Input identity ended at the demux boundary

The old callback surface carried EOF, retry, pause, metadata, duration, pacing,
and time without identifying the VLC input that produced the call. A reusable
demux filter, a surviving controller, and a rebuilding sout chain could
therefore overlap during replacement or seek. An old EOF or retry could stop a
new chain, an old pause could affect a successor, and a waiter could resume
after ownership changed and consume the wrong receiver state.

Patch 0037 gives every input a nonzero 64-bit generation. Pending and active
input state are separate, including metadata, desired pause, retry policy, EOF
value plus EOF-known state, pacing, duration, and callbacks. Every demux call
carries the generation. Promotion is one locked operation, teardown detaches
callbacks before the identity can be reused, and a pacing wait revalidates
ownership after every wake.

The first EOF=false event is intentionally delivered: false is data, not an
uninitialized sentinel. A pending input that has finished producing bytes
waits for promotion/receiver completion; it must not report receiver-ended
before its LOAD exists.

### STOP and successor LOAD shared one mutable request/session slot

The former first-block path reset receiver requests and session state before
the prior STOP was terminal. Depending on timing, this either orphaned the STOP
response, lost the new LOAD request, or let an old status mutate the successor.

A first block now queues the exact generation, stream token, and MIME type.
While the old session is playing it requests STOP but preserves all old request
and media-session attribution. Only a terminal/loadable state can commit the
queued input. Promotion, queue removal, old request clearing, and the exact
LOAD emission occur under the controller lock in that order.

Artwork endpoint creation must temporarily release that lock. If input,
metadata, route, receiver state, or stream token changes in that window, the
transaction revalidates. Any surviving queue is immediately re-arbitrated in a
loop because its first-block callback has already returned and no later state
transition is guaranteed.

### One fixed HTTP URL and one shared FIFO had no LOAD identity

A stale Cast HTTP client could reconnect to the fixed stream URL after a seek
or replacement and read bytes from the next chain. A single nullable client
pointer was also treated as sufficient authority after waits.

Every concrete sout chain now receives a fresh nonzero 64-bit stream token.
The token is embedded in the Cast LOAD content URL as the sole canonical query
'streamToken=<unsigned decimal>'. The HTTP callback rejects zero, missing,
mismatched, signed, encoded, leading-zero, overflowed, or extra-parameter
queries with 410. It validates the exact client before waiting and before
dequeueing. Stop/prepare purge the FIFO, detach the client, clear the live
token, reset pacing, and signal waiters.

### Artwork callbacks observed mutable controller metadata

The HTTP artwork callback previously depended on controller-owned mutable
artwork state. Endpoint replacement and metadata replacement could make a
callback serve the wrong source or outlive the value it expected.

Each endpoint now owns an immutable context containing the copied source URL
and controller pointer. Candidate creation is transactional; endpoint and
context are installed/deleted as a pair. Controller destruction deletes the
endpoint before its context. The complete context type is defined before the
destructor, avoiding deletion through an incomplete type.

### Terminal state had ambiguous edge cases

Cast can publish primary 'IDLE' with extended 'LOADING' while an attributed
initial LOAD is still progressing. That is accepted only before playback,
while the controller is Loading/Buffering, and only when 'idleReason' is
empty. Any terminal reason wins. This handles requestId-zero broadcasts without
letting a later IDLE resurrect a played session.

A local STOP racing 'FINISHED' remains a local handoff and does not surface as
end-of-media to a demux rebuilding after seek. A queued input with an empty app
transport relaunches the media receiver instead of asserting or sending LOAD to
an empty destination. Closing the sout first detaches its callback and HTTP
access object, then destroys the controller, then the shared HTTP host.

Cast state/message references used for this interpretation:

- <https://developers.google.com/cast/docs/reference/web_receiver/cast.framework.messages.MediaStatus>
- <https://developers.google.com/cast/docs/media/messages>

## Enforced production invariants

'chromecast-load-transition-source-check.py' validates eleven final source files
and the exact seven-path patch. It binds the production implementation to:

- 64-bit nonzero input generations and stream tokens on every internal callback;
- pending/active ownership and generation-tagged sout ES identities;
- exact chain token creation, URL publication, query parsing, and HTTP client
  revalidation;
- fail-closed mixed/stale generation rejection before or immediately after the
  first nested write;
- STOP-before-LOAD request/session preservation;
- locked promotion and load commit ordering;
- queue re-arbitration after unlocked artwork work;
- first-value EOF delivery and stale EOF/retry rejection;
- bounded pacing with post-wake generation validation;
- immutable, paired artwork endpoint lifetime;
- receiver relaunch when a loadable state has no app transport;
- local STOP precedence over a racing FINISHED status; and
- callback/access/controller/HTTP-host destruction ordering.

It first runs frozen 0036's production-contract validator against the actual
final 0037/0038 source, including the unchanged DLNA input. It does not run
0036's frozen mutation harness there because 0037 legitimately introduces a
second occurrence of one fail-closed 0036 mutation fixture. Instead it
reverse-applies every 0037 unified-diff hunk in memory, validates the exact
reconstructed 0036 predecessor, and only then runs frozen 0036's 21 source and
seven patch mutations plus its inherited 0035 proof. The same predecessor also
passes frozen 0034's structural proof and all 33 negative mutations. This keeps
each mutation suite at the source boundary where its fixture inventory was
frozen without weakening any final-source production invariant.

Adversarial results against the frozen final source:

- inherited 0036 semantic mutations rejected on its predecessor: 21/21;
- inherited 0036 patch mutations rejected: 7/7;
- inherited 0035 source/patch mutations rejected: 14/14 and 3/3;
- inherited 0034 semantic mutations rejected: 33/33;
- new 0037 semantic mutations rejected: 44/44;
- exact patch/path mutations rejected: 3/3.

An exhaustive outer-statement early-transfer sweep injected 132 synthetic
unconditional returns across GetMedia (21), msgPlayerLoad (7),
prepareHttpArtwork with both boolean outcomes (38), tryLoad's outer/loop bodies
(29), setMeta with both outcomes (18), setInputLength with both outcomes (8),
and demux init (11). Both the 0037 checker and the independently maintained
post-pin checker rejected 131/132. The sole acceptance inserts 'return;'
immediately before tryLoad's already-final unconditional 'return;' after its
Loading/LoadFailed handling, so it is semantically identical; all 131
meaningful early-transfer mutations fail closed.

Both final-source checkers' direct-statement scanners also treat an outer-body
'if (true)', 'if (1)', or 'if (!false)' that immediately governs a direct or
braced return/throw/goto as an unconditional transfer. Dedicated negative
fixtures reject always-taken guarded exits before GetMedia's token URL,
prepareHttpArtwork's publication transaction, tryLoad's transaction loop,
and the demux initialization tail; braced and unbraced spellings are covered.
This keeps each independently callable structural proof fail-closed for the
same reachable production paths, without relying on exact patch reversal or a
sibling validator to reject those edits first.

'chromecast-load-transition-probe.cpp' executes:

- all 384 combinations of played/controller-starting, primary state, extended
  state, and idle reason, with exactly one accepted initial-loading case;
- 16 malformed canonical-query cases plus zero and mismatched expectations;
- maximum-uint64 parsing and decimal overflow rejection;
- 100,000 deterministic nonzero 64-bit token round trips with wrong-token
  rejection; and
- IPv4/IPv6 content URL construction plus empty-base/path/token rejection.

The standalone validator reruns the frozen 0034 state and 0036 metadata native
probes against the final headers, then runs the new 0037 probe. All three use
'-std=c++17 -Wall -Wextra -Werror' and the hash-bound compatibility header. The
validator supports a portable external work root in this precedence order:

1. explicit second positional argument;
2. 'SWIFTVLC_VALIDATION_TMP_ROOT';
3. legacy 'SWIFTVLC_EXTERNAL_TMPDIR';
4. 'TMPDIR';
5. '/tmp'.

## Compile evidence

The four changed Chromecast translation units that contain executable module
logic were compiled directly with 'clang++ -fsyntax-only -Werror' using the
configured VLC tree and VLC's verified protobuf 3.21.1 source:

- 'chromecast_ctrl.cpp'
- 'chromecast_communication.cpp'
- 'cast.cpp'
- 'chromecast_demux.cpp'

Environment recorded for the final isolated pass:

- Xcode 26.6 ('17F113');
- Apple clang 21.0.0 ('clang-2100.1.1.101');
- macOS 26.6.2 arm64;
- macOS SDK selected by 'xcrun';
- 'git diff --check': PASS;
- native/source standalone validator: PASS.

## Historical replay and reversibility evidence

On 2026-09-01, a fresh detached checkout of
'c833c4be000b426d73ff4324bec574065f00e3df' at
'<external-build-root>/Tmp/swiftvlc-0037-final-replay.E144jx/vlc'
replayed all 38 patches from the hash-verified manifest. Every patch passed
both the forward preflight and the immediate reverse preflight. The cumulative
0001–0036 full-index binary-diff SHA-256 was
'f1e37e25607ae8f174ae3d2ddcc041579eca6b034f7ab139fc8337cf1a2469c9';
the then-current 0001–0038 full-index binary-diff SHA-256 was
'429913eaf702b91acbe1c794dfa88dbd1a350fe225937243cd92e09d1da716ae'.
The replay changed 90 pinned-source paths and 'git diff --check' passed at the
0036 boundary, at the final tree, after reversal, and after reapplication.

That replay used the then-current patch 0032 at SHA-256
'3b402d434287d2e64b0169f9a7917b6d4648151374eff85b2ee149c6a964841b'.
The current manifest instead contains the ARC-corrected patch 0032 at SHA-256
'299dcf69856805872e803c44e84826d95c39e4eea5876bf1cc0d01de3f99b8c4'.
Consequently, the cumulative hashes and path count in this historical
subsection are not identities for the current manifest. The corrective replay
below supersedes them for release qualification.

Inherited gates ran at their exact replay boundaries:

- after 0034: source/state proof 33/33 mutations and native probe PASS;
- after 0035: source proof 14/14 plus patch proof 3/3 mutations PASS;
- after 0036: source proof 21/21, patch proof 7/7, inherited 0035 proofs, and
  metadata integer truth table PASS; and
- after 0037: final-source 0036 production semantics, reconstructed-predecessor
  0036 source mutations 21/21 and patch mutations 7/7, inherited 0035 source
  mutations 14/14 and patch mutations 3/3, inherited 0034 mutations 33/33,
  new source mutations 44/44, patch mutations 3/3, frozen 0034 and 0036 native
  probes, and the new 0037 native probe PASS.

The final replay passed both the complete 0037 validator and the complete 0038
validator. Actual reverse applications of 0038 and then 0037 reproduced the
exact 0001–0036 cumulative diff SHA-256 above and passed the untouched complete
0036 validator. Forward reapplication of 0037 and then 0038 reproduced the
exact final cumulative diff SHA-256 above and passed both final validators
again. The post-pin checker plus linked JSON/URL/duration and production UPnP
probes passed both at the reconstructed 0036 boundary and after final
reapplication. The retained replay and complete log at
'<external-build-root>/Logs/native-build-a/final-validator-chain-replay.log'
are outside the source checkout; no libVLC archive or XCFramework was built
during this proof.

These results are deterministic source/protocol evidence. They must not be
interpreted as physical receiver evidence.

### Corrective 0038 compatibility replay

Later on 2026-09-01, the first clean all-platform native build exposed that
0038's NASM wrapper inputs were removed by `contrib/src/main.mak`'s cross-Meson
`env -i` boundary. Revised patch 0038 at SHA-256
`5f1a58d162c798b2d6f5c2a2fdac9f728279f195ef192405b80272bc2f164c59`
adds only that missing environment bridge. A new detached replay of all 38
hash-verified patches changed 105 upstream paths and passed `git diff --check`,
the complete 0037 validator, post-pin linked/native proofs, and the revised
0038 validator. Reversing 0038 reproduced the 0001–0037 full-index binary-diff
SHA-256
`4b2420a72eaeb0e5d790e1f945ccdfff6dd3463b98082f7bc51a377bd42f10dd`;
that tree changed 98 upstream paths. Reversing 0037 then reproduced the
current 0001–0036 full-index binary-diff SHA-256
`0f081b4cf8888bf4b4afed5cda7a7e052775e6671540f059b16b8364691baf21`,
also across 98 paths. A second fresh checkout replaying exactly 0001–0036
independently reproduced that identity. Forward
reapplication restored the corrective 0001–0038 full-index binary-diff
SHA-256
`ef189d468e0ed175050d471888fd5e6093f7200a48764c90791eb2d3b96c27fb`.
The transient replay root was
`<external-build-root>/Tmp/corrective-0038-replay.FWNAG4`; its complete log is
retained at
`<external-build-root>/Logs/native-build-a/corrective-0038-replay.log`.
This addendum supersedes the historical cumulative identities and path count;
patch 0037 and its source/protocol claims are unchanged.

## Build and release integration

When the manifest lists patch 0037, 'build-libvlc.sh' runs this superseding
validator and does not invoke the frozen 0036 standalone validator on final
source. Patch 0036 remains the exact fallback when 0037 is absent, and patch
0035 remains the fallback when both successors are absent. Release-integrity
tests enforce that newest-first selection and the checker/probe order.

The later frozen 0034 standalone call is likewise suppressed only when 0037 is
selected: 0037 reverse-validates that exact predecessor and runs its native
probe itself. The complete post-pin gate still runs after host-tool generation
on every supported branch. Its source checker selects the exact generation-
aware 0037 contract only when all five unique source markers agree, otherwise
it preserves the pre-0037 contract; both the exact 0036 predecessor and final
0038 replay pass. Its linked production JSON/URL/duration probe and concurrent
production UPnP lifecycle probe also pass on the final replay.

The standalone 0037 validator is itself included in libVLC's recorded build
configuration. Release provenance verification requires the same named file
and SHA-256, so omitting the validator or changing its hash fails closed before
packaging. The standalone validator then hash-binds its checker, native probes,
patches 0035–0037, frozen inherited checkers, and compatibility header.
The post-pin validator is independently recorded in the same artifact
configuration and transitively hash-binds all 12 repository-owned checker,
probe, compatibility, iconv, and UPnP fake-header inputs before it runs.

## Remaining release evidence

This patch is a deterministic source/protocol gate, not proof that a physical
Cast receiver rendered and controlled media correctly. Candidate-bound device
qualification still has to cover at least:

- first LOAD followed by repeated requestId-zero IDLE/extended-LOADING status;
- rapid item replacement during Loading, Buffering, Playing, Paused, and STOP;
- repeated seek forward/back, seek near EOF, and STOP/FINISHED races;
- local files small enough to reach demux EOF before the predecessor STOP;
- audio-only, video, subtitles, remux, and both transcode fallback stages;
- pause one item then replace it playing and start-paused;
- receiver-native play/pause/seek and takeover from another sender;
- stale old content URLs and concurrent/retried HTTP clients;
- local artwork replacement while an old artwork request is in flight;
- Wi-Fi loss, receiver app closure, control disconnect, reconnect, and recast;
- VOD, live HLS, IPv4, IPv6, and scoped/unpublishable route rejection; and
- truthful final audio/video output and clock/position behavior.

Record receiver model, firmware, sender OS/device, network topology, fixture
identity, and raw logs. Casting remains a release blocker until this physical
matrix passes even when every static/native proof is green.
