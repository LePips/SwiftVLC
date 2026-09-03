from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

QUALIFICATION = Path(__file__).resolve().parents[1]


def load_script(name: str):
    path = QUALIFICATION / name
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


policy = load_script("qualification_policy.py")
binding = load_script("candidate-build-binding.py")
candidate_metadata = load_script("candidate-metadata.py")
fixture_tree_binding = load_script("fixture-tree-binding.py")
test_catalog_authority = load_script("test-catalog-authority.py")


class CandidateBuildBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.source_authority = self.root / "source-authority"
        authority_swift = self.source_authority / "Sources" / "SwiftVLC"
        authority_swift.mkdir(parents=True)
        (authority_swift / "A.swift").write_text("struct A {}\n")
        (authority_swift / "Nested").mkdir()
        (authority_swift / "Nested" / "B.swift").write_text("struct B {}\n")
        authority_showcase = self.source_authority / "Showcase"
        (authority_showcase / "Shared").mkdir(parents=True)
        (authority_showcase / "iOS").mkdir()
        (authority_showcase / "UITests" / "iOS").mkdir(parents=True)
        (authority_showcase / "Shared" / "Common.swift").write_text(
            "struct CommonFixture {}\n"
        )
        (authority_showcase / "iOS" / "App.swift").write_text(
            "struct AppFixture {}\n"
        )
        (authority_showcase / "UITests" / "iOS" / "Probe.swift").write_text(
            "struct ProbeFixture {}\n"
        )
        (self.source_authority / "Package.swift").write_text(
            "// swift-tools-version: 6.0\n"
            ".binaryTarget(name: \"libvlc\", url: \"https://example.invalid/libvlc.zip\", checksum: \"deadbeef\")\n"
        )
        project = authority_showcase / "SwiftVLCShowcase.xcodeproj"
        (project / "xcshareddata" / "xcschemes").mkdir(parents=True)
        (project / "project.pbxproj").write_text(
            """/* Begin XCRemoteSwiftPackageReference section */
\t\tBA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */ = {
\t\t\tisa = XCRemoteSwiftPackageReference;
\t\t\trepositoryURL = "https://github.com/harflabs/SwiftVLC";
\t\t\trequirement = {
\t\t\t\tkind = exactVersion;
\t\t\t\tversion = 1.1.0-beta.8;
\t\t\t};
\t\t};
/* End XCRemoteSwiftPackageReference section */
BA000001 /* XCRemoteSwiftPackageReference "SwiftVLC" */,
DEVELOPMENT_TEAM = ABCDE12345;
DEVELOPMENT_TEAM = ABCDE12345;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios.uitests;
PRODUCT_BUNDLE_IDENTIFIER = com.swiftvlc.showcase.ios.uitests;
"""
        )
        (project / "xcshareddata" / "xcschemes" / "iOS.xcscheme").write_text(
            "<Scheme/>\n"
        )
        (authority_showcase / "iOS" / "Info.plist").write_text(
            "fixture plist\n"
        )
        scripts = self.source_authority / "scripts"
        scripts.mkdir()
        (scripts / "release-source-digest.py").write_text(
            f'import sys\nprint("{"b" * 64}")\n'
        )
        subprocess.run(["git", "init", "-q", str(self.source_authority)], check=True)
        subprocess.run(
            ["git", "-C", str(self.source_authority), "add", "."], check=True
        )
        subprocess.run(
            [
                "git",
                "-C",
                str(self.source_authority),
                "-c",
                "user.name=Fixture",
                "-c",
                "user.email=fixture@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-qm",
                "fixture authority",
            ],
            check=True,
        )
        self.source_commit = subprocess.run(
            ["git", "-C", str(self.source_authority), "rev-parse", "HEAD"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        self.source = self.root / "source"
        shutil.copytree(self.source_authority / "Sources", self.source / "Sources")
        shutil.copytree(self.source_authority / "Showcase", self.source / "Showcase")
        shutil.copy2(self.source_authority / "Package.swift", self.source / "Package.swift")
        (self.source / "Package.swift").write_text(
            binding.expected_local_package(
                (self.source_authority / "Package.swift").read_text()
            )
        )
        effective_project = (
            self.source / "Showcase" / "SwiftVLCShowcase.xcodeproj" / "project.pbxproj"
        )
        effective_project.write_text(
            binding.expected_local_signed_project(
                (
                    self.source_authority
                    / "Showcase"
                    / "SwiftVLCShowcase.xcodeproj"
                    / "project.pbxproj"
                ).read_text(),
                "ABCDEFGHIJ",
                "com.swiftvlc.validation.fixture",
            )
        )
        self.swift_root = self.source / "Sources" / "SwiftVLC"
        self.authority = self.root / "authority" / "Vendor" / "libvlc.xcframework"
        self.authority.mkdir(parents=True)
        (self.authority / "Info.plist").write_text("fixture artifact\n")
        (self.source / "Vendor").symlink_to(self.authority.parent)
        self.derived = self.root / "DerivedData"
        self.workspace_path = (
            self.derived / "SourcePackages" / "workspace-state.json"
        )
        self.workspace_path.parent.mkdir(parents=True)
        self.write_workspace(self.local_dependency(), self.local_artifact())
        self.build_settings = self.root / "effective-build-settings.json"
        self.write_build_settings()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def local_ref(self) -> dict:
        return {
            "identity": "source",
            "kind": "fileSystem",
            "location": str(self.source.absolute()),
            "name": "SwiftVLC",
        }

    def local_dependency(self) -> dict:
        return {
            "packageRef": self.local_ref(),
            "state": {
                "name": "fileSystem",
                "path": str(self.source.absolute()),
            },
            "subpath": "source",
        }

    def local_artifact(self) -> dict:
        return {
            "kind": {"xcframework": {}},
            "packageRef": self.local_ref(),
            "path": str(
                (self.source / "Vendor" / "libvlc.xcframework").absolute()
            ),
            "source": {"type": "local"},
            "targetName": "libvlc",
        }

    @staticmethod
    def remote_ref() -> dict:
        return {
            "identity": "swiftvlc",
            "kind": "remoteSourceControl",
            "location": "https://github.com/harflabs/SwiftVLC",
            "name": "SwiftVLC",
        }

    def remote_dependency(self) -> dict:
        return {
            "packageRef": self.remote_ref(),
            "state": {
                "checkoutState": {
                    "revision": "051b780" + "0" * 33,
                    "version": "1.1.0-beta.8",
                },
                "name": "sourceControlCheckout",
            },
            "subpath": "SwiftVLC",
        }

    def remote_artifact(self) -> dict:
        return {
            "kind": {"xcframework": {}},
            "packageRef": self.remote_ref(),
            "path": str(
                self.derived
                / "SourcePackages"
                / "artifacts"
                / "swiftvlc"
                / "libvlc"
                / "libvlc.xcframework"
            ),
            "source": {
                "type": "remote",
                "url": (
                    "https://github.com/harflabs/SwiftVLC/releases/download/"
                    "1.1.0-beta.8/libvlc.xcframework.zip"
                ),
            },
            "targetName": "libvlc",
        }

    def write_workspace(self, dependencies: dict | list, artifacts: dict | list) -> None:
        if isinstance(dependencies, dict):
            dependencies = [dependencies]
        if isinstance(artifacts, dict):
            artifacts = [artifacts]
        self.workspace_path.write_text(
            json.dumps(
                {
                    "object": {
                        "artifacts": artifacts,
                        "dependencies": dependencies,
                        "prebuilts": [],
                    },
                    "version": 7,
                },
                sort_keys=True,
            )
        )

    def args(self) -> argparse.Namespace:
        return argparse.Namespace(
            source_root=self.source,
            source_authority=self.source_authority,
            artifact_authority=self.authority,
            derived_data=self.derived,
            build_settings=self.build_settings,
            development_team="ABCDEFGHIJ",
            bundle_prefix="com.swiftvlc.validation.fixture",
            source_commit=self.source_commit,
            release_source_digest="b" * 64,
            version="1.1.0-beta.9",
            candidate_runtime_binding="1" * 64,
            configuration="Release",
            platform="iphoneos",
        )

    def write_build_settings(self, *, swift_flags: str = "") -> None:
        self.build_settings.write_text(
            json.dumps(
                [
                    {
                        "target": target,
                        "buildSettings": {
                            "ARCHS": "arm64",
                            "CONFIGURATION": "Release",
                            "OTHER_LDFLAGS": "",
                            "OTHER_SWIFT_FLAGS": swift_flags,
                            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": (
                                "SWIFT_PACKAGE" if target == "SwiftVLC" else ""
                            ),
                            "SWIFT_OPTIMIZATION_LEVEL": "-O",
                            "SWIFT_VERSION": "6.0",
                        },
                    }
                    for target in ("iOS", "iOSUITests", "SwiftVLC")
                ]
            )
        )

    def filelist_path(self) -> Path:
        path = (
            binding.filelist_root(self.derived, "Release", "iphoneos")
            / "arm64"
            / "SwiftVLC.SwiftFileList"
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def exact_entries(self) -> list[str]:
        return [
            str((self.swift_root / relative).absolute())
            for relative in ("A.swift", "Nested/B.swift")
        ]

    def write_filelist(self, entries: list[str] | None = None) -> Path:
        path = self.filelist_path()
        path.write_text("\n".join(entries or self.exact_entries()) + "\n")
        return path

    def showcase_filelist_path(self, target: str) -> Path:
        path = (
            self.derived
            / "Build"
            / "Intermediates.noindex"
            / "SwiftVLCShowcase.build"
            / "Release-iphoneos"
            / f"{target}.build"
            / "Objects-normal"
            / "arm64"
            / f"{target}.SwiftFileList"
        )
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def showcase_entries(self, target: str) -> list[str]:
        prefixes = ("Shared/", "iOS/") if target == "iOS" else (
            "Shared/",
            "UITests/iOS/",
        )
        sources = sorted(
            str(path.absolute())
            for path in (self.source / "Showcase").rglob("*.swift")
            if path.relative_to(self.source / "Showcase").as_posix().startswith(prefixes)
        )
        filelist = self.showcase_filelist_path(target)
        generated = filelist.parents[2] / "DerivedSources" / "GeneratedAssetSymbols.swift"
        generated.parent.mkdir(parents=True, exist_ok=True)
        generated.write_text(f"// generated for {target}\n")
        return sources + [str(generated.absolute())]

    def write_showcase_filelists(
        self, overrides: dict[str, list[str]] | None = None
    ) -> None:
        for target in ("iOS", "iOSUITests"):
            entries = (overrides or {}).get(target, self.showcase_entries(target))
            self.showcase_filelist_path(target).write_text("\n".join(entries) + "\n")

    def attach_products(self, receipt: dict) -> None:
        products = self.root / "staged-products"
        candidate_app = products / "Release-iphoneos" / "iOS.app"
        test_runner = products / "Release-iphoneos" / "iOSUITests-Runner.app"
        test_bundle = test_runner / "PlugIns" / "iOSUITests.xctest"
        candidate_app.mkdir(parents=True, exist_ok=True)
        test_bundle.mkdir(parents=True, exist_ok=True)
        (candidate_app / "payload").write_text("signed candidate")
        (test_runner / "runner-payload").write_text("signed runner")
        (test_bundle / "test-payload").write_text("signed tests")
        xctestrun = products / "iOS_iphoneos.xctestrun"
        xctestrun.write_text("base xctestrun")
        receipt.update(
            {
                "candidateApp": str(candidate_app),
                "testRunner": str(test_runner),
                "testBundle": str(test_bundle),
                "baseXCTestRun": str(xctestrun),
            }
        )

    def successful_attestation(self) -> dict:
        receipt = binding.make_receipt(self.args())
        self.write_filelist()
        self.write_showcase_filelists()
        self.attach_products(receipt)
        attestation = binding.make_attestation(receipt)
        catalog = policy.catalog_record(["iOSUITests/FixtureTests/test_binding"])
        catalog_path = self.root / "catalog.json"
        catalog_path.write_text(json.dumps(catalog))
        return binding.bind_catalog(attestation, catalog_path)

    def test_exact_local_resolution_and_vendor_authority_symlink_are_attested(self):
        attestation = self.successful_attestation()
        self.assertEqual(
            attestation["artifactBindingMode"],
            "vendor-symlink-to-authority-root",
        )
        self.assertEqual(attestation["swiftSourceCount"], 2)
        self.assertEqual(attestation["swiftFileLists"][0]["architecture"], "arm64")
        self.assertEqual(
            {item["target"] for item in attestation["showcaseTargetFileLists"]},
            {"iOS", "iOSUITests"},
        )
        self.assertNotIn(str(self.root), json.dumps(attestation))
        policy.validate_candidate_build_attestation(attestation)

    def test_remote_beta_eight_resolution_is_rejected(self):
        self.write_workspace(self.remote_dependency(), self.remote_artifact())
        with self.assertRaisesRegex(binding.BuildBindingError, "sourceControl"):
            binding.make_receipt(self.args())

    def test_wrong_local_root_is_rejected(self):
        dependency = self.local_dependency()
        dependency["state"]["path"] = str(self.root / "other-source")
        self.write_workspace(dependency, self.local_artifact())
        with self.assertRaisesRegex(binding.BuildBindingError, "exact build source root"):
            binding.make_receipt(self.args())

    def test_duplicate_mixed_local_and_remote_resolution_is_rejected(self):
        self.write_workspace(
            [self.local_dependency(), self.remote_dependency()],
            [self.local_artifact(), self.remote_artifact()],
        )
        with self.assertRaisesRegex(binding.BuildBindingError, "exactly one SwiftVLC"):
            binding.make_receipt(self.args())

    def test_vendor_symlink_escape_is_rejected(self):
        (self.source / "Vendor").unlink()
        escaped = self.root / "unattested" / "Vendor"
        (escaped / "libvlc.xcframework").mkdir(parents=True)
        (escaped / "libvlc.xcframework" / "payload").write_text("wrong")
        (self.source / "Vendor").symlink_to(escaped)
        with self.assertRaisesRegex(binding.BuildBindingError, "exact attested"):
            binding.make_receipt(self.args())

    def test_missing_swift_source_in_filelist_is_rejected(self):
        receipt = binding.make_receipt(self.args())
        self.write_filelist(self.exact_entries()[:-1])
        with self.assertRaisesRegex(binding.BuildBindingError, "missing="):
            binding.make_attestation(receipt)

    def test_build_source_byte_mutation_before_prebuild_is_rejected(self):
        (self.swift_root / "A.swift").write_text("struct Injected {}\n")
        with self.assertRaisesRegex(binding.BuildBindingError, "bytes/modes"):
            binding.make_receipt(self.args())

    def test_build_source_byte_mutation_after_prebuild_is_rejected(self):
        receipt = binding.make_receipt(self.args())
        (self.swift_root / "A.swift").write_text("struct Injected {}\n")
        self.write_filelist()
        with self.assertRaisesRegex(binding.BuildBindingError, "bytes/modes"):
            binding.make_attestation(receipt)

    def test_showcase_ui_test_byte_mutation_is_rejected(self):
        receipt = binding.make_receipt(self.args())
        (self.source / "Showcase" / "UITests" / "iOS" / "Probe.swift").write_text(
            "struct InjectedProbe {}\n"
        )
        self.write_filelist()
        with self.assertRaisesRegex(binding.BuildBindingError, "Showcase"):
            binding.make_attestation(receipt)

    def test_unapproved_non_swift_build_input_overlay_is_rejected(self):
        (self.source / "Showcase" / "iOS" / "Info.plist").write_text(
            "injected background modes\n"
        )
        with self.assertRaisesRegex(binding.BuildBindingError, "clean source authority"):
            binding.make_receipt(self.args())

    def test_build_input_or_effective_settings_mutation_after_prebuild_is_rejected(self):
        for mutation in ("input", "settings"):
            with self.subTest(mutation=mutation):
                receipt = binding.make_receipt(self.args())
                if mutation == "input":
                    (self.source / "Showcase" / "iOS" / "Info.plist").write_text(
                        "mutated after prebuild\n"
                    )
                else:
                    self.write_build_settings(swift_flags="-DUNATTESTED")
                self.write_filelist()
                self.write_showcase_filelists()
                with self.assertRaisesRegex(
                    binding.BuildBindingError,
                    "(build input|effectiveBuildSettings|forbidden compile/link flags)",
                ):
                    binding.make_attestation(receipt)
                shutil.copy2(
                    self.source_authority / "Showcase" / "iOS" / "Info.plist",
                    self.source / "Showcase" / "iOS" / "Info.plist",
                )
                self.write_build_settings()

    def test_omitted_ui_test_compile_input_is_rejected(self):
        receipt = binding.make_receipt(self.args())
        self.write_filelist()
        ui_entries = self.showcase_entries("iOSUITests")
        omitted = [
            entry for entry in ui_entries if not entry.endswith("Probe.swift")
        ]
        self.write_showcase_filelists({"iOSUITests": omitted})
        with self.assertRaisesRegex(binding.BuildBindingError, "iOSUITests.*missing="):
            binding.make_attestation(receipt)

    def test_unchanged_ui_test_filelist_is_rejected_as_stale(self):
        self.write_showcase_filelists()
        receipt = binding.make_receipt(self.args())
        self.write_filelist()
        with self.assertRaisesRegex(binding.BuildBindingError, "iOS.*not refreshed"):
            binding.make_attestation(receipt)

    def test_wrong_claimed_source_commit_and_digest_are_rejected(self):
        bad_commit = self.args()
        bad_commit.source_commit = "f" * 40
        with self.assertRaisesRegex(binding.BuildBindingError, "claimed source commit"):
            binding.make_receipt(bad_commit)
        bad_digest = self.args()
        bad_digest.release_source_digest = "e" * 64
        with self.assertRaisesRegex(
            binding.BuildBindingError, "claimed release source digest"
        ):
            binding.make_receipt(bad_digest)

    def test_persistent_source_authority_mutation_after_prebuild_is_rejected(self):
        receipt = binding.make_receipt(self.args())
        (self.source_authority / "Showcase" / "Shared" / "Common.swift").write_text(
            "struct MutatedAuthority {}\n"
        )
        self.write_filelist()
        self.write_showcase_filelists()
        with self.assertRaisesRegex(
            binding.BuildBindingError, "source authority checkout must be clean"
        ):
            binding.make_attestation(receipt)

    def test_extra_swift_source_in_filelist_is_rejected(self):
        receipt = binding.make_receipt(self.args())
        self.write_filelist(self.exact_entries() + [str(self.root / "Injected.swift")])
        with self.assertRaisesRegex(binding.BuildBindingError, "extra="):
            binding.make_attestation(receipt)

    def test_remote_checkout_swift_filelist_is_rejected(self):
        receipt = binding.make_receipt(self.args())
        remote = self.derived / "SourcePackages" / "checkouts" / "SwiftVLC"
        entries = [str(remote / "Sources" / "SwiftVLC" / Path(item).name) for item in self.exact_entries()]
        self.write_filelist(entries)
        with self.assertRaisesRegex(binding.BuildBindingError, "does not exactly match"):
            binding.make_attestation(receipt)

    def test_unchanged_prebuild_swift_filelist_is_rejected_as_stale(self):
        self.write_filelist()
        receipt = binding.make_receipt(self.args())
        with self.assertRaisesRegex(binding.BuildBindingError, "not refreshed"):
            binding.make_attestation(receipt)

    def test_missing_swift_filelist_is_rejected_with_rebuild_action(self):
        receipt = binding.make_receipt(self.args())
        with self.assertRaisesRegex(binding.BuildBindingError, "rerun build-for-testing"):
            binding.make_attestation(receipt)

    def strict_candidate(self, attestation: dict) -> dict:
        catalog = ["iOSUITests/FixtureTests/test_binding"]
        return {
            "formatVersion": 2,
            "version": "1.1.0-beta.9",
            "candidateRuntimeBinding": attestation["candidateRuntimeBinding"],
            "sourceCommit": attestation["sourceCommit"],
            "releaseSourceDigestAlgorithm": "swiftvlc-git-tree-v1",
            "releaseSourceDigest": attestation["releaseSourceDigest"],
            "artifactDigestAlgorithm": "swiftvlc-tree-v1",
            "artifactDigest": attestation["artifactDigest"],
            "candidateBuildAttestation": attestation,
            "candidateBuildAttestationDigestAlgorithm": "sha256",
            "candidateBuildAttestationDigest": hashlib.sha256(
                policy.canonical_json_bytes(attestation)
            ).hexdigest(),
            "candidateAppBundleIdentifier": "com.swiftvlc.fixture.app",
            "candidateAppDigestAlgorithm": "swiftvlc-tree-v1",
            "candidateAppDigest": attestation["candidateAppDigest"],
            "testRunnerBundleIdentifier": "com.swiftvlc.fixture.uitests.xctrunner",
            "testRunnerDigestAlgorithm": "swiftvlc-tree-v1",
            "testRunnerDigest": attestation["testRunnerDigest"],
            "testBundleRelativePath": attestation["testBundleRelativePath"],
            "testBundleDigestAlgorithm": "swiftvlc-tree-v1",
            "testBundleDigest": attestation["testBundleDigest"],
            "baseXCTestRunDigestAlgorithm": "sha256",
            "baseXCTestRunDigest": attestation["baseXCTestRunDigest"],
            "baseXCTestRunName": attestation["baseXCTestRunName"],
            "testCatalogDigestAlgorithm": "swiftvlc-test-catalog-v1",
            "testCatalogDigest": attestation["testCatalogDigest"],
            "testCatalogCount": attestation["testCatalogCount"],
            "testCatalog": attestation["testCatalog"],
            "testCatalogAuthorityDigestAlgorithm": "sha256",
            "testCatalogAuthorityDigest": "0" * 64,
            "qualificationMatrixChecksum": "1" * 64,
            "featureManifestChecksum": "2" * 64,
            "qualificationProfilesChecksum": "3" * 64,
            "fixtureManifestChecksum": "4" * 64,
            "qualificationPolicyDigestAlgorithm": "swiftvlc-qualification-policy-v1",
            "qualificationPolicyDigest": policy.policy_digest(),
        }

    def test_metadata_rejects_attestation_and_outer_digest_tampering(self):
        attestation = self.successful_attestation()
        candidate = self.strict_candidate(attestation)
        policy.validate_candidate_identity(candidate, strict=True)

        tampered = json.loads(json.dumps(candidate))
        tampered["candidateBuildAttestation"]["workspaceStateDigest"] = "9" * 64
        with self.assertRaisesRegex(policy.QualificationPolicyError, "digest mismatch"):
            policy.validate_candidate_identity(tampered, strict=True)

        tampered = json.loads(json.dumps(candidate))
        tampered["candidateBuildAttestation"]["workspaceBinding"][
            "artifactSourceType"
        ] = "remote"
        tampered["candidateBuildAttestationDigest"] = hashlib.sha256(
            policy.canonical_json_bytes(tampered["candidateBuildAttestation"])
        ).hexdigest()
        with self.assertRaisesRegex(policy.QualificationPolicyError, "exact local"):
            policy.validate_candidate_identity(tampered, strict=True)

        for field in (
            "candidateAppDigest",
            "testRunnerDigest",
            "testBundleDigest",
            "baseXCTestRunDigest",
            "testCatalogDigest",
        ):
            with self.subTest(product_binding=field):
                tampered = json.loads(json.dumps(candidate))
                tampered[field] = "0" * 64
                with self.assertRaisesRegex(
                    policy.QualificationPolicyError,
                    f"{field} does not match candidate metadata",
                ):
                    policy.validate_candidate_identity(tampered, strict=True)

    def test_prebuilt_beta_attestation_cannot_be_relabelled_stable(self):
        args = self.args()
        args.version = "1.1.0-beta.1"
        receipt = binding.make_receipt(args)
        self.write_filelist()
        self.write_showcase_filelists()
        self.attach_products(receipt)
        catalog_path = self.root / "beta-catalog.json"
        catalog_path.write_text(
            json.dumps(policy.catalog_record(["iOSUITests/FixtureTests/test_binding"]))
        )
        attestation = binding.bind_catalog(
            binding.make_attestation(receipt), catalog_path
        )
        candidate = self.strict_candidate(attestation)
        candidate["version"] = "1.1.0"
        with self.assertRaisesRegex(
            policy.QualificationPolicyError,
            "attestation version does not match candidate metadata",
        ):
            policy.validate_candidate_identity(candidate, strict=True)

        app = self.root / "Versioned.app"
        app.mkdir()
        with (app / "Info.plist").open("wb") as output:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.swiftvlc.fixture.app",
                    "SwiftVLCCandidateVersion": attestation["version"],
                    "SwiftVLCCandidateRuntimeBinding": attestation[
                        "candidateRuntimeBinding"
                    ],
                    "SwiftVLCSourceCommit": attestation["sourceCommit"],
                    "SwiftVLCReleaseSourceDigest": attestation[
                        "releaseSourceDigest"
                    ],
                    "SwiftVLCArtifactDigest": attestation["artifactDigest"],
                },
                output,
            )
        digest_script = self.root / "version-digest.py"
        digest_script.write_text(f'print("{attestation["artifactDigest"]}")\n')
        with self.assertRaisesRegex(
            candidate_metadata.CandidateMetadataError,
            "attestation version does not match --version",
        ):
            candidate_metadata.create(
                app,
                self.authority,
                "1.1.0",
                digest_script,
                {},
                attestation,
            )

    def test_plist_only_self_stamp_cannot_create_strict_metadata(self):
        app = self.root / "iOS.app"
        app.mkdir()
        with (app / "Info.plist").open("wb") as output:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.swiftvlc.fixture.app",
                    "SwiftVLCSourceCommit": "a" * 40,
                    "SwiftVLCReleaseSourceDigest": "b" * 64,
                    "SwiftVLCArtifactDigest": "c" * 64,
                },
                output,
            )
        digest_script = self.root / "digest.py"
        digest_script.write_text(f'print("{"c" * 64}")\n')
        with self.assertRaisesRegex(
            candidate_metadata.CandidateMetadataError, "Info.plist identity stamps alone"
        ):
            candidate_metadata.create(
                app,
                self.authority,
                "1.1.0-beta.9",
                digest_script,
                {},
            )

    def xctestrun_products(self) -> tuple[Path, Path, Path, Path, dict]:
        products = self.root / "Products"
        configuration = products / "Release-iphoneos"
        candidate_app = configuration / "iOS.app"
        test_runner = configuration / "iOSUITests-Runner.app"
        test_bundle = test_runner / "PlugIns" / "iOSUITests.xctest"
        test_bundle.mkdir(parents=True)
        candidate_app.mkdir(parents=True)
        with (candidate_app / "Info.plist").open("wb") as output:
            plistlib.dump({"CFBundleIdentifier": "com.swiftvlc.fixture.app"}, output)
        with (test_runner / "Info.plist").open("wb") as output:
            plistlib.dump(
                {
                    "CFBundleIdentifier": (
                        "com.swiftvlc.fixture.uitests.xctrunner"
                    )
                },
                output,
            )
        xctestrun = products / "iOS_iphoneos.xctestrun"
        target = {
            "IsUITestBundle": True,
            "ProductModuleName": "iOSUITests",
            "TestHostPath": "__TESTROOT__/Release-iphoneos/iOSUITests-Runner.app",
            "TestBundlePath": "__TESTHOST__/PlugIns/iOSUITests.xctest",
            "UITargetAppPath": "__TESTROOT__/Release-iphoneos/iOS.app",
            "DependentProductPaths": [
                "__TESTROOT__/Release-iphoneos/iOS.app",
                "__TESTROOT__/Release-iphoneos/iOSUITests-Runner.app",
                (
                    "__TESTROOT__/Release-iphoneos/iOSUITests-Runner.app/"
                    "PlugIns/iOSUITests.xctest"
                ),
            ],
            "TestHostBundleIdentifier": (
                "com.swiftvlc.fixture.uitests.xctrunner"
            ),
        }
        return xctestrun, candidate_app, test_runner, test_bundle, target

    def test_xctestrun_paths_must_resolve_to_exact_hashed_products(self):
        xctestrun, candidate_app, test_runner, test_bundle, target = (
            self.xctestrun_products()
        )
        with xctestrun.open("wb") as output:
            plistlib.dump(
                {"TestConfigurations": [{"TestTargets": [target]}]}, output
            )
        candidate_metadata.validate_xctestrun_products(
            xctestrun,
            candidate_app=candidate_app,
            test_runner=test_runner,
            test_bundle=test_bundle,
        )

        for field, replacement in (
            ("TestHostPath", "__TESTROOT__/Release-iphoneos/Other-Runner.app"),
            ("TestBundlePath", "__TESTHOST__/PlugIns/Other.xctest"),
            ("UITargetAppPath", "__TESTROOT__/Release-iphoneos/Other.app"),
        ):
            with self.subTest(field=field):
                other = self.root / "Products" / "Release-iphoneos"
                if field == "TestHostPath":
                    (
                        other
                        / "Other-Runner.app"
                        / "PlugIns"
                        / "iOSUITests.xctest"
                    ).mkdir(parents=True)
                elif field == "TestBundlePath":
                    (test_runner / "PlugIns" / "Other.xctest").mkdir()
                else:
                    (other / "Other.app").mkdir()
                mutated = dict(target, **{field: replacement})
                with xctestrun.open("wb") as output:
                    plistlib.dump(
                        {"TestConfigurations": [{"TestTargets": [mutated]}]},
                        output,
                    )
                with self.assertRaisesRegex(
                    candidate_metadata.CandidateMetadataError,
                    "does not reference the exact hashed product",
                ):
                    candidate_metadata.validate_xctestrun_products(
                        xctestrun,
                        candidate_app=candidate_app,
                        test_runner=test_runner,
                        test_bundle=test_bundle,
                    )

    def test_xctestrun_cannot_omit_its_ui_test_target(self):
        xctestrun, candidate_app, test_runner, test_bundle, _ = (
            self.xctestrun_products()
        )
        with xctestrun.open("wb") as output:
            plistlib.dump({"TestConfigurations": [{"TestTargets": []}]}, output)
        with self.assertRaisesRegex(
            candidate_metadata.CandidateMetadataError,
            "exactly one UI-test target",
        ):
            candidate_metadata.validate_xctestrun_products(
                xctestrun,
                candidate_app=candidate_app,
                test_runner=test_runner,
                test_bundle=test_bundle,
            )

    def test_xctestrun_cannot_prefilter_or_inject_candidate_controls(self):
        xctestrun, candidate_app, test_runner, test_bundle, target = (
            self.xctestrun_products()
        )
        mutations = {
            "filter": {"OnlyTestIdentifiers": ["FixtureTests/test_one"]},
            "test environment": {
                "TestingEnvironmentVariables": {"SWIFTVLC_PIP_LIVE_URL": "wrong"}
            },
            "app environment": {
                "UITargetAppEnvironmentVariables": {
                    "SWIFTVLC_QUALIFICATION_MODE": "forged"
                }
            },
            "arguments": {"UITargetAppCommandLineArguments": ["--forged"]},
        }
        for label, mutation in mutations.items():
            with self.subTest(label=label):
                mutated = dict(target, **mutation)
                with xctestrun.open("wb") as output:
                    plistlib.dump(
                        {"TestConfigurations": [{"TestTargets": [mutated]}]},
                        output,
                    )
                with self.assertRaises(candidate_metadata.CandidateMetadataError):
                    candidate_metadata.validate_xctestrun_products(
                        xctestrun,
                        candidate_app=candidate_app,
                        test_runner=test_runner,
                        test_bundle=test_bundle,
                    )


class FixtureTreeBindingTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "fixtures"
        self.root.mkdir()
        (self.root / "media").mkdir()
        self.payload = self.root / "media" / "fixture.bin"
        self.payload.write_bytes(b"candidate fixture")
        digest = hashlib.sha256(self.payload.read_bytes()).hexdigest()
        (self.root / "manifest.json").write_text(
            json.dumps(
                {
                    "formatVersion": 1,
                    "files": {
                        "media/fixture.bin": {
                            "bytes": self.payload.stat().st_size,
                            "sha256": digest,
                        }
                    },
                }
            )
        )

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_exact_fixture_tree_binding_is_stable(self):
        first = fixture_tree_binding.fixture_binding(self.root)
        second = fixture_tree_binding.fixture_binding(self.root)
        self.assertEqual(first, second)
        self.assertEqual(first["fileCount"], 1)

    def test_persistent_fixture_mutation_is_rejected(self):
        fixture_tree_binding.fixture_binding(self.root)
        self.payload.write_bytes(b"mutated during server run")
        with self.assertRaisesRegex(
            fixture_tree_binding.FixtureTreeBindingError,
            "no longer match manifest",
        ):
            fixture_tree_binding.fixture_binding(self.root)

    def test_extra_or_symlinked_fixture_is_rejected(self):
        (self.root / "extra.bin").write_bytes(b"extra")
        with self.assertRaisesRegex(
            fixture_tree_binding.FixtureTreeBindingError, "file set mismatch"
        ):
            fixture_tree_binding.fixture_binding(self.root)
        (self.root / "extra.bin").unlink()
        (self.root / "escape.bin").symlink_to(self.payload)
        with self.assertRaisesRegex(
            fixture_tree_binding.FixtureTreeBindingError, "contains a symlink"
        ):
            fixture_tree_binding.fixture_binding(self.root)


class CaptureBuildSettingsTests(unittest.TestCase):
    def invoke(self, source: str) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            stderr_path = Path(temporary) / "xcodebuild.stderr"
            return subprocess.run(
                [
                    "python3",
                    str(QUALIFICATION / "capture-build-settings.py"),
                    "--stderr",
                    str(stderr_path),
                    "--",
                    "python3",
                    "-c",
                    source,
                ],
                text=True,
                capture_output=True,
                check=False,
            )

    def test_emits_only_canonical_json(self):
        completed = self.invoke(
            "import sys; print('xcode diagnostic', file=sys.stderr); "
            "print('[{\"target\": \"iOS\", \"buildSettings\": {\"B\": \"2\", \"A\": \"1\"}}]')"
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertEqual(
            completed.stdout,
            '[{"buildSettings":{"A":"1","B":"2"},"target":"iOS"}]\n',
        )
        self.assertNotIn("diagnostic", completed.stdout)

    def test_rejects_malformed_or_mixed_stdout(self):
        for source in (
            "print('not json')",
            "print('warning\\n[]')",
            "print('{\"target\": \"iOS\"}')",
        ):
            with self.subTest(source=source):
                completed = self.invoke(source)
                self.assertNotEqual(completed.returncode, 0)
                self.assertEqual(completed.stdout, "")
                self.assertRegex(
                    completed.stderr,
                    r"Error: xcodebuild (?:did not emit pure JSON|build-settings JSON is empty)",
                )

    def test_propagates_subprocess_exit_status_without_json(self):
        completed = self.invoke("import sys; sys.exit(7)")
        self.assertEqual(completed.returncode, 7)
        self.assertEqual(completed.stdout, "")


class RunnerBuildBindingIntegrationTests(unittest.TestCase):
    def test_runner_resolves_attests_builds_and_binds_metadata_in_order(self):
        runner = (QUALIFICATION / "run-device-tests.sh").read_text()
        ordered_needles = (
            '"$BUILD_SOURCE_ROOT/scripts/setup-dev.sh" --skip-download',
            "xcodebuild -resolvePackageDependencies",
            "build_args=(",
            'candidate-build-binding.py" prebuild',
            '"$OUTPUT_DIR/build.log"',
            'candidate-build-binding.py" postbuild',
            'candidate-metadata.py" create',
            '--build-attestation "$BUILD_ATTESTATION"',
        )
        positions = [runner.index(needle) for needle in ordered_needles]
        self.assertEqual(positions, sorted(positions))

    def test_runner_rechecks_fixture_and_source_authorities_before_validation(self):
        runner = (QUALIFICATION / "run-device-tests.sh").read_text()
        stop = runner.rindex("stop_fixture_server")
        fixture_recheck = runner.index('fixture-tree-binding.py" verify', stop)
        report = runner.index('"$RESULTS_TSV" "$OUTPUT_DIR/report.json"', fixture_recheck)
        validation = runner.rindex('report_validation.py"')
        self.assertLess(fixture_recheck, report)
        self.assertGreaterEqual(runner.count("assert_source_authority_unchanged\n"), 2)
        self.assertLess(runner.rindex("assert_source_authority_unchanged\n"), validation)
        self.assertIn('STAGED_FIXTURES="$WORK_DIR/qualification-fixtures"', runner)
        self.assertIn('--root "$STAGED_FIXTURES"', runner)
        self.assertIn('FIXTURES="$STAGED_FIXTURES"', runner)

    def test_skip_build_revalidates_strict_embedded_metadata(self):
        runner = (QUALIFICATION / "run-device-tests.sh").read_text()
        prebuilt = runner.index('if [[ "$PREBUILT_CANDIDATE" == true ]]')
        create = runner.index('candidate-metadata.py" create', prebuilt)
        section = runner[prebuilt:create]
        self.assertIn('candidate-metadata.py" verify', section)
        self.assertIn('--metadata "$CANDIDATE_METADATA"', section)
        self.assertIn('if [[ "$PREBUILT_CANDIDATE" == false ]]', runner)


class TestCatalogAuthorityTests(unittest.TestCase):
    def test_reviewed_catalog_requires_exact_enumerated_leaf_set(self):
        reviewed_catalog = policy.catalog_record(
            [
                "iOSUITests/FixtureTests/test_first",
                "iOSUITests/FixtureTests/test_second",
            ]
        )
        authority = test_catalog_authority.authority_record(reviewed_catalog)
        self.assertEqual(
            test_catalog_authority.verify_catalog(reviewed_catalog, authority),
            authority,
        )
        diminished = policy.catalog_record(
            ["iOSUITests/FixtureTests/test_first"]
        )
        with self.assertRaisesRegex(
            test_catalog_authority.TestCatalogAuthorityError,
            "missing=.*test_second",
        ):
            test_catalog_authority.verify_catalog(diminished, authority)

    def test_reviewed_catalog_digest_tampering_is_rejected(self):
        catalog = policy.catalog_record(
            ["iOSUITests/FixtureTests/test_first"]
        )
        authority = test_catalog_authority.authority_record(catalog)
        authority["testCatalogDigest"] = "0" * 64
        with self.assertRaisesRegex(
            test_catalog_authority.TestCatalogAuthorityError,
            "digest/count drifted",
        ):
            test_catalog_authority.validate_authority(authority)

if __name__ == "__main__":
    unittest.main()
