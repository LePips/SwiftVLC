# libVLC archive-member inventories

Each directory under `sets/` is an immutable, complete inventory of the eight
XCFramework slices and 13 architectures shipped by SwiftVLC. Its 64-character
name is calculated from the canonical manifest bytes by
`scripts/libvlc-manifest-set.py` using a domain-separated, length-prefixed
SHA-256 construction.

`scripts/check-libvlc-manifest.sh` derives the inventory from the actual
XCFramework and accepts it only when that exact content-addressed set is
checked in. It validates every historical and prospective set so CI cannot
ignore a malformed set merely because `Package.swift` still points to an older
artifact.

After an intentional, fully validated native rebuild, add (never replace) its
inventory with:

```sh
./scripts/check-libvlc-manifest.sh --write
./scripts/check-libvlc-manifest.sh
```

The writer refuses partial slice/architecture sets and never falls back to the
only or newest directory. Existing sets remain available so the currently
published artifact and an upcoming release candidate can both be verified
without weakening the release gate.
