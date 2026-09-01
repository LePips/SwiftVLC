# Chromecast metadata schema correctness provenance (patch 0036)

## Baseline and atomic inventory

- VLC source pin: `c833c4be000b426d73ff4324bec574065f00e3df`.
- Patch 0036 applies immediately after frozen patch 0035. It does not change
  patch 0035, its checker, validator, provenance, or any of their recorded
  hashes.
- Patch: `0036-chromecast-metadata-schema-correctness.patch`.
- Patch SHA-256:
  `d2e040c8db4ff529766be4bab875519e8e16242bed4bc645c4a485e422e47295`.
- Stable patch ID: `35d101b44fb068319cf561048aebb99bd5f64281`.
- The patch owns exactly two VLC paths, in this order:
  - `modules/stream_out/chromecast/chromecast_communication.cpp`
  - `modules/stream_out/chromecast/chromecast_protocol.hpp`
- Its complete delta is 66 additions and 13 removals. There is no public API,
  build-system, Swift, DLNA, transport-state, or transition-state change.

## Authoritative Cast schema

Google's official [Media Playback Messages](https://developers.google.com/cast/docs/media/messages#MusicTrackMediaMetadata)
table defines music metadata type 3 with `albumName` as a string and
`trackNumber` and `discNumber` as integers. Google's official
[Web Sender MusicTrackMediaMetadata reference](https://developers.google.com/cast/docs/reference/web_sender/chrome.cast.media.MusicTrackMediaMetadata)
further specifies both numeric fields as positive integers and types them as
numbers, not strings. The same reference marks the music fields, including
`title`, as optional.

The post-0035 VLC source instead emitted the album under `album`, quoted the
two numeric values, and allowed arbitrary VLC metadata strings through. It also
extracted music fields only when the primary title existed and emitted no
metadata object without a title. That dropped valid album/artist/numeric-only
metadata and also dropped those fields when a later NowPlaying or ESNowPlaying
fallback supplied the title.

Patch 0036 therefore:

- emits the album under `albumName`;
- reads the complete raw VLC track/disc metadata values and accepts only ASCII
  digits whose parsed value is greater than zero and no greater than
  `std::numeric_limits<unsigned>::max()`;
- emits accepted track/disc values as unquoted JSON integers and omits empty,
  zero, signed, whitespace-padded, fractional, slash-delimited, non-ASCII, and
  overflowing values;
- extracts music fields independently of the primary title, emits a music
  metadata object when any supported music field is present, and never emits
  an empty `title` key; and
- preserves the existing generic/non-music requirement for a non-empty title.

Leading ASCII zeroes are accepted because the complete value still consists
only of digits and resolves to a positive bounded integer; JSON emission is the
canonical parsed value. Artwork-only metadata and generic artwork behavior are
explicitly outside this patch and retain the prior policy.

## Production-bound pure helpers and native truth table

`chromecast_positive_metadata_integer` is a pure, allocation-free helper in
the production `chromecast_protocol.hpp`. It accumulates one digit at a time,
checks overflow before multiplication/addition, rejects zero, and writes the
result only on success. Both production numeric fields call it directly on
their raw `vlc_meta_Get` values. `chromecast_should_emit_metadata` is the pure
presence-policy boundary used by production to preserve generic title-only
behavior while allowing individually optional music fields.

`chromecast-metadata-schema-probe.cpp` is frozen at
`d93ac662e8123d8f81ddb415a8a1e543efcd4df42caf240a1935c5792608d08f`.
It compiles the exact production header under C++17 with warnings as errors and
checks ordinary values, leading zeroes, the exact unsigned maximum, empty and
all-zero values, both signs, leading/trailing whitespace, tabs/newlines,
fractions, slash notation, exponent notation, letters, embedded NUL, non-ASCII
bytes, boundary overflow, long overflow, a null output pointer, and unchanged
output on every rejection. Its policy table separately proves fallback-title
behavior, every title-less music-field case, the all-empty omission, and the
unchanged non-music title requirement.

## Final-source, patch, and frozen-base proof

`chromecast-metadata-schema-source-check.py` is frozen at
`39fcc62fe9ac56359de49dcd22a54601e9f79d8b20b099fff117661be20ba909`.
It binds the two exact patch paths and complete added/removed-line inventory,
the exact pure-helper bodies, both raw production call sites, the schema keys,
unquoted JSON emission, fallback ordering, title omission, optional music
fields, and unchanged generic policy. Twenty-one adversarial final-source
mutations and seven independent patch mutations must all be rejected.

Patch 0036 necessarily supersedes the four metadata lines understood by the
frozen 0035 checker. To keep the 0035 evidence auditable without weakening or
editing it, the 0036 checker reconstructs only six explicit superseded chunks
in memory: declarations, the music extraction guard, track/disc extraction,
the metadata/title gate, the album key, and numeric emission. It then imports
the hash-bound frozen checker and invokes its `validate_patch`,
`validate_sources`, 14 source mutations, and three patch mutations on that
reconstruction. No temporary source tree or modified 0035 artifact is used.

`validate-chromecast-metadata-schema.sh` is frozen at
`794aa02a09540d522ac9d517f4e22d83c0e5efebd9567f767d4d9aa156033419`.
Before running either proof it hash-binds the 0036 patch, checker, probe, probe
compatibility header, and these frozen 0035 inputs:

- patch 0035:
  `e14238bd31c42e8fa6b864746beeb3284ef485546228ea9c9f6181adc075983d`;
- checker 0035:
  `155f6fc4207a160ad6811c8ca56cb96b5b38ce836db9a517b2bc2fb4dac64fdc`.

The engine preflight records both manifest entries. It runs the frozen 0035
validator only when 0036 is absent; when 0036 is listed it runs the superseding
0036 validator, whose in-memory proof includes the frozen warning and omission
base. Qualification maps to that same final validator.

## Fresh external-SSD replay

The manifest entries 0001–0036 were hash-checked and replayed in order from the
full pin into the fresh external SSD tree (with the machine-local build prefix
normalized as `<external-build-root>`),
`<external-build-root>/Tmp/swiftvlc-0036-replay.EVjGkN/vlc`. Every patch
passed `git apply --check` before application and the resulting tree passed
`git diff --check`.

Immediately before 0036, its two owned blobs were:

- `chromecast_communication.cpp`:
  `17c776428bd2d4214b94ad673a4e99bec91f9df6`;
- `chromecast_protocol.hpp`:
  `dc0717d77bf56f038d301df1811be8220b03f1bd`.

After 0036 they were exactly:

- `chromecast_communication.cpp`:
  `87c6669eca03c325a793b0d7bc2a4f98d591b73a`;
- `chromecast_protocol.hpp`:
  `f314dc761e5d10d5a144daaf144c98d4f1d1e301`.

The final tree passed the 0036 validator and the frozen 0034 state checker plus
native probe (33 negative mutations). Direct frozen-0035 validation correctly
rejected the superseding final source. Reversing only 0036 reproduced both
post-0035 blobs and passed the unmodified 0035 validator with all 17 negative
mutations; applying 0036 again reproduced both final blobs and passed the full
0036 proof again.

No libVLC archive, xcframework, application, or release artifact was built.
This is source and native-helper evidence, not receiver-output evidence. A
release candidate still needs physical receiver observation of `albumName`,
numeric track/disc rendering, invalid-value omission, title-less music
metadata, and NowPlaying fallback behavior.
