#!/usr/bin/env python3
"""Fail-closed source and mutation proof for VLC patch 0035.

Patch 0035 deliberately remains the exact three-file upstream delta.  This
checker binds those tiny edits to the production GetMedia/UpdateOutput bodies
and rejects the original bugs, misleading dead-code tokens, partial backports,
and any extra patch payload.
"""

from __future__ import annotations

import argparse
from collections import Counter
from pathlib import Path
import re
from typing import Mapping


PATHS = {
    "communication": "modules/stream_out/chromecast/chromecast_communication.cpp",
    "cast": "modules/stream_out/chromecast/cast.cpp",
    "dlna": "modules/stream_out/dlna/dlna.cpp",
}

PATCH_PATHS = (
    PATHS["cast"],
    PATHS["communication"],
    PATHS["dlna"],
)

METADATA_FIELDS = (
    ("album", "album", "vlc_meta_Album"),
    ("albumartist", "albumArtist", "vlc_meta_AlbumArtist"),
    ("tracknumber", "trackNumber", "vlc_meta_TrackNumber"),
    ("discnumber", "discNumber", "vlc_meta_DiscNumber"),
)


def without_comments(source: str) -> str:
    result: list[str] = []
    index = 0
    quote: str | None = None
    while index < len(source):
        character = source[index]
        if quote is not None:
            result.append(character)
            if character == "\\" and index + 1 < len(source):
                index += 1
                result.append(source[index])
            elif character == quote:
                quote = None
            index += 1
            continue
        if character in ('"', "'"):
            quote = character
            result.append(character)
            index += 1
            continue
        if source.startswith("//", index):
            newline = source.find("\n", index + 2)
            if newline < 0:
                break
            result.append("\n")
            index = newline + 1
            continue
        if source.startswith("/*", index):
            closing = source.find("*/", index + 2)
            if closing < 0:
                raise AssertionError("unterminated source comment")
            result.extend("\n" for value in source[index:closing] if value == "\n")
            index = closing + 2
            continue
        result.append(character)
        index += 1
    return "".join(result)


def compact(source: str) -> str:
    return re.sub(r"\s+", "", without_comments(source))


def braced_body(source: str, opening: int, description: str) -> str:
    depth = 0
    quote: str | None = None
    index = opening
    while index < len(source):
        character = source[index]
        if quote is not None:
            if character == "\\":
                index += 2
                continue
            if character == quote:
                quote = None
        elif character in ('"', "'"):
            quote = character
        elif source.startswith("//", index):
            newline = source.find("\n", index + 2)
            index = len(source) if newline < 0 else newline
            continue
        elif source.startswith("/*", index):
            closing = source.find("*/", index + 2)
            if closing < 0:
                raise AssertionError(f"unterminated comment in {description}")
            index = closing + 2
            continue
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[opening : index + 1]
        index += 1
    raise AssertionError(f"unterminated body for {description}")


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"missing production function {signature}")
    if source.find(signature, start + len(signature)) >= 0:
        raise AssertionError(f"ambiguous production function {signature}")
    opening = source.find("{", start + len(signature))
    if opening < 0:
        raise AssertionError(f"missing body for {signature}")
    return braced_body(source, opening, signature)


def conditional_body(source: str, pattern: str, description: str) -> str:
    matches = list(re.finditer(pattern, source))
    if len(matches) != 1:
        raise AssertionError(
            f"{description} must have exactly one matching production branch"
        )
    opening = source.find("{", matches[0].end())
    if opening < 0:
        raise AssertionError(f"{description} branch has no braced body")
    return braced_body(source, opening, description)


def call_end(source: str, call: str) -> int:
    start = source.find(call)
    if start < 0 or source.find(call, start + len(call)) >= 0:
        raise AssertionError(f"expected exactly one {call} call")
    opening = source.find("(", start + len(call))
    if opening < 0:
        raise AssertionError(f"{call} has no argument list")
    depth = 0
    quote: str | None = None
    index = opening
    while index < len(source):
        character = source[index]
        if quote is not None:
            if character == "\\":
                index += 2
                continue
            if character == quote:
                quote = None
        elif character in ('"', "'"):
            quote = character
        elif character == "(":
            depth += 1
        elif character == ")":
            depth -= 1
            if depth == 0:
                semicolon = source.find(";", index + 1)
                if semicolon < 0:
                    raise AssertionError(f"{call} result is not a statement")
                return semicolon + 1
        index += 1
    raise AssertionError(f"unterminated {call} argument list")


def validate_metadata(source: str) -> None:
    get_media = function_body(
        source, "std::string ChromecastCommunication::GetMedia("
    )
    music = conditional_body(
        get_media,
        r"if\s*\(\s*b_music\s*\)",
        "Chromecast music-metadata emission",
    )
    get_media_compact = compact(get_media)
    music_compact = compact(music)

    for variable, json_key, metadata_key in METADATA_FIELDS:
        extraction = f"{variable}=meta_get_escaped(p_meta,{metadata_key});"
        condition = f"if(!{variable}.empty())"
        emission = f'ss<<",\\"{json_key}\\":\\""<<{variable}<<"\\"";'
        if get_media_compact.count(extraction) != 1:
            raise AssertionError(
                f"{variable} is not extracted exactly once from {metadata_key}"
            )
        if music_compact.count(condition + emission) != 1:
            raise AssertionError(
                f"{json_key} is not emitted exactly once behind its non-empty value"
            )
        if f"if({variable}.empty())" in music_compact:
            raise AssertionError(f"{json_key} still uses the inverted empty predicate")
        if music_compact.count(f'\\"{json_key}\\"') != 1:
            raise AssertionError(f"{json_key} has an ambiguous JSON emission")


def validate_warning(source: str, result_type: str, renderer: str) -> None:
    update = function_body(
        source, f"{result_type} sout_stream_sys_t::UpdateOutput("
    )
    warning = conditional_body(
        update,
        r"if\s*\(\s*!\s*perf_warning_shown\b",
        f"{renderer} performance-warning guard",
    )
    update_compact = compact(update)
    if update_compact.count("perf_warning_shown(false)") != 0:
        # Constructor initialization is outside UpdateOutput; this guards
        # against a reassuring token being moved into the wrong function.
        raise AssertionError(f"{renderer} warning initialization moved into UpdateOutput")
    full_compact = compact(source)
    if full_compact.count("perf_warning_shown(false)") != 1:
        raise AssertionError(f"{renderer} warning latch is not initialized once")
    if full_compact.count("boolperf_warning_shown;") != 1:
        raise AssertionError(f"{renderer} warning latch member is not unique")
    if compact(update).count("vlc_dialog_wait_question(") != 1:
        raise AssertionError(f"{renderer} UpdateOutput has an ambiguous warning dialog")
    if compact(update).count("perf_warning_shown=true;") != 1:
        raise AssertionError(f"{renderer} UpdateOutput does not latch one shown warning")

    tail = compact(warning[call_end(warning, "vlc_dialog_wait_question") :])
    required_prefix = "perf_warning_shown=true;if(res<=0)returnfalse;"
    if not tail.startswith(required_prefix):
        raise AssertionError(
            f"{renderer} must latch the shown warning immediately before cancel returns"
        )
    if (
        'if(res==2)config_PutInt(RENDERER_CFG_PREFIX"show-perf-warning",0);'
        not in tail
    ):
        raise AssertionError(
            f"{renderer} no-longer-warning preference is not response-2-only"
        )


def validate_sources(sources: Mapping[str, str]) -> None:
    if set(sources) != set(PATHS):
        raise AssertionError("0035 source inventory is not exact")
    validate_metadata(sources["communication"])
    validate_warning(sources["cast"], "bool", "Chromecast")
    validate_warning(sources["dlna"], "int", "DLNA")


def patch_changes(patch: str) -> tuple[tuple[str, ...], Counter[str], Counter[str]]:
    paths: list[str] = []
    added: Counter[str] = Counter()
    removed: Counter[str] = Counter()
    for line in patch.splitlines():
        match = re.fullmatch(r"diff --git a/(.+) b/(.+)", line)
        if match:
            if match.group(1) != match.group(2):
                raise AssertionError("0035 cannot rename a VLC path")
            paths.append(match.group(1))
            continue
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            added[line[1:]] += 1
        elif line.startswith("-"):
            removed[line[1:]] += 1
    return tuple(paths), added, removed


def validate_patch(patch: str) -> None:
    paths, added, removed = patch_changes(patch)
    expected_added = Counter(
        {
            "                if( !album.empty() )": 1,
            "                if( !albumartist.empty() )": 1,
            "                if( !tracknumber.empty() )": 1,
            "                if( !discnumber.empty() )": 1,
            "            perf_warning_shown = true;": 2,
        }
    )
    expected_removed = Counter(
        {
            "                if( album.empty() )": 1,
            "                if( albumartist.empty() )": 1,
            "                if( tracknumber.empty() )": 1,
            "                if( discnumber.empty() )": 1,
            "            perf_warning_shown = true;": 2,
        }
    )
    if paths != PATCH_PATHS:
        raise AssertionError(
            f"0035 patch path inventory changed: expected {PATCH_PATHS!r}, got {paths!r}"
        )
    if added != expected_added or removed != expected_removed:
        raise AssertionError("0035 contains a non-upstream or incomplete code delta")


def replace_once(
    sources: Mapping[str, str], key: str, old: str, new: str
) -> dict[str, str]:
    source = sources[key]
    if source.count(old) != 1:
        raise AssertionError(f"mutation fixture {key}:{old!r} is not unique")
    mutated = dict(sources)
    mutated[key] = source.replace(old, new, 1)
    return mutated


def run_source_mutations(sources: Mapping[str, str]) -> int:
    mutations: list[tuple[str, str, str]] = []
    for variable, json_key, _ in METADATA_FIELDS:
        mutations.append(
            (
                "communication",
                f"if( !{variable}.empty() )",
                f"if( {variable}.empty() )",
            )
        )
        mutations.append(
            (
                "communication",
                f'\\"{json_key}\\":\\"" << {variable}',
                f'\\"wrong{json_key}\\":\\"" << {variable}',
            )
        )
    for key in ("cast", "dlna"):
        mutations.extend(
            (
                (
                    key,
                    "perf_warning_shown = true;\n            if ( res <= 0 )\n                 return false;",
                    "if ( res <= 0 )\n                 return false;\n            perf_warning_shown = true;",
                ),
                (
                    key,
                    "if ( !perf_warning_shown &&",
                    "if ( perf_warning_shown &&",
                ),
                (
                    key,
                    "perf_warning_shown = true;",
                    "perf_warning_shown = false;",
                ),
            )
        )

    for index, (key, old, new) in enumerate(mutations, 1):
        mutated = replace_once(sources, key, old, new)
        try:
            validate_sources(mutated)
        except AssertionError:
            continue
        raise AssertionError(f"source mutation {index} escaped: {key}:{old}")
    return len(mutations)


def run_patch_mutations(patch: str) -> int:
    mutations = (
        (
            "+                if( !album.empty() )",
            "+                if( album.empty() )",
        ),
        (
            "diff --git a/modules/stream_out/dlna/dlna.cpp b/modules/stream_out/dlna/dlna.cpp",
            "diff --git a/modules/stream_out/dlna/dlna.cpp b/modules/stream_out/dlna/other.cpp",
        ),
        (
            "+            perf_warning_shown = true;",
            "+            perf_warning_shown = false;",
        ),
    )
    for index, (old, new) in enumerate(mutations, 1):
        if patch.count(old) < 1:
            raise AssertionError(f"patch mutation fixture {old!r} is missing")
        mutated = patch.replace(old, new, 1)
        try:
            validate_patch(mutated)
        except AssertionError:
            continue
        raise AssertionError(f"patch mutation {index} escaped: {old}")
    return len(mutations)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vlc_source_root", type=Path)
    parser.add_argument("patch", type=Path)
    arguments = parser.parse_args()
    root = arguments.vlc_source_root.resolve()
    sources: dict[str, str] = {}
    for key, relative in PATHS.items():
        path = root / relative
        if not path.is_file():
            raise SystemExit(f"missing 0035 validation input: {path}")
        sources[key] = path.read_text(encoding="utf-8")
    if not arguments.patch.is_file():
        raise SystemExit(f"missing 0035 patch: {arguments.patch}")
    patch = arguments.patch.read_text(encoding="utf-8")

    validate_patch(patch)
    validate_sources(sources)
    source_mutations = run_source_mutations(sources)
    patch_mutations = run_patch_mutations(patch)
    print(
        "PASS Chromecast 0035 source proof: "
        f"files={len(sources)} source_mutations={source_mutations} "
        f"patch_mutations={patch_mutations}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
