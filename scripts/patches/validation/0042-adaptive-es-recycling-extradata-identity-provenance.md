# Patch 0042 provenance: adaptive ES codec-configuration identity

SwiftVLC patch `0042-adaptive-es-recycling-extradata-identity.patch` corrects an
upstream VLC adaptive-demux regression and adds a native regression test.

The adaptive defect was introduced by VideoLAN VLC commit
[`dc8ecee7c06354a847f65cb484fd9e78867305c8`](https://code.videolan.org/videolan/vlc/-/commit/dc8ecee7c06354a847f65cb484fd9e78867305c8)
on 2019-07-29. The same inversion was copied into the MP4 sample-description
compatibility path by commit
[`3f02c7cd9404`](https://code.videolan.org/videolan/vlc/-/commit/3f02c7cd9404)
on 2020-04-09. Both remain present in official VLC master at commit
`618a236d93702381f10ca1b0481c3048bdf9a515` as of 2026-09-02. For H.264,
HEVC, VC-1 and AV1, `FakeESOutID::isCompatible` returns the truth value of
`memcmp` directly. That rejects byte-identical codec configuration and accepts
different configuration of equal length.

`FakeESOut::createOrRecycleRealEsID` reuses a real ES only when this predicate
returns true. A same-variant adaptive seek therefore discards the old real ES,
decoder and video output even when the new segment has identical codec
configuration. On iOS this needlessly destroys the native PiP output. The
opposite error can retain a decoder across an actual codec-configuration
change.

The MP4 copy also falls through to a broader similarity test when both
configurations exist but have different lengths. That can incorrectly retain a
decoder across a sample-description change.

The patch introduces one internal byte-identity helper shared by the adaptive
and MP4 paths, so their truth tables cannot drift again. Its native test covers
H.264, HEVC, VC-1 and AV1, including absent data, length mismatch and a changed
source ID, then asserts both outcomes through the real adaptive recycling path:

- identical H.264 configuration retains one selected real ES across restart;
- changed configuration of the same size creates a replacement and collects
  the old ES.

Source-ID, codec, original-fourcc, profile, level and presence gates remain in
place. Representation switches and discontinuities therefore continue to force
replacement through VLC's existing source-ID boundary. A source checker binds
both call sites to the shared helper, the native test registration and an
adversarial mutation matrix.

The patched VLC host build was also compiled through both language call sites:
`adaptive_test` compiled and exited successfully, and `demux/mp4/mp4.c`
compiled as a C libtool object. Replacing the helper's equality check with the
original inverted `memcmp != 0` behavior made the same `adaptive_test` binary
exit with failure in `check4`; restoring equality returned it to success. This
mutation proof confirms the native regression test detects the upstream bug
rather than merely executing the affected code.
