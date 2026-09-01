from __future__ import annotations

import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path
import tempfile
import textwrap
from typing import Optional
import unittest


VALIDATION_DIRECTORY = (
    Path(__file__).resolve().parents[1] / "patches" / "validation"
)
sys.path.insert(0, str(VALIDATION_DIRECTORY))
import pip_extension_version as version  # noqa: E402


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_VALIDATOR = REPOSITORY_ROOT / "scripts/validate-native-extension-contract.sh"

VERSIONED_ARCHIVE_SYMBOLS = {
    1: (
        "swiftvlc_libvlc_pip_extensions_version",
        "swiftvlc_libvlc_media_player_get_media_length_snapshot",
        "swiftvlc_libvlc_video_set_format_callbacks_ex",
    ),
    2: ("swiftvlc_libvlc_media_player_get_playback_snapshot",),
    4: (
        "swiftvlc_libvlc_media_player_request_next_frame",
        "swiftvlc_libvlc_media_player_cancel_next_frame_request",
        "swiftvlc_libvlc_video_set_display_status_callback",
        "swiftvlc_libvlc_video_set_callbacks_atomic",
    ),
    5: (
        "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot",
    ),
    6: ("swiftvlc_libvlc_video_set_callbacks_atomic_v2",),
    8: (
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot",
        "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization",
    ),
}
LEASE_ARCHIVE_SYMBOLS = (
    "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease",
    "swiftvlc_libvlc_media_player_release_apple_audio_session_lease",
)


def synthetic_sources(
        highest_version: int, *, leases: bool = False,
        omitted_versions: tuple[int, ...] = ()) -> dict[str, str]:
    sources = {
        "public_header": (
            "unsigned swiftvlc_libvlc_pip_extensions_version(void);\n"
        ),
        "events_header": "typedef struct libvlc_event_t libvlc_event_t;\n",
        "media_player": (
            "unsigned swiftvlc_libvlc_pip_extensions_version(void)\n"
            f"{{ return {highest_version}; }}\n"
        ),
        "exports": "swiftvlc_libvlc_pip_extensions_version\n",
    }
    fragments = {
        4: {
            "public_header": (
                "typedef enum swiftvlc_next_frame_request_result_t {\n"
                "    swiftvlc_next_frame_request_accepted = 0,\n"
                "} swiftvlc_next_frame_request_result_t;\n"
                "swiftvlc_next_frame_request_result_t\n"
                "swiftvlc_libvlc_media_player_request_next_frame(void);\n"
                "bool swiftvlc_libvlc_media_player_cancel_next_frame_request(void);\n"
                "void swiftvlc_libvlc_video_set_display_status_callback(void);\n"
                "int swiftvlc_libvlc_video_set_callbacks_atomic(void);\n"
            ),
            "media_player": (
                "int swiftvlc_libvlc_media_player_request_next_frame(void) "
                "{ return 0; }\n"
                "bool swiftvlc_libvlc_media_player_cancel_next_frame_request(void) "
                "{ return false; }\n"
                "void swiftvlc_libvlc_video_set_display_status_callback(void) "
                "{}\n"
                "int swiftvlc_libvlc_video_set_callbacks_atomic(void) "
                "{ return 0; }\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_request_next_frame\n"
                "swiftvlc_libvlc_media_player_cancel_next_frame_request\n"
                "swiftvlc_libvlc_video_set_display_status_callback\n"
                "swiftvlc_libvlc_video_set_callbacks_atomic\n"
            ),
        },
        5: {
            "public_header": (
                "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot(void);\n"
            ),
            "media_player": (
                "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot(void) "
                "{ return false; }\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot\n"
            ),
        },
        6: {
            "public_header": (
                "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void);\n"
            ),
            "media_player": (
                "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void) "
                "{ return 0; }\n"
            ),
            "exports": "swiftvlc_libvlc_video_set_callbacks_atomic_v2\n",
        },
        7: {
            "events_header": (
                "enum { libvlc_MediaPlayerRateChanged, };\n"
                "struct { float new_rate; } media_player_rate_changed;\n"
            ),
            "media_player": (
                "void publish_rate(void) { event.type = "
                "libvlc_MediaPlayerRateChanged, "
                "event.u.media_player_rate_changed.new_rate = 1; }\n"
            ),
        },
        8: {
            "public_header": (
                "#define SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION 1\n"
                "typedef struct swiftvlc_apple_audio_recovery_snapshot_t {\n"
                "    unsigned version;\n"
                "} swiftvlc_apple_audio_recovery_snapshot_t;\n"
                "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(void);\n"
                "void swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(void);\n"
            ),
            "media_player": (
                "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(void) "
                "{ return false; }\n"
                "void swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(void) "
                "{}\n"
            ),
            "exports": (
                "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n"
                "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization\n"
            ),
        },
    }
    for current_version in range(4, highest_version + 1):
        if current_version in omitted_versions:
            continue
        for source_key, fragment in fragments[current_version].items():
            sources[source_key] += fragment
    if leases:
        sources["public_header"] += (
            "typedef uint64_t swiftvlc_apple_audio_session_lease_t;\n"
            "typedef enum swiftvlc_apple_audio_session_lease_result_t {\n"
            "    swiftvlc_apple_audio_session_lease_failed = -1,\n"
            "} swiftvlc_apple_audio_session_lease_result_t;\n"
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void);\n"
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_lease(void);\n"
        )
        sources["media_player"] += (
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void) "
            "{ return 1; }\n"
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_lease(void) "
            "{ return true; }\n"
        )
        sources["exports"] += (
            "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease\n"
            "swiftvlc_libvlc_media_player_release_apple_audio_session_lease\n"
        )
    return sources


class PiPExtensionVersionTests(unittest.TestCase):
    def assert_rejected(self, sources: dict[str, str], **kwargs) -> None:
        with self.assertRaises(version.ExtensionVersionError):
            version.resolve_extension_version(sources, **kwargs)

    def test_every_supported_version_resolves_exactly(self) -> None:
        for expected in range(4, 9):
            with self.subTest(expected=expected):
                sources = synthetic_sources(expected)
                self.assertEqual(
                    version.resolve_extension_version(
                        sources, expected_version=expected
                    ).version,
                    expected,
                )

    def test_v8_lease_extension_is_full_or_absent_without_bumping(self) -> None:
        without = version.resolve_extension_version(synthetic_sources(8))
        self.assertEqual(without.version, 8)
        self.assertEqual(without.same_version_groups, ())

        sources = synthetic_sources(8, leases=True)
        with_leases = version.resolve_extension_version(
            sources,
            expected_version=8,
            required_same_version_groups=("apple-audio-session-leases",),
        )
        self.assertEqual(with_leases.version, 8)
        self.assertEqual(
            with_leases.same_version_groups,
            ("apple-audio-session-leases",),
        )

        sources["exports"] = sources["exports"].replace(
            "swiftvlc_libvlc_media_player_release_apple_audio_session_lease\n",
            "",
        )
        self.assert_rejected(sources)

    def test_manifest_intent_rejects_complete_version_or_lease_removal(self) -> None:
        self.assert_rejected(
            synthetic_sources(7), expected_version=8
        )
        self.assert_rejected(
            synthetic_sources(8),
            expected_version=8,
            required_same_version_groups=("apple-audio-session-leases",),
        )

    def test_partial_duplicate_and_gapped_stages_fail_closed(self) -> None:
        partial = synthetic_sources(8)
        partial["exports"] = partial["exports"].replace(
            "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n",
            "",
        )
        self.assert_rejected(partial)

        duplicate = synthetic_sources(8)
        duplicate["exports"] += (
            "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n"
        )
        self.assert_rejected(duplicate)

        self.assert_rejected(synthetic_sources(8, omitted_versions=(5,)))

    def test_prototype_and_call_cannot_impersonate_any_implementation(self) -> None:
        cases = [
            (group, synthetic_sources(group.version), ())
            for group in version.VERSION_GROUPS
        ]
        cases.extend(
            (
                group,
                synthetic_sources(group.version, leases=True),
                (group.name,),
            )
            for group in version.SAME_VERSION_GROUPS
        )
        for group, baseline, required_groups in cases:
            implementations = [
                current for current in group.markers
                if current.source_key == "media_player"
                and "implementation" in current.label
            ]
            for current in implementations:
                for replacement_kind in ("prototype", "call"):
                    with self.subTest(
                        group=group.name,
                        marker=current.label,
                        decoy=replacement_kind,
                    ):
                        candidate = dict(baseline)
                        candidate["media_player"] = (
                            version._replace_implementation_definition(
                                candidate["media_player"],
                                current,
                                replacement_kind,
                            )
                        )
                        self.assert_rejected(
                            candidate,
                            expected_version=group.version,
                            required_same_version_groups=required_groups,
                        )

    def test_comments_and_strings_cannot_create_a_new_stage(self) -> None:
        comments = synthetic_sources(7)
        v8 = synthetic_sources(8)
        v7 = synthetic_sources(7)
        for source_key in ("public_header", "media_player"):
            added = v8[source_key].replace(v7[source_key], "", 1)
            comments[source_key] += "\n/*\n" + added + "\n*/\n"
        comments["exports"] += (
            "# swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot\n"
            "# swiftvlc_libvlc_media_player_set_pause_without_reset_authorization\n"
        )
        self.assertEqual(
            version.resolve_extension_version(comments).version, 7
        )

        strings = synthetic_sources(7)
        strings["public_header"] += (
            'const char *fake_v8_a = "#define '
            'SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION 1";\n'
            'const char *fake_v8_b = "typedef struct '
            'swiftvlc_apple_audio_recovery_snapshot_t";\n'
            'const char *fake_v8_c = "'
            'swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(";\n'
            'const char *fake_v8_d = "'
            'swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(";\n'
        )
        strings["media_player"] += (
            'const char *fake_v8_e = "'
            'swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(";\n'
            'const char *fake_v8_f = "'
            'swiftvlc_libvlc_media_player_set_pause_without_reset_authorization(";\n'
        )
        self.assertEqual(version.resolve_extension_version(strings).version, 7)

    def test_version_body_must_be_only_one_canonical_literal_return(self) -> None:
        mutations = (
            "{ return 9; }",
            "{ return 4 + 4; }",
            "{ if (1) return 8; return 8; }",
            "{ int ignored = 0; return 8; }",
            "{ return 08; }",
        )
        for body in mutations:
            with self.subTest(body=body):
                sources = version._replace_version_body(
                    synthetic_sources(8), body
                )
                sources["media_player"] += (
                    "\nint unrelated(void) { return 8; }\n"
                )
                self.assert_rejected(sources)

    def test_native_and_vendored_headers_must_classify_identically(self) -> None:
        sources = synthetic_sources(8, leases=True)
        resolution = version.validate_vendored_headers(
            sources,
            sources["public_header"],
            sources["events_header"],
            8,
            ("apple-audio-session-leases",),
        )
        self.assertEqual(resolution.version, 8)
        with self.assertRaises(version.ExtensionVersionError):
            version.validate_vendored_headers(
                sources,
                synthetic_sources(7)["public_header"],
                synthetic_sources(7)["events_header"],
                8,
                ("apple-audio-session-leases",),
            )
        with self.assertRaises(version.ExtensionVersionError):
            version.validate_vendored_headers(
                sources,
                sources["public_header"],
                synthetic_sources(6)["events_header"],
                8,
                ("apple-audio-session-leases",),
            )

    def test_realistic_negative_mutation_matrix_is_complete(self) -> None:
        self.assertEqual(
            version.run_negative_mutations(synthetic_sources(4), 4),
            41,
        )
        caught = version.run_negative_mutations(
            synthetic_sources(8, leases=True),
            8,
            ("apple-audio-session-leases",),
        )
        self.assertEqual(caught, 49)

    def test_invalid_manifest_intent_is_rejected(self) -> None:
        sources = synthetic_sources(8, leases=True)
        for expected in (3, 9, True):
            with self.subTest(expected=expected):
                self.assert_rejected(sources, expected_version=expected)
        self.assert_rejected(
            sources, required_same_version_groups=("unknown",)
        )
        self.assert_rejected(
            sources,
            required_same_version_groups=(
                "apple-audio-session-leases",
                "apple-audio-session-leases",
            ),
        )


class NativeExtensionArchiveContractTests(unittest.TestCase):
    """Exercise the all-slice archive gate with deterministic fake Mach-O tools."""

    def setUp(self) -> None:
        external_root = os.environ.get("SWIFTVLC_VALIDATION_TMP_ROOT")
        temporary_parent = None
        if external_root:
            temporary_parent = Path(external_root)
            temporary_parent.mkdir(parents=True, exist_ok=True)
        self.temporary = tempfile.TemporaryDirectory(
            prefix="swiftvlc-native-archive-test.", dir=temporary_parent
        )
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)
        self.xcframework = self.root / "Fixture.xcframework"
        self.xcframework.mkdir()
        self.libraries: list[dict[str, object]] = []
        self.fake_tools = self.root / "fake-tools"
        self.fake_tools.mkdir()
        self._write_fake_tools()

    def _write_executable(self, name: str, body: str) -> None:
        path = self.fake_tools / name
        path.write_text(textwrap.dedent(body), encoding="utf-8")
        path.chmod(0o755)

    def _write_fake_tools(self) -> None:
        self._write_executable(
            "uname",
            """\
            #!/bin/sh
            if [ "${1:-}" = "-s" ]; then
                echo Darwin
            elif [ "${1:-}" = "-m" ]; then
                echo arm64
            else
                echo Darwin
            fi
            """,
        )
        self._write_executable(
            "xcrun",
            """\
            #!/usr/bin/env python3
            from pathlib import Path
            import sys

            tools = Path(__file__).resolve().parent
            arguments = sys.argv[1:]
            if arguments == ["--find", "lipo"]:
                print(tools / "lipo")
            elif arguments == ["--find", "nm"]:
                print(tools / "nm")
            elif arguments == ["--sdk", "macosx", "--find", "clang"]:
                print(tools / "clang")
            elif arguments == ["--sdk", "macosx", "--show-sdk-path"]:
                print("/")
            else:
                print(f"unexpected fake xcrun arguments: {arguments}", file=sys.stderr)
                raise SystemExit(2)
            """,
        )
        self._write_executable(
            "lipo",
            """\
            #!/usr/bin/env python3
            import json
            from pathlib import Path
            import sys

            if len(sys.argv) != 3 or sys.argv[1] != "-archs":
                raise SystemExit("fake lipo expects -archs <archive>")
            payload = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
            print(" ".join(payload["architectures"]))
            """,
        )
        self._write_executable(
            "nm",
            """\
            #!/usr/bin/env python3
            import json
            from pathlib import Path
            import sys

            arguments = sys.argv[1:]
            if len(arguments) != 4 or arguments[0] != "-arch" or arguments[2] != "-gm":
                raise SystemExit(f"unexpected fake nm arguments: {arguments}")
            architecture = arguments[1]
            payload = json.loads(Path(arguments[3]).read_text(encoding="utf-8"))
            for kind, symbol in payload["symbols"].get(architecture, []):
                if kind == "strong":
                    print(f"0000000000000000 (__TEXT,__text) external _{symbol}")
                elif kind == "weak":
                    print(f"0000000000000000 (__TEXT,__text) weak external _{symbol}")
                elif kind == "data":
                    print(f"0000000000000000 (__DATA,__data) external _{symbol}")
                else:
                    raise SystemExit(f"unknown fake symbol kind: {kind}")
            """,
        )
        self._write_executable(
            "clang",
            """\
            #!/usr/bin/env python3
            from pathlib import Path
            import os
            import sys

            arguments = sys.argv[1:]
            output = Path(arguments[arguments.index("-o") + 1])
            prefix = "-DSWIFTVLC_EXPECTED_PIP_EXTENSIONS_VERSION="
            version = next(value[len(prefix):] for value in arguments if value.startswith(prefix))
            lease_prefix = "-DSWIFTVLC_REQUIRE_APPLE_AUDIO_SESSION_LEASES="
            next(value for value in arguments if value.startswith(lease_prefix))
            output.write_text(f"#!/bin/sh\\nprintf '%s\\\\n' '{version}'\\n", encoding="utf-8")
            os.chmod(output, 0o755)
            """,
        )

    @staticmethod
    def symbols_through(extension_version: int, *, leases: bool) -> list[str]:
        symbols = []
        for introduced, introduced_symbols in VERSIONED_ARCHIVE_SYMBOLS.items():
            if introduced <= extension_version:
                symbols.extend(introduced_symbols)
        if leases:
            symbols.extend(LEASE_ARCHIVE_SYMBOLS)
        return symbols

    def add_slice(
        self,
        identifier: str,
        architectures: tuple[str, ...],
        *,
        platform: str,
        extension_version: int,
        leases: bool = False,
        variant: Optional[str] = None,
    ) -> Path:
        directory = self.xcframework / identifier
        directory.mkdir()
        archive = directory / "libvlc.a"
        symbols = self.symbols_through(extension_version, leases=leases)
        payload = {
            "architectures": list(architectures),
            "symbols": {
                architecture: [["strong", symbol] for symbol in symbols]
                for architecture in architectures
            },
        }
        archive.write_text(json.dumps(payload), encoding="utf-8")
        library: dict[str, object] = {
            "LibraryIdentifier": identifier,
            "LibraryPath": "libvlc.a",
            "BinaryPath": "libvlc.a",
            "SupportedArchitectures": list(architectures),
            "SupportedPlatform": platform,
        }
        if variant is not None:
            library["SupportedPlatformVariant"] = variant
        self.libraries.append(library)
        return archive

    @staticmethod
    def mutate_symbol(
        archive: Path,
        architecture: str,
        symbol: str,
        replacement: list[list[str]],
    ) -> None:
        payload = json.loads(archive.read_text(encoding="utf-8"))
        retained = [
            entry for entry in payload["symbols"][architecture]
            if entry[1] != symbol
        ]
        payload["symbols"][architecture] = retained + replacement
        archive.write_text(json.dumps(payload), encoding="utf-8")

    def run_contract(
        self, expected_version: int, *, require_leases: bool = False
    ) -> subprocess.CompletedProcess[str]:
        (self.xcframework / "Info.plist").write_bytes(
            plistlib.dumps({"AvailableLibraries": self.libraries})
        )
        environment = dict(os.environ)
        environment["PATH"] = str(self.fake_tools) + os.pathsep + environment["PATH"]
        environment["SWIFTVLC_VALIDATION_TMP_ROOT"] = str(self.root / "work")
        command = [
            "/bin/bash",
            str(ARCHIVE_VALIDATOR),
            "--xcframework",
            str(self.xcframework),
            "--expected-version",
            str(expected_version),
        ]
        if require_leases:
            command.append("--require-apple-audio-session-leases")
        return subprocess.run(
            command, capture_output=True, text=True, env=environment, check=False
        )

    def test_device_only_contract_checks_every_slice_and_architecture(self) -> None:
        self.add_slice(
            "ios-arm64", ("arm64",), platform="ios",
            extension_version=8, leases=True,
        )
        self.add_slice(
            "ios-arm64_x86_64-simulator", ("arm64", "x86_64"),
            platform="ios", variant="simulator", extension_version=8,
            leases=True,
        )
        result = self.run_contract(8, require_leases=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("runtime=skipped", result.stdout)
        self.assertIn("slices=2 architectures=3", result.stdout)

    def test_non_host_slice_missing_required_symbol_is_rejected(self) -> None:
        self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=8,
            leases=True,
        )
        simulator = self.add_slice(
            "ios-arm64_x86_64-simulator", ("arm64", "x86_64"),
            platform="ios", variant="simulator", extension_version=8,
            leases=True,
        )
        missing = VERSIONED_ARCHIVE_SYMBOLS[8][0]
        self.mutate_symbol(simulator, "x86_64", missing, [])
        result = self.run_contract(8, require_leases=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ios-arm64_x86_64-simulator/x86_64", result.stderr)
        self.assertIn(missing, result.stderr)

    def test_future_and_partial_same_version_groups_are_rejected(self) -> None:
        archive = self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=7,
        )
        future = VERSIONED_ARCHIVE_SYMBOLS[8][0]
        self.mutate_symbol(archive, "arm64", future, [["strong", future]])
        result = self.run_contract(7)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Future native extension symbol is present", result.stderr)

        self.mutate_symbol(archive, "arm64", future, [])
        for version_8_symbol in VERSIONED_ARCHIVE_SYMBOLS[8]:
            self.mutate_symbol(
                archive, "arm64", version_8_symbol,
                [["strong", version_8_symbol]],
            )
        lease = LEASE_ARCHIVE_SYMBOLS[0]
        self.mutate_symbol(archive, "arm64", lease, [["strong", lease]])
        result = self.run_contract(8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("lease symbol group is partial", result.stderr)

    def test_duplicate_and_weak_only_required_symbols_are_rejected(self) -> None:
        archive = self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=8,
            leases=True,
        )
        required = VERSIONED_ARCHIVE_SYMBOLS[6][0]
        self.mutate_symbol(
            archive, "arm64", required,
            [["strong", required], ["strong", required]],
        )
        result = self.run_contract(8, require_leases=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("strong=2 definitions=2", result.stderr)

        self.mutate_symbol(archive, "arm64", required, [["weak", required]])
        result = self.run_contract(8, require_leases=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("strong=0 definitions=1", result.stderr)

    def test_plist_architecture_and_archive_inventory_drift_is_rejected(self) -> None:
        self.add_slice(
            "ios-arm64", ("arm64",), platform="ios", extension_version=8,
        )
        self.libraries[0]["SupportedArchitectures"] = ["arm64", "x86_64"]
        result = self.run_contract(8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("architecture mismatch", result.stderr)

        self.libraries[0]["SupportedArchitectures"] = ["arm64"]
        extra = self.xcframework / "unexpected" / "libvlc.a"
        extra.parent.mkdir()
        extra.write_text("not declared", encoding="utf-8")
        result = self.run_contract(8)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("archive inventory differs", result.stderr)


if __name__ == "__main__":
    unittest.main()
