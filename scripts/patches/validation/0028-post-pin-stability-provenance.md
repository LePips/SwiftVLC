# Patch 0028 provenance and validation boundary

Patch 0028 is a reviewable source backport. Its base is VLC
`c833c4be000b426d73ff4324bec574065f00e3df` after SwiftVLC patches 0001–0026
have been applied in manifest order. The frozen patch artifact SHA-256 is
`66c0496227ff6093b4853708dee24115039b43847dbdd7f2ff26aeb3314c3136`.
The following upstream commits were then applied in exactly this dependency
order:

| Order | Upstream commit | Author | Author date | Upstream subject |
| ---: | --- | --- | --- | --- |
| 1 | `0ab833bfbb2012fabfa9f2e308261b8abaed3647` | Pierre Lamot | 2026-01-16T15:20:50+01:00 | player: fix player seeking to AB loop start while paused |
| 2 | `f573990efc348205a60a967a19924f5746359835` | Pierre Lamot | 2026-01-15T18:24:03+01:00 | player: fix initial seeking in AB loop policy |
| 3 | `ef2f3434c4b10784b612dbfac402c637ce71703a` | Thomas Guillem | 2026-07-07T05:04:23Z | player: pass a valid date to the PLAYING timer event |
| 4 | `2b807d98b2ba8733dee502926401b95853194f59` | Alexandre Janniaux | 2026-08-08T12:27:12+02:00 | transcode: unload the decoder before cleaning fmt_in |
| 5 | `2febc7486de3985506243cc4fae36a3287b58c50` | Alexandre Janniaux | 2026-08-10T16:03:28+02:00 | input: decoder: unload the packetizer before cleaning its fmt_in |
| 6 | `de592342d31900eb9c85de97ad1feb5879f718fc` | Dave Nicolson | 2026-03-22T21:20:15+01:00 | chromecast: Add duration for streams |
| 7 | `8fbd8560ef1bed8546b14c88e08f98c1dc5decad` | Alaric Senat | 2026-03-26T11:14:04+01:00 | sout: chromecast: fix `CLOSE` json message parsing |
| 8 | `37afe71a69684c7fe594934ad0dca4542a48cf19` | Alaric Senat | 2026-03-26T14:01:06+01:00 | sout: chromecast: avoid unecessary string copies |
| 9 | `5efe99a912ce3ebc9d62829e91b0aed5280345ba` | Marvin Scholz | 2026-01-16T15:52:07+01:00 | sout: chromecast: fix exposed URL formatting |
| 10 | `8bc99a65e253aae5d4c687a33a76c916c521db77` | Dave Nicolson | 2026-03-21T12:07:21Z | chromecast: Remove invalid attribute |
| 11 | `39e76682953ffd5357d0ee06e3b5a79512c3118d` | Dave Nicolson | 2026-04-19T22:25:03+02:00 | chromecast: Improve stream type detection |

The cast sequence is atomic. Its only conflict was adapted around patch 0001:
the non-throwing connection failure and `isConnected()` contract remain, while
the URL composer replaces the raw server-IP accessor. The null-safe
`json_get_str_view` from 37afe is shared by production and the linked probe.
The production boundary additionally classifies and refuses IPv4 unspecified,
loopback, and multicast addresses; their IPv4-mapped IPv6 forms; and direct
IPv6 scoped, link-local, loopback, unspecified, and multicast addresses before
publishing artwork/content URLs or emitting LOAD. Wrapper-published artwork
records both its source and exact advertised URL. Reinit restores the source,
invalidates the old route, then republishes against the new reachable route;
allocation failure cannot publish an artwork URL whose source is not
restorable. The invalid `autoplay` member removed by 8bc stays absent.

The duration adaptation queries both outputs of the pinned
`DEMUX_GET_LENGTH` contract through the branch called by production demux
initialization. Query failure and successful non-live unknown/zero durations
map to `VLC_TICK_INVALID`; every successful live result, including a positive
seek-window length, maps to `INPUT_DURATION_INDEFINITE`; only a finite
non-live result is retained.

Patch 0025 is the companion lifecycle correction on the 0001–0024 baseline.
Its frozen patch artifact SHA-256 is
`166dfb6fd1fa0793bf5d5db2381822c57a829bf36bd0a960b17c52e981cfda61`.
The UPnP singleton now has explicit `Absent`, `Live`, and `TearingDown` states.
Last release publishes `TearingDown` under the process-global lock, calls the
real destructor/`UpnpFinish` after unlocking, then publishes `Absent` and
broadcasts. A concurrent `get()` waits in a loop and cannot initialize a new
libupnp instance until Finish has returned.

The linked validation compiles VLC's real JSON grammar and tokeniser,
`json.c`/`json_get_str`, `vlc_uri_compose`, and the exact Cast helpers used by
production. It executes missing/non-string `type`, root object/array, CLOSE and
ordinary namespaces; all rejected address classes plus bracketed global IPv6;
old-route restore/new-route artwork publication; the five duration/live result
classes; media fields; and LOAD-without-autoplay. The structural validation
binds those helpers to production call sites and proves the A-B, pause-epoch,
decoder/packetizer teardown, artwork reinit, address, and duration ordering.
The whole Chromecast controller and communication translation units are not
host-linked by this narrow probe, so their binding is intentionally a strict
source contract: `getServerBaseURL()` may contain only the direct policy-helper
return; reinit's restore and route-clear operations must be consecutive,
unconditional outer-body statements before reconnect; and demux init's
outer-body assignment must contain a lambda whose sole action is directly
returning the real four-argument `DEMUX_GET_LENGTH` call. A correct helper left
behind an `if`, after a top-level control transfer, or next to a raw/forced
production result cannot satisfy that contract.

The UPnP gate separately compiles the actual `upnp-wrapper.cpp` production
implementation against deterministic fake VLC/libupnp boundaries. Fake
`UpnpFinish` invokes the callback registered by production while last release
is in progress, then blocks while a concurrent production `get()` waits. The
gate proves callback reentry is not lock-deadlocked and that the second init
occurs exactly once, only after Finish returns. Structural negative mutations
cover removal or bypass of each formerly blind policy branch, including
delete-under-lock and wait/wakeup regressions. The source checker also runs
fast adversarial self-tests on every gate invocation. Those fixtures preserve
the expected helper tokens while (1) conditionally skipping old-route artwork
restore, (2) returning the raw server IP from a wrapper with an unreachable URL
policy call, and (3) forcing `VLC_EGENERIC` from a lambda with an unreachable
`DEMUX_GET_LENGTH` call; all three must be rejected before source validation.

`scripts/build-libvlc.sh` runs these gates after VLC extras/tools produces
bison 3 and before the first platform slice is compiled; temporary objects
remain under the configured external build root.

Commits 46c85, 853d, c949/52a, and 6c097 are not included. In particular,
6c097 remains deferred until the final 0027 display/submission context is
frozen, as documented in `006c097-vsbd-integration.md`.

The complete 0001–0028 series has been replayed from the pin with the current
provisional 0027 artifact, but compatibility must be rerun after 0027 is
regenerated and frozen. This checkpoint does not regenerate or rebuild libVLC.
A physical Chromecast session remains a release-lab requirement; the native
gate proves parser, serialization, route invalidation, and address policy on
the host but cannot prove receiver firmware interoperability or physical
network recovery behavior.
