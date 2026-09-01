# Patch 0038: Apple assembly metadata provenance

Status: source-complete candidate, audited 2026-09-01. No complete native
libVLC rebuild is claimed by this record; the targeted x86_64 diagnostic below
is proof of the corrective path only.

## Identity and authoring base

- Upstream VLC revision:
  `c833c4be000b426d73ff4324bec574065f00e3df`.
- Authoring base: a fresh replay of the frozen SwiftVLC patch manifest through
  `0036-chromecast-metadata-schema-correctness.patch`. Patch 0037 was not in
  the frozen manifest when 0038 was authored, so it was not used as the base.
- Corrective compatibility replay: frozen patch 0037 at SHA-256
  `dd3c672da9b7a6fcd82e6eadd298d1c5f86ce75e55d86800de8fd83683461105`
  appears immediately before 0038 in the hash-verified manifest. A fresh
  checkout of the upstream revision accepted all 38 manifest patches in order.
  The final 0037, post-pin linked/native, and revised 0038 standalone
  validators passed there. Actual reverse applications of 0038 and 0037
  reproduced the validated predecessors; forward applications restored the
  validated final tree.
- Patch SHA-256:
  `5f1a58d162c798b2d6f5c2a2fdac9f728279f195ef192405b80272bc2f164c59`.
- Source checker SHA-256:
  `65b077ed399f44bee2616fb613511c422c97c88245fb82d2384ff4430ad45099`.
- Installed NASM wrapper SHA-256:
  `531c0d99e01e0c6e04af9d28c6a04121264d240242ae9d5905f014243eb33282`.
- Nested libgcrypt patch SHA-256:
  `8a080d7dc5cc9cc6dc5d05c327bd7521a7b3f0bdf901574b2f7162734761a216`.

The standalone validator pins the patch, checker, and this record by hash.
The release patch manifest is the repository-level trust root and records the
final 0037 and 0038 identities in that order.

## Observed artifact debt and root causes

The direct archive/Mach-O validator was run against the current
`Vendor/libvlc.xcframework` with the release deployment policy (iOS 18.0,
tvOS 18.0, visionOS 2.0, macOS 15.0, and Catalyst 18.0). It parsed 64,289
Mach-O objects in 13 architecture slices and reported 995 violations:

- 990 x86_64 objects had no `LC_BUILD_VERSION`: 214 in the macOS slice and
  194 each in the Catalyst, iOS Simulator, tvOS Simulator, and visionOS
  Simulator slices. These are NASM-produced objects spread across VLC and
  contrib code, not an archive-level linker classification problem.
- Five `rijndael-aesni.o` objects, one in each x86_64-bearing slice above,
  encoded `__TEXT,__text` alignment exponent 16 (65,536 bytes). The source is
  libgcrypt 1.10.1's inline assembler `.align 16`, whose Darwin meaning is an
  exponent rather than the intended byte count.

The previous tools recipe selected NASM 2.14. NASM's own 3.x change log says
the Mach-O `build_version` directive was added in NASM 3.00. Patch 0038 uses
3.02 and supplies that directive explicitly; merely allowing the Apple linker
to infer a platform would preserve the underlying ambiguity.

The 995 violations above are diagnostic evidence, not an expected-pass
baseline. A newly built release artifact must have zero violations.

The first clean all-platform build of the source-complete candidate exposed a
second causal defect after both arm64 iOS slices succeeded. VLC's cross-build
`MESON` command deliberately runs `env -i PATH=...`; that removed the four
exported inputs needed by the fail-closed NASM wrapper. Dav1d's x86_64
configure therefore found the wrapper but its `nasm -v` probe failed because
`VLC_APPLE_NASM_REAL` was absent. The corrective 0038 hunk forwards only the
real-binary path, platform, minimum OS, and SDK through that scrubbed setup
boundary. It does not forward `NASMENV`, compiler flags, `HOME`, or other host
state.

## NASM 3.02 provenance

- Official archive URL:
  `https://www.nasm.us/pub/nasm/releasebuilds/3.02/nasm-3.02.tar.gz`.
- The official release directory identified 3.02 as stable, with git ID
  `8f1fb545a582c55c69607f457b4d1e71c19b2ecf` and archive size 2,581,529
  bytes.
- Two independent HTTPS downloads were byte-identical.
- Audited SHA-512:
  `2971e17bad24127149c53fec5b7f28b32811d19c3f4b3fe9fff7f44df9e6c78f0a7dc3b30cb2257317ce8faa96c6063dad785250104c670ed7bb14651c1c8437`.
- Supplemental SHA-256:
  `f504227b2f529e658d41629075f0503b38d67d790af345f34eba4af60c6a5998`.
- No publisher checksum or signature sidecar was present at the official
  release directory when audited. The SHA-512 above is therefore an audited
  digest of two identical official HTTPS downloads, not a publisher-signed
  checksum. The VLC tools recipe enforces that exact digest.
- A local build from that archive reported `NASM version 3.02` and assembled
  the real-object probes described below.

The VideoLAN tools mirror did not yet contain the 3.02 archive during this
audit. VLC's existing `download_pkg` rule first tries that mirror and then the
official `NASM_URL`; the exact SHA-512 is checked in either case.

## Source policy implemented by 0038

1. `extras/tools/packages.mak`, `SHA512SUMS`, and `bootstrap` select the exact
   3.02 recipe and make 3.02 the minimum bootstrap probe. The Apple build then
   explicitly requests the recipe's `.buildnasm` target regardless of which
   host NASM satisfied bootstrap.
2. With an explicit command line and empty `NASMENV`,
   `extras/package/apple/nasm-wrapper.sh` passes non-Mach-O invocations through
   unchanged. For a command-line `macho64` format it validates an eight-value
   Apple platform allowlist and unsigned
   `MAJOR.MINOR[.PATCH]` minimum-OS/SDK values, normalizes them to the Mach-O
   field limits, and prepends exactly one NASM `macho build_version` pragma.
   It rejects caller-supplied build-version arguments, `NASMENV`, response
   files, missing metadata, invalid components, and wrapper recursion.
3. `extras/package/apple/build.sh` maps `macOS`, `iOS`, `iOS-Simulator`,
   `tvOS`, `tvOS-Simulator`, `xrOS`, `xr-Simulator`, and `macCatalyst` to
   NASM's `macos`, `ios`, `iossimulator`, `tvos`, `tvossimulator`, `xros`,
   `xrsimulator`, and `macCatalyst` inputs. It derives minimum OS and SDK from
   the build's final `VLC_DEPLOYMENT_TARGET` and `VLC_APPLE_SDK_VERSION`; no
   current Xcode SDK value is hardcoded.
4. The Apple build installs the wrapper only after explicitly requesting
   `.buildnasm`, preserves that bundled NASM under a non-shadowing name, and
   requires its version output to contain the exact version token
   `NASM version 3.02`. A stale 2.14 cache, a newer binary, a missing bundled
   binary, and a non-executable binary all fail before wrapper installation;
   there is no host-NASM fallback. The wrapper is then placed first in the
   inherited path. Moving the tools binary is intentional because
   `contrib/src/main.mak` prepends the tools bin directory again.
5. `contrib/src/main.mak` preserves the setup-time `env -i` boundary while
   explicitly forwarding the four fail-closed wrapper inputs. Normal GNU make
   environment inheritance carries the same exported values into Meson/Ninja
   compile and install recipes. The source checker executes both paths and
   proves that unrelated host/compiler variables remain scrubbed from setup.
6. The libgcrypt 1.10.1 source patch emits Darwin `.p2align 4` (16 bytes) at
   the AESNI site and retains `.align 16` on non-Apple assemblers. Its
   `rules.mak` insertion applies exactly once before `$(MOVE)`.

Unsupported Apple targets deliberately export no NASM metadata. Their normal
Arm assembly builds are unaffected, while any unexpected `macho64` invocation
fails closed rather than being stamped as the wrong platform.

## Executed evidence

- The source checker passed eight exact upstream paths, 19 deliberate source
  or patch mutations, 30 executable wrapper cases, eight executable
  wrapper-installation cases, and three cross-Meson setup/compile/install
  environment cases. The installation cases prove that exact 3.02
  tools and preserved binaries are accepted while stale 2.14, newer 3.03,
  look-alike 3.020, missing, and non-executable binaries fail closed even when
  an acceptable host NASM is available. The wrapper cases cover all
  five accepted `-f`/`--format` spellings, last-option-wins behavior,
  pass-through formats, all eight platforms, normalized two/three-component
  versions, field overflows, missing/invalid values, hidden `NASMENV` options,
  both response-file spellings, duplicate metadata, and recursion. The Meson
  cases independently mutate each required variable and both environment
  boundaries, poison unrelated environment keys, and prove the exact intended
  scrub/inheritance behavior.
- The original clean build failed at dav1d's x86_64 iOS Simulator NASM version
  probe. After applying only the corrective `contrib/src/main.mak` hunk to that
  retained failed tree, the exact setup command visibly carried all four
  values, dav1d configured and built, and its `mc_sse.obj` contained one
  `LC_BUILD_VERSION` with platform 7, minimum OS 18.0, and SDK 26.5. Repeating
  the retained slice with the official wrapper's `dup3`/`pipe2` cache overrides
  then completed VLC compilation, static module/contrib linking, and the final
  x86_64 archive with `Build succeeded!`. This targeted resume proves the
  causal fix but is not clean-build release evidence.
- The official NASM 3.02 binary was invoked through the patched wrapper to
  assemble a real x86_64 Mach-O object for each of the eight platform names.
  Every object contained exactly one `LC_BUILD_VERSION`, platform IDs
  1/2/3/6/7/8/11/12 respectively, minimum OS 18.0, and SDK 26.0.
- The nested libgcrypt patch dry-applied and applied to a clean libgcrypt
  1.10.1 tree. Compiling the affected source for x86_64 iOS Simulator changed
  the resulting `__TEXT,__text` alignment from `2^16` to `2^4`; the non-Apple
  source branch remains `.align 16`.
- A fresh checkout of upstream revision
  `c833c4be000b426d73ff4324bec574065f00e3df` verified every manifest hash and
  applied all 38 patches in order. Final 0037 passed its complete source proof
  (33 inherited 0034 mutations, inherited 0035/0036 source and patch suites,
  44 new source mutations, and three patch mutations) and all three native
  probes. Patch 0038 then passed 19 source/patch mutations, 30 wrapper cases,
  eight installer cases, and three cross-Meson environment cases.
- The final replay passed `git apply --reverse --check`; 0038 and 0037 were
  actually reversed. Reversing 0038 reproduced the 0001–0037 full-index binary
  diff SHA-256
  `4b2420a72eaeb0e5d790e1f945ccdfff6dd3463b98082f7bc51a377bd42f10dd`;
  reversing 0037 then reproduced the 0001–0036 full-index binary diff SHA-256
  `0f081b4cf8888bf4b4afed5cda7a7e052775e6671540f059b16b8364691baf21`.
  Both predecessor trees changed 98 upstream paths. A second fresh checkout
  replaying exactly 0001–0036 independently reproduced the latter identity;
  the older `f1e37e…` record used the pre-ARC patch 0032 and is historical.
  The complete 0036 validator and the post-pin legacy linked/native branch
  passed there. Forward checks and actual reapplications restored the final
  full-index binary diff SHA-256
  `ef189d468e0ed175050d471888fd5e6093f7200a48764c90791eb2d3b96c27fb`.
  Complete 0037, post-pin final linked/native, and 0038 validators then passed
  again, followed by a final reverse check and `git diff --check`.

## Release gate and residual risk

This is source-level and focused object-level evidence. It intentionally does
not claim a complete native libVLC build. A release candidate needs a clean
native rebuild: existing contrib configuration can cache an absolute assembler
path, and existing archives can retain old objects even when the source patch
is correct.

After that rebuild, `validate-libvlc-macho-metadata.py` is the non-negotiable
artifact gate. It must directly parse every XCFramework archive member and
prove exactly one `LC_BUILD_VERSION`, the expected platform and minimum OS,
CPU agreement, and section-alignment caps. This final gate also detects an
upstream source/pre-include pragma that changes NASM metadata, which a generic
command wrapper cannot safely infer without parsing third-party assembly.

Patch 0038 does not modify `build-libvlc.sh`, the patch manifest, release
qualification, Cast sources, or the direct Mach-O parser. Those integrations
remain owned by the surrounding release stack.

The frozen 0037 SHA above is now a compatibility input to this provenance
record. Any future 0037 change requires a new complete replay, a new evidence
record hash, and a corresponding standalone-validator hash update.
