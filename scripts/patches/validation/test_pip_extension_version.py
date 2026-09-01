#!/usr/bin/env python3
"""Adversarial unit tests for the shared PiP extension-version resolver."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import re
import unittest
from typing import Dict


HELPER_PATH = Path(__file__).with_name("pip_extension_version.py")
SPEC = importlib.util.spec_from_file_location(
    "swiftvlc_pip_extension_version", HELPER_PATH
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import resolver: {HELPER_PATH}")
VERSION = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERSION)


def make_sources(version: int, leases: bool = False) -> Dict[str, str]:
    """Build one minimal but realistic contiguous v4-v8 source surface."""
    if version not in range(4, 9):
        raise ValueError(f"unsupported fixture version: {version}")
    if leases and version != 8:
        raise ValueError("the lease refinement belongs to version 8")

    public_header = [
        "unsigned swiftvlc_libvlc_pip_extensions_version(void);",
        "typedef enum swiftvlc_next_frame_request_result_t {",
        "    swiftvlc_next_frame_request_accepted = 0,",
        "} swiftvlc_next_frame_request_result_t;",
        "int swiftvlc_libvlc_media_player_request_next_frame(void);",
        "int swiftvlc_libvlc_media_player_cancel_next_frame_request(void);",
        "void swiftvlc_libvlc_video_set_display_status_callback(void);",
        "int swiftvlc_libvlc_video_set_callbacks_atomic(void);",
    ]
    media_player = [
        "unsigned swiftvlc_libvlc_pip_extensions_version(void)",
        "{",
        f"    return {version};",
        "}",
        "int swiftvlc_libvlc_media_player_request_next_frame(void)",
        "{",
        "    return 0;",
        "}",
        "int swiftvlc_libvlc_media_player_cancel_next_frame_request(void)",
        "{",
        "    return 0;",
        "}",
        "void swiftvlc_libvlc_video_set_display_status_callback(void)",
        "{",
        "}",
        "int swiftvlc_libvlc_video_set_callbacks_atomic(void)",
        "{",
        "    return 0;",
        "}",
    ]
    events_header = []
    exports = [
        "swiftvlc_libvlc_pip_extensions_version",
        "swiftvlc_libvlc_media_player_request_next_frame",
        "swiftvlc_libvlc_media_player_cancel_next_frame_request",
        "swiftvlc_libvlc_video_set_display_status_callback",
        "swiftvlc_libvlc_video_set_callbacks_atomic",
    ]

    if version >= 5:
        public_header.extend([
            "typedef struct swiftvlc_sample_buffer_renderer_snapshot_t {",
            "    unsigned abi_version;",
            "} swiftvlc_sample_buffer_renderer_snapshot_t;",
            "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_"
            "snapshot(void);",
        ])
        media_player.extend([
            "bool swiftvlc_libvlc_media_player_get_sample_buffer_renderer_"
            "snapshot(void)",
            "{",
            "    return false;",
            "}",
        ])
        exports.append(
            "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot"
        )

    if version >= 6:
        public_header.extend([
            "#define SWIFTVLC_VMEM_INVALID_PICTURE_PTS_US INT64_MIN",
            "typedef int (*swiftvlc_video_display_status_v2_cb)"
            "(void *, void *, long long);",
            "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void);",
        ])
        media_player.extend([
            "int swiftvlc_libvlc_video_set_callbacks_atomic_v2(void)",
            "{",
            "    return 0;",
            "}",
        ])
        exports.append("swiftvlc_libvlc_video_set_callbacks_atomic_v2")

    if version >= 7:
        events_header.extend([
            "enum libvlc_event_e {",
            "    libvlc_MediaPlayerRateChanged,",
            "};",
            "struct event_payload {",
            "    struct { float new_rate; } media_player_rate_changed;",
            "};",
        ])
        media_player.extend([
            "static void publish_rate_event(void)",
            "{",
            "    event.type = libvlc_MediaPlayerRateChanged,",
            "    event.u.media_player_rate_changed.new_rate = 1.0f;",
            "}",
        ])

    if version >= 8:
        public_header.extend([
            "#define SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION 1",
            "typedef struct swiftvlc_apple_audio_recovery_snapshot_t {",
            "    unsigned version;",
            "} swiftvlc_apple_audio_recovery_snapshot_t;",
            "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_"
            "snapshot(void);",
            "void swiftvlc_libvlc_media_player_set_pause_without_reset_"
            "authorization(void);",
        ])
        media_player.extend([
            "bool swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(void)",
            "{",
            "    return false;",
            "}",
            "void swiftvlc_libvlc_media_player_set_pause_without_reset_"
            "authorization(void)",
            "{",
            "}",
        ])
        exports.extend([
            "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot",
            "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization",
        ])

    if leases:
        public_header.extend([
            "typedef uint64_t swiftvlc_apple_audio_session_lease_t;",
            "typedef enum swiftvlc_apple_audio_session_lease_result_t {",
            "    swiftvlc_apple_audio_session_lease_failed = -1,",
            "} swiftvlc_apple_audio_session_lease_result_t;",
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void);",
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_"
            "lease(void);",
        ])
        media_player.extend([
            "int swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(void)",
            "{",
            "    return 0;",
            "}",
            "bool swiftvlc_libvlc_media_player_release_apple_audio_session_lease(void)",
            "{",
            "    return false;",
            "}",
        ])
        exports.extend([
            "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease",
            "swiftvlc_libvlc_media_player_release_apple_audio_session_lease",
        ])

    return {
        "media_player": "\n".join(media_player) + "\n",
        "public_header": "\n".join(public_header) + "\n",
        "events_header": "\n".join(events_header) + "\n",
        "exports": "\n".join(exports) + "\n",
    }


def marker_matches(sources: Dict[str, str], current: object):
    source_key = current.source_key
    source = sources[source_key]
    searchable = (
        source
        if source_key == "exports"
        else VERSION.strip_c_comments_and_literals(source)
    )
    return tuple(re.finditer(current.pattern, searchable))


def remove_marker(sources: Dict[str, str], current: object) -> Dict[str, str]:
    candidate = dict(sources)
    matches = marker_matches(candidate, current)
    if len(matches) != 1:
        raise AssertionError(
            f"fixture marker count for {current.label} is {len(matches)}, not one"
        )
    found = matches[0]
    source = candidate[current.source_key]
    candidate[current.source_key] = (
        source[: found.start()] + "SWIFTVLC_REMOVED_MARKER" + source[found.end() :]
    )
    return candidate


def remove_group(sources: Dict[str, str], group: object) -> Dict[str, str]:
    candidate = dict(sources)
    for current in group.markers:
        candidate = remove_marker(candidate, current)
    return candidate


def duplicate_marker(
    sources: Dict[str, str], current: object
) -> Dict[str, str]:
    candidate = dict(sources)
    matches = marker_matches(candidate, current)
    if len(matches) != 1:
        raise AssertionError(
            f"fixture marker count for {current.label} is {len(matches)}, not one"
        )
    found = matches[0]
    source = candidate[current.source_key]
    duplicate = source[found.start() : found.end()]
    candidate[current.source_key] = source + "\n" + duplicate + "\n"
    return candidate


def replace_version_body(
    sources: Dict[str, str], replacement: str
) -> Dict[str, str]:
    candidate = dict(sources)
    cleaned = VERSION.strip_c_comments_and_literals(candidate["media_player"])
    start, end, _ = VERSION.version_function_body(cleaned)
    source = candidate["media_player"]
    candidate["media_player"] = source[:start] + replacement + source[end:]
    return candidate


class PiPExtensionVersionTests(unittest.TestCase):
    def assert_rejected(self, sources: Dict[str, str], **kwargs: object) -> None:
        with self.assertRaises(VERSION.ExtensionVersionError):
            VERSION.resolve_extension_version(sources, **kwargs)

    def test_every_historical_version_boundary_resolves_exactly(self) -> None:
        for expected in range(4, 9):
            with self.subTest(version=expected):
                resolution = VERSION.resolve_extension_version(
                    make_sources(expected), expected_version=expected
                )
                self.assertEqual(resolution.version, expected)
                self.assertEqual(resolution.same_version_groups, ())

    def test_version_8_accepts_0032_base_and_0033_final_profiles(self) -> None:
        base = VERSION.resolve_extension_version(
            make_sources(8), expected_version=8
        )
        final = VERSION.resolve_extension_version(
            make_sources(8, leases=True), expected_version=8
        )
        self.assertEqual(base.same_version_groups, ())
        self.assertEqual(
            final.same_version_groups, ("apple-audio-session-leases",)
        )

    def test_manifest_intent_can_require_the_version_8_lease_refinement(self) -> None:
        required = ("apple-audio-session-leases",)
        with self.assertRaises(VERSION.ExtensionVersionError):
            VERSION.resolve_extension_version(
                make_sources(8),
                expected_version=8,
                required_same_version_groups=required,
            )
        resolution = VERSION.resolve_extension_version(
            make_sources(8, leases=True),
            expected_version=8,
            required_same_version_groups=required,
        )
        self.assertEqual(resolution.same_version_groups, required)

    def test_comment_and_string_markers_do_not_advance_version(self) -> None:
        baseline = make_sources(4)
        complete = make_sources(8, leases=True)
        marker_index = 0
        for group in VERSION.VERSION_GROUPS[1:] + VERSION.SAME_VERSION_GROUPS:
            for current in group.markers:
                matches = marker_matches(complete, current)
                self.assertEqual(len(matches), 1, current.label)
                found = matches[0]
                token = complete[current.source_key][found.start() : found.end()]
                if current.source_key == "exports":
                    baseline["exports"] += "# " + token + "\n"
                elif marker_index % 2 == 0:
                    baseline[current.source_key] += "/* " + token + " */\n"
                else:
                    escaped = token.replace("\\", "\\\\").replace('"', '\\"')
                    baseline[current.source_key] += '"' + escaped + '";\n'
                marker_index += 1
        resolution = VERSION.resolve_extension_version(
            baseline, expected_version=4
        )
        self.assertEqual(resolution.version, 4)

    def test_every_stage_marker_is_required_exactly_once(self) -> None:
        for group in (VERSION.COMMON_GROUP,) + VERSION.VERSION_GROUPS:
            fixture_version = max(4, group.version)
            baseline = make_sources(fixture_version)
            for current in group.markers:
                with self.subTest(
                    group=group.name, marker=current.label, mutation="missing"
                ):
                    self.assert_rejected(
                        remove_marker(baseline, current),
                        expected_version=fixture_version,
                    )
                with self.subTest(
                    group=group.name, marker=current.label, mutation="duplicate"
                ):
                    self.assert_rejected(
                        duplicate_marker(baseline, current),
                        expected_version=fixture_version,
                    )

    def test_every_lease_marker_is_required_exactly_once_when_present(self) -> None:
        baseline = make_sources(8, leases=True)
        group = VERSION.SAME_VERSION_GROUPS[0]
        for current in group.markers:
            with self.subTest(marker=current.label, mutation="missing"):
                self.assert_rejected(
                    remove_marker(baseline, current), expected_version=8
                )
            with self.subTest(marker=current.label, mutation="duplicate"):
                self.assert_rejected(
                    duplicate_marker(baseline, current), expected_version=8
                )

    def test_prototype_and_call_cannot_impersonate_any_implementation(self) -> None:
        cases = [
            (group, make_sources(group.version), ())
            for group in VERSION.VERSION_GROUPS
        ]
        cases.extend(
            (
                group,
                make_sources(group.version, leases=True),
                (group.name,),
            )
            for group in VERSION.SAME_VERSION_GROUPS
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
                            VERSION._replace_implementation_definition(
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

    def test_all_predecessor_gaps_are_rejected(self) -> None:
        baseline = make_sources(8, leases=True)
        for predecessor in VERSION.VERSION_GROUPS[:-1]:
            with self.subTest(missing=predecessor.name):
                self.assert_rejected(
                    remove_group(baseline, predecessor), expected_version=8
                )

    def test_version_body_must_be_only_the_exact_literal_return(self) -> None:
        baseline = make_sources(8, leases=True)
        invalid_bodies = {
            "stale-seven": "{ return 7; }",
            "unknown-nine": "{ return 9; }",
            "computed": "{ return 7 + 1; }",
            "multiple": "{ if (ready) return 8; return 8; }",
            "side-effect": "{ observe_version(); return 8; }",
        }
        for name, body in invalid_bodies.items():
            with self.subTest(mutation=name):
                self.assert_rejected(
                    replace_version_body(baseline, body), expected_version=8
                )

    def test_matching_return_elsewhere_does_not_rescue_stale_version_body(self) -> None:
        candidate = replace_version_body(
            make_sources(8, leases=True), "{ return 7; }"
        )
        candidate["media_player"] += (
            "unsigned unrelated_version(void) { return 8; }\n"
        )
        self.assert_rejected(candidate, expected_version=8)

    def test_implementation_and_export_drift_is_rejected(self) -> None:
        cases = (
            (5, False, VERSION.VERSION_GROUPS[1].markers[1]),
            (6, False, VERSION.VERSION_GROUPS[2].markers[2]),
            (8, False, VERSION.VERSION_GROUPS[4].markers[5]),
            (8, True, VERSION.SAME_VERSION_GROUPS[0].markers[7]),
        )
        for fixture_version, leases, current in cases:
            with self.subTest(version=fixture_version, marker=current.label):
                self.assert_rejected(
                    remove_marker(
                        make_sources(fixture_version, leases=leases), current
                    ),
                    expected_version=fixture_version,
                )

    def test_expected_version_prevents_complete_stage_downgrade(self) -> None:
        predecessor = make_sources(7)
        self.assertEqual(
            VERSION.resolve_extension_version(predecessor).version, 7
        )
        self.assert_rejected(predecessor, expected_version=8)

    def test_native_and_vendored_public_surfaces_must_match(self) -> None:
        final = make_sources(8, leases=True)
        same = VERSION.validate_vendored_headers(
            final,
            final["public_header"],
            final["events_header"],
            expected_version=8,
        )
        self.assertEqual(same.version, 8)
        self.assertEqual(
            same.same_version_groups, ("apple-audio-session-leases",)
        )

        mismatches = (
            (
                final,
                make_sources(7)["public_header"],
                make_sources(7)["events_header"],
                8,
                "native-v8-vendored-v7",
            ),
            (
                make_sources(7),
                final["public_header"],
                final["events_header"],
                7,
                "native-v7-vendored-v8",
            ),
            (
                final,
                make_sources(8)["public_header"],
                make_sources(8)["events_header"],
                8,
                "native-final-vendored-pre-lease",
            ),
            (
                make_sources(8),
                final["public_header"],
                final["events_header"],
                8,
                "native-pre-lease-vendored-final",
            ),
        )
        for (
            native,
            vendored_public,
            vendored_events,
            expected_version,
            name,
        ) in mismatches:
            with self.subTest(mismatch=name):
                with self.assertRaises(VERSION.ExtensionVersionError):
                    VERSION.validate_vendored_headers(
                        native,
                        vendored_public,
                        vendored_events,
                        expected_version=expected_version,
                    )


if __name__ == "__main__":
    unittest.main()
