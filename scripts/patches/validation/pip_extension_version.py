#!/usr/bin/env python3
"""Fail-closed resolver for SwiftVLC's additive libVLC extension ABI.

The extension function is shared by several otherwise independent patches.
This module is the single composition proof for versions 4 through 8: every
stage must be complete, unique, and contiguous, and the implementation must be
exactly one literal return of the resolved version.  Release callers should
also provide ``expected_version`` from the ordered patch manifest so removing
an entire final stage cannot silently downgrade the intended artifact.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
import sys
from typing import Dict, Mapping, NamedTuple, Optional, Sequence, Tuple


class ExtensionVersionError(AssertionError):
    """The source tree does not encode one supported, complete ABI version."""


class Marker(NamedTuple):
    source_key: str
    label: str
    pattern: str


class MarkerGroup(NamedTuple):
    name: str
    version: int
    markers: Tuple[Marker, ...]


class Resolution(NamedTuple):
    version: int
    same_version_groups: Tuple[str, ...]


def marker(source_key: str, label: str, symbol: str) -> Marker:
    return Marker(
        source_key,
        label,
        r"\b" + re.escape(symbol) + r"\s*\(",
    )


def implementation_marker(label: str, symbol: str) -> Marker:
    """Match one ordinary C function definition, never a prototype or call.

    SwiftVLC's extension entry points use typedef names for callback parameters,
    so their declarators contain no nested parentheses. Requiring the opening
    function-body brace immediately after that declarator keeps a declaration,
    direct call, and an ``if (function(...)) {`` decoy from satisfying an
    implementation marker.
    """
    return Marker(
        "media_player",
        label,
        r"\b" + re.escape(symbol) + r"\s*\([^(){};]*\)\s*\{",
    )


COMMON_GROUP = MarkerGroup(
    "shared-version-function",
    4,
    (
        marker("public_header", "public version declaration",
               "swiftvlc_libvlc_pip_extensions_version"),
        Marker("exports", "version export",
               r"(?m)^swiftvlc_libvlc_pip_extensions_version$"),
    ),
)


VERSION_GROUPS = (
    MarkerGroup(
        "strict-frame-step",
        4,
        (
            Marker("public_header", "strict result typedef",
                   r"\btypedef\s+enum\s+"
                   r"swiftvlc_next_frame_request_result_t\b"),
            marker("public_header", "strict request declaration",
                   "swiftvlc_libvlc_media_player_request_next_frame"),
            implementation_marker(
                "strict request implementation",
                "swiftvlc_libvlc_media_player_request_next_frame"),
            Marker("exports", "strict request export",
                   r"(?m)^swiftvlc_libvlc_media_player_request_next_frame$"),
            marker("public_header", "strict cancel declaration",
                   "swiftvlc_libvlc_media_player_cancel_next_frame_request"),
            implementation_marker(
                "strict cancel implementation",
                "swiftvlc_libvlc_media_player_cancel_next_frame_request"),
            Marker("exports", "strict cancel export",
                   r"(?m)^swiftvlc_libvlc_media_player_cancel_next_frame_request$"),
            marker("public_header", "display-status setter declaration",
                   "swiftvlc_libvlc_video_set_display_status_callback"),
            implementation_marker(
                "display-status setter implementation",
                "swiftvlc_libvlc_video_set_display_status_callback"),
            Marker("exports", "display-status setter export",
                   r"(?m)^swiftvlc_libvlc_video_set_display_status_callback$"),
            marker("public_header", "atomic setter declaration",
                   "swiftvlc_libvlc_video_set_callbacks_atomic"),
            implementation_marker(
                "atomic setter implementation",
                "swiftvlc_libvlc_video_set_callbacks_atomic"),
            Marker("exports", "atomic setter export",
                   r"(?m)^swiftvlc_libvlc_video_set_callbacks_atomic$"),
        ),
    ),
    MarkerGroup(
        "sample-buffer-renderer-snapshot",
        5,
        (
            marker("public_header", "renderer snapshot declaration",
                   "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot"),
            implementation_marker(
                "renderer snapshot implementation",
                "swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot"),
            Marker("exports", "renderer snapshot export",
                   r"(?m)^swiftvlc_libvlc_media_player_get_sample_buffer_renderer_snapshot$"),
        ),
    ),
    MarkerGroup(
        "timestamp-bearing-vmem",
        6,
        (
            marker("public_header", "vmem v2 declaration",
                   "swiftvlc_libvlc_video_set_callbacks_atomic_v2"),
            implementation_marker(
                "vmem v2 implementation",
                "swiftvlc_libvlc_video_set_callbacks_atomic_v2"),
            Marker("exports", "vmem v2 export",
                   r"(?m)^swiftvlc_libvlc_video_set_callbacks_atomic_v2$"),
        ),
    ),
    MarkerGroup(
        "effective-rate-event",
        7,
        (
            Marker("events_header", "rate event enumerator",
                   r"\blibvlc_MediaPlayerRateChanged\s*,"),
            Marker("events_header", "rate event payload",
                   r"\bmedia_player_rate_changed\s*;"),
            Marker("media_player", "rate event publication",
                   r"\.type\s*=\s*libvlc_MediaPlayerRateChanged\s*,"),
            Marker("media_player", "rate payload publication",
                   r"\.u\.media_player_rate_changed\.new_rate\s*="),
        ),
    ),
    MarkerGroup(
        "apple-audio-recovery",
        8,
        (
            Marker("public_header", "recovery snapshot version",
                   r"(?m)^#define\s+"
                   r"SWIFTVLC_APPLE_AUDIO_RECOVERY_SNAPSHOT_VERSION\s+1$"),
            Marker("public_header", "recovery snapshot typedef",
                   r"\btypedef\s+struct\s+"
                   r"swiftvlc_apple_audio_recovery_snapshot_t\b"),
            marker("public_header", "recovery snapshot declaration",
                   "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot"),
            marker("public_header", "non-authorizing pause declaration",
                   "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization"),
            implementation_marker(
                "recovery snapshot implementation",
                "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot"),
            implementation_marker(
                "non-authorizing pause implementation",
                "swiftvlc_libvlc_media_player_set_pause_without_reset_authorization"),
            Marker("exports", "recovery snapshot export",
                   r"(?m)^swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot$"),
            Marker("exports", "non-authorizing pause export",
                   r"(?m)^swiftvlc_libvlc_media_player_set_pause_without_reset_authorization$"),
        ),
    ),
)


# Patch 0033 extends the already-version-8 audio policy.  It is deliberately
# not a new version stage, but if any lease surface appears, every declaration,
# implementation, and export must be present exactly once.
SAME_VERSION_GROUPS = (
    MarkerGroup(
        "apple-audio-session-leases",
        8,
        (
            Marker("public_header", "lease token typedef",
                   r"\btypedef\s+uint64_t\s+"
                   r"swiftvlc_apple_audio_session_lease_t\s*;"),
            Marker("public_header", "lease result typedef",
                   r"\btypedef\s+enum\s+"
                   r"swiftvlc_apple_audio_session_lease_result_t\b"),
            marker("public_header", "lease acquire declaration",
                   "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease"),
            marker("public_header", "lease release declaration",
                   "swiftvlc_libvlc_media_player_release_apple_audio_session_lease"),
            implementation_marker(
                "lease acquire implementation",
                "swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease"),
            implementation_marker(
                "lease release implementation",
                "swiftvlc_libvlc_media_player_release_apple_audio_session_lease"),
            Marker("exports", "lease acquire export",
                   r"(?m)^swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease$"),
            Marker("exports", "lease release export",
                   r"(?m)^swiftvlc_libvlc_media_player_release_apple_audio_session_lease$"),
        ),
    ),
)


def strip_c_comments_and_literals(source: str) -> str:
    """Blank comments and quoted literals while preserving offsets/newlines."""
    output = list(source)
    state = "code"
    index = 0
    while index < len(source):
        current = source[index]
        following = source[index + 1] if index + 1 < len(source) else ""
        if state == "code":
            if current == "/" and following == "/":
                output[index] = output[index + 1] = " "
                index += 2
                state = "line-comment"
                continue
            if current == "/" and following == "*":
                output[index] = output[index + 1] = " "
                index += 2
                state = "block-comment"
                continue
            if current == '"':
                output[index] = " "
                index += 1
                state = "string"
                continue
            if current == "'":
                output[index] = " "
                index += 1
                state = "character"
                continue
            index += 1
            continue
        if state == "line-comment":
            if current == "\n":
                state = "code"
            else:
                output[index] = " "
            index += 1
            continue
        if state == "block-comment":
            if current == "*" and following == "/":
                output[index] = output[index + 1] = " "
                index += 2
                state = "code"
                continue
            if current != "\n":
                output[index] = " "
            index += 1
            continue
        if state in ("string", "character"):
            quote = '"' if state == "string" else "'"
            if current == "\\":
                output[index] = " "
                if index + 1 < len(source):
                    if source[index + 1] != "\n":
                        output[index + 1] = " "
                    index += 2
                else:
                    index += 1
                continue
            if current == quote:
                output[index] = " "
                index += 1
                state = "code"
                continue
            if current != "\n":
                output[index] = " "
            index += 1
            continue
    if state in ("block-comment", "string", "character"):
        raise ExtensionVersionError(
            f"unterminated C lexical construct while stripping {state}")
    return "".join(output)


def normalized_sources(sources: Mapping[str, str]) -> Dict[str, str]:
    required = {"media_player", "public_header", "events_header", "exports"}
    missing = required.difference(sources)
    extra = set(sources).difference(required)
    if missing or extra:
        raise ExtensionVersionError(
            f"version source keys differ: missing={sorted(missing)} "
            f"extra={sorted(extra)}")
    return {
        "media_player": strip_c_comments_and_literals(sources["media_player"]),
        "public_header": strip_c_comments_and_literals(sources["public_header"]),
        "events_header": strip_c_comments_and_literals(sources["events_header"]),
        "exports": sources["exports"],
    }


def marker_matches(source: str, current: Marker) -> Sequence[re.Match[str]]:
    return tuple(re.finditer(current.pattern, source))


def classify_group(group: MarkerGroup,
                   sources: Mapping[str, str]) -> str:
    counts = tuple(
        len(marker_matches(sources[current.source_key], current))
        for current in group.markers
    )
    if all(count == 0 for count in counts):
        return "absent"
    if all(count == 1 for count in counts):
        return "full"
    details = ", ".join(
        f"{current.label}={count}"
        for current, count in zip(group.markers, counts)
    )
    raise ExtensionVersionError(
        f"{group.name} v{group.version} marker group is partial or duplicated: "
        f"{details}")


def version_function_body(media_player: str) -> Tuple[int, int, str]:
    signature = re.compile(
        r"\bunsigned\s+swiftvlc_libvlc_pip_extensions_version\s*"
        r"\(\s*void\s*\)\s*\{")
    matches = tuple(signature.finditer(media_player))
    if len(matches) != 1:
        raise ExtensionVersionError(
            "shared extension version definition count is not one: "
            f"{len(matches)}")
    opening = media_player.find("{", matches[0].start(), matches[0].end())
    depth = 0
    for index in range(opening, len(media_player)):
        current = media_player[index]
        if current == "{":
            depth += 1
        elif current == "}":
            depth -= 1
            if depth == 0:
                return opening, index + 1, media_player[opening:index + 1]
    raise ExtensionVersionError("unterminated shared extension version body")


def resolve_extension_version(
        sources: Mapping[str, str],
        expected_version: Optional[int] = None,
        required_same_version_groups: Sequence[str] = ()) -> Resolution:
    if (expected_version is not None
            and (isinstance(expected_version, bool)
                 or expected_version not in range(4, 9))):
        raise ExtensionVersionError(
            f"expected version must be an integer from 4 through 8: "
            f"{expected_version!r}")
    if isinstance(required_same_version_groups, (str, bytes)):
        raise ExtensionVersionError(
            "required same-version groups must be a sequence of names")
    required_groups = tuple(required_same_version_groups)
    known_groups = {group.name for group in SAME_VERSION_GROUPS}
    if len(set(required_groups)) != len(required_groups):
        raise ExtensionVersionError(
            f"required same-version groups contain duplicates: "
            f"{required_groups!r}")
    unknown_groups = set(required_groups).difference(known_groups)
    if unknown_groups:
        raise ExtensionVersionError(
            f"unknown required same-version groups: {sorted(unknown_groups)}")

    cleaned = normalized_sources(sources)
    if classify_group(COMMON_GROUP, cleaned) != "full":
        raise ExtensionVersionError("shared extension declaration/export missing")

    resolved = 3
    missing_predecessor = False
    for group in VERSION_GROUPS:
        state = classify_group(group, cleaned)
        if state == "absent":
            missing_predecessor = True
            continue
        if missing_predecessor:
            raise ExtensionVersionError(
                f"{group.name} v{group.version} exists after a missing "
                "predecessor stage")
        resolved = group.version
    if resolved < 4:
        raise ExtensionVersionError("strict-frame-step v4 base marker group missing")

    complete_same_version = []
    for group in SAME_VERSION_GROUPS:
        state = classify_group(group, cleaned)
        if state == "full":
            if resolved < group.version:
                raise ExtensionVersionError(
                    f"{group.name} requires extension version {group.version}")
            complete_same_version.append(group.name)
    missing_groups = set(required_groups).difference(complete_same_version)
    if missing_groups:
        raise ExtensionVersionError(
            f"required same-version groups are absent: "
            f"{sorted(missing_groups)}")

    _, _, body = version_function_body(cleaned["media_player"])
    exact_return = re.fullmatch(
        r"\{\s*return\s+([0-9]+)\s*;\s*\}", body)
    if exact_return is None:
        raise ExtensionVersionError(
            "shared extension version body must contain only one literal return")
    returned_literal = exact_return.group(1)
    if returned_literal != str(resolved):
        raise ExtensionVersionError(
            f"shared extension version returns {returned_literal}, but complete "
            f"markers resolve to {resolved}")
    if expected_version is not None and resolved != expected_version:
        raise ExtensionVersionError(
            f"resolved extension version {resolved} does not match caller "
            f"intent {expected_version}")
    return Resolution(resolved, tuple(complete_same_version))


def _replace_match(source: str, current: Marker, replacement: str) -> str:
    cleaned = (source if current.source_key == "exports"
               else strip_c_comments_and_literals(source))
    matches = marker_matches(cleaned, current)
    if len(matches) != 1:
        raise ExtensionVersionError(
            f"cannot mutate {current.label}: count={len(matches)}")
    found = matches[0]
    return source[:found.start()] + replacement + source[found.end():]


def _replace_implementation_definition(
        source: str, current: Marker, replacement_kind: str) -> str:
    """Replace one implementation with a prototype-only or call-only decoy."""
    if current.source_key != "media_player" or "implementation" not in current.label:
        raise ExtensionVersionError(
            f"cannot replace non-implementation marker: {current.label}")
    cleaned = strip_c_comments_and_literals(source)
    matches = marker_matches(cleaned, current)
    if len(matches) != 1:
        raise ExtensionVersionError(
            f"cannot replace {current.label}: count={len(matches)}")
    found = matches[0]
    opening = cleaned.find("{", found.start(), found.end())
    if opening < 0:
        raise ExtensionVersionError(
            f"implementation marker has no opening brace: {current.label}")

    depth = 0
    closing = -1
    for index in range(opening, len(cleaned)):
        token = cleaned[index]
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 0:
                closing = index + 1
                break
    if closing < 0:
        raise ExtensionVersionError(
            f"implementation body is unterminated: {current.label}")

    declarator = source[found.start():opening].rstrip()
    function_name_match = re.match(r"[A-Za-z_][A-Za-z0-9_]*", declarator)
    if function_name_match is None:
        raise ExtensionVersionError(
            f"cannot identify implementation symbol: {current.label}")
    function_name = function_name_match.group(0)
    if replacement_kind == "prototype":
        replacement = declarator + ";"
    elif replacement_kind == "call":
        replacement = (
            "swiftvlc_removed_implementation(void)\n"
            "{\n"
            f"    {function_name}();\n"
            "}"
        )
    else:
        raise ExtensionVersionError(
            f"unknown implementation replacement: {replacement_kind}")
    return source[:found.start()] + replacement + source[closing:]


def _replace_version_body(sources: Mapping[str, str], body: str) -> Dict[str, str]:
    candidate = dict(sources)
    cleaned = strip_c_comments_and_literals(sources["media_player"])
    start, end, _ = version_function_body(cleaned)
    candidate["media_player"] = (
        sources["media_player"][:start] + body + sources["media_player"][end:]
    )
    return candidate


def run_negative_mutations(
        sources: Mapping[str, str], expected_version: int,
        required_same_version_groups: Sequence[str] = ()) -> int:
    """Prove realistic version/marker corruptions fail the shared gate."""
    baseline = resolve_extension_version(
        sources, expected_version, required_same_version_groups)
    mutation_required_groups = tuple(sorted(set(
        required_same_version_groups
    ).union(baseline.same_version_groups)))
    caught = 0

    def rejects(name: str, candidate: Mapping[str, str],
                intended: Optional[int] = expected_version) -> None:
        nonlocal caught
        try:
            resolve_extension_version(
                candidate, intended, mutation_required_groups)
        except ExtensionVersionError:
            caught += 1
            return
        raise ExtensionVersionError(
            f"negative mutation escaped extension-version gate: {name}")

    prior = baseline.version - 1
    rejects("stale-return", _replace_version_body(
        sources, f"{{ return {prior}; }}"))
    unrelated = _replace_version_body(sources, f"{{ return {prior}; }}")
    unrelated["media_player"] += (
        f"\nint unrelated_version_fixture(void) {{ return {baseline.version}; }}\n"
    )
    rejects("unrelated-return", unrelated)
    rejects("computed-return", _replace_version_body(
        sources, f"{{ return {baseline.version - 1} + 1; }}"))
    rejects("multiple-return", _replace_version_body(
        sources, f"{{ if (1) return {baseline.version}; "
                 f"return {baseline.version}; }}"))
    rejects("unknown-future-return", _replace_version_body(
        sources, "{ return 9; }"))
    rejects("statement-before-return", _replace_version_body(
        sources, f"{{ int ignored = 0; return {baseline.version}; }}"))

    highest = VERSION_GROUPS[baseline.version - 4]
    for current in highest.markers:
        partial = dict(sources)
        partial[current.source_key] = _replace_match(
            partial[current.source_key], current, "SWIFTVLC_REMOVED_MARKER")
        rejects(f"partial-{highest.name}-{current.label}", partial)

        duplicate = dict(sources)
        cleaned = (duplicate[current.source_key]
                   if current.source_key == "exports"
                   else strip_c_comments_and_literals(
                       duplicate[current.source_key]))
        found = marker_matches(cleaned, current)[0]
        duplicate[current.source_key] += (
            "\n" + duplicate[current.source_key][found.start():found.end()] + "\n"
        )
        rejects(f"duplicate-{highest.name}-{current.label}", duplicate)

        if (current.source_key == "media_player"
                and "implementation" in current.label):
            for replacement_kind in ("prototype", "call"):
                decoy = dict(sources)
                decoy[current.source_key] = _replace_implementation_definition(
                    decoy[current.source_key], current, replacement_kind)
                rejects(
                    f"{replacement_kind}-only-{highest.name}-{current.label}",
                    decoy)

    for group in SAME_VERSION_GROUPS:
        if group.name not in baseline.same_version_groups:
            continue
        for current in group.markers:
            partial = dict(sources)
            partial[current.source_key] = _replace_match(
                partial[current.source_key], current,
                "SWIFTVLC_REMOVED_MARKER")
            rejects(f"partial-{group.name}-{current.label}", partial)

            duplicate = dict(sources)
            cleaned = (duplicate[current.source_key]
                       if current.source_key == "exports"
                       else strip_c_comments_and_literals(
                           duplicate[current.source_key]))
            found = marker_matches(cleaned, current)[0]
            duplicate[current.source_key] += (
                "\n" + duplicate[current.source_key][
                    found.start():found.end()
                ] + "\n"
            )
            rejects(f"duplicate-{group.name}-{current.label}", duplicate)

            if (current.source_key == "media_player"
                    and "implementation" in current.label):
                for replacement_kind in ("prototype", "call"):
                    decoy = dict(sources)
                    decoy[current.source_key] = _replace_implementation_definition(
                        decoy[current.source_key], current, replacement_kind)
                    rejects(
                        f"{replacement_kind}-only-{group.name}-{current.label}",
                        decoy)

        removed = dict(sources)
        for current in group.markers:
            removed[current.source_key] = _replace_match(
                removed[current.source_key], current,
                "SWIFTVLC_REMOVED_MARKER")
        rejects(f"removed-{group.name}", removed)

    # Removing an entire final stage and changing the return is structurally a
    # valid historical predecessor. Caller intent is what makes that a release
    # failure, so exercise the explicit expected-version boundary directly.
    downgraded = dict(sources)
    removable_groups = [highest]
    removable_groups.extend(
        group for group in SAME_VERSION_GROUPS
        if group.version == baseline.version
        and group.name in baseline.same_version_groups
    )
    for group in removable_groups:
        for current in group.markers:
            downgraded[current.source_key] = _replace_match(
                downgraded[current.source_key], current,
                "SWIFTVLC_REMOVED_MARKER")
    downgraded = _replace_version_body(
        downgraded, f"{{ return {baseline.version - 1}; }}")
    rejects("complete-stage-downgrade", downgraded)

    if baseline.version >= 6:
        gap = dict(sources)
        predecessor = VERSION_GROUPS[1]  # v5
        for current in predecessor.markers:
            gap[current.source_key] = _replace_match(
                gap[current.source_key], current, "SWIFTVLC_REMOVED_MARKER")
        rejects("missing-v5-predecessor", gap)
    return caught


def read_source_root(root: Path) -> Dict[str, str]:
    source_paths = {
        "media_player": root / "lib/media_player.c",
        "public_header": root / "include/vlc/libvlc_media_player.h",
        "events_header": root / "include/vlc/libvlc_events.h",
        "exports": root / "lib/libvlc.sym",
    }
    missing = [str(current) for current in source_paths.values()
               if not current.is_file()]
    if missing:
        raise ExtensionVersionError(
            f"missing extension-version source inputs: {missing}")
    return {
        key: current.read_text(encoding="utf-8")
        for key, current in source_paths.items()
    }


def validate_vendored_headers(
        sources: Mapping[str, str], vendored_public_header: str,
        vendored_events_header: str,
        expected_version: int,
        required_same_version_groups: Sequence[str] = ()) -> Resolution:
    native = resolve_extension_version(
        sources, expected_version, required_same_version_groups)
    vendored_sources = dict(sources)
    vendored_sources["public_header"] = vendored_public_header
    vendored_sources["events_header"] = vendored_events_header
    vendored = resolve_extension_version(
        vendored_sources, expected_version, required_same_version_groups)
    if vendored != native:
        raise ExtensionVersionError(
            "native/vendored extension-version surface classification differs: "
            f"native={native} vendored={vendored}")
    return native


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--expected-version", type=int)
    parser.add_argument(
        "--require-same-version-group", action="append", default=[])
    parser.add_argument("--vendored-public-header", type=Path)
    parser.add_argument("--vendored-events-header", type=Path)
    parser.add_argument("--run-mutations", action="store_true")
    arguments = parser.parse_args(argv[1:])
    try:
        sources = read_source_root(arguments.source_root.resolve())
        resolution = resolve_extension_version(
            sources, arguments.expected_version,
            arguments.require_same_version_group)
        vendored_arguments = (
            arguments.vendored_public_header,
            arguments.vendored_events_header,
        )
        if any(current is not None for current in vendored_arguments):
            if any(current is None for current in vendored_arguments):
                raise ExtensionVersionError(
                    "vendored public and events headers must be supplied together")
            assert arguments.vendored_public_header is not None
            assert arguments.vendored_events_header is not None
            vendored_public_path = arguments.vendored_public_header.resolve()
            vendored_events_path = arguments.vendored_events_header.resolve()
            missing_vendored = [
                str(current)
                for current in (vendored_public_path, vendored_events_path)
                if not current.is_file()
            ]
            if missing_vendored:
                raise ExtensionVersionError(
                    f"vendored extension headers not found: {missing_vendored}")
            resolution = validate_vendored_headers(
                sources,
                vendored_public_path.read_text(encoding="utf-8"),
                vendored_events_path.read_text(encoding="utf-8"),
                resolution.version, arguments.require_same_version_group)
        if arguments.run_mutations:
            run_negative_mutations(
                sources, resolution.version,
                arguments.require_same_version_group)
    except (OSError, ExtensionVersionError) as error:
        print(f"FAIL shared PiP extension-version proof: {error}",
              file=sys.stderr)
        return 1
    print(resolution.version)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
