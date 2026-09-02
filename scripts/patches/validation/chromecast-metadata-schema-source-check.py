#!/usr/bin/env python3
"""Fail-closed source, supersession, and mutation proof for VLC patch 0036."""

from __future__ import annotations

import argparse
from collections import Counter
import importlib.util
from pathlib import Path
import re
from types import ModuleType
from typing import Mapping


PATHS = {
    "communication": "modules/stream_out/chromecast/chromecast_communication.cpp",
    "protocol": "modules/stream_out/chromecast/chromecast_protocol.hpp",
    "cast": "modules/stream_out/chromecast/cast.cpp",
    "dlna": "modules/stream_out/dlna/dlna.cpp",
}

PATCH_PATHS = (PATHS["communication"], PATHS["protocol"])


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
    if start < 0 or source.find(signature, start + len(signature)) >= 0:
        raise AssertionError(f"expected exactly one production function {signature}")
    opening = source.find("{", start + len(signature))
    if opening < 0:
        raise AssertionError(f"missing body for {signature}")
    return braced_body(source, opening, signature)


def conditional_body(source: str, pattern: str, description: str) -> str:
    matches = list(re.finditer(pattern, source))
    if len(matches) != 1:
        raise AssertionError(f"{description} must have exactly one branch")
    opening = source.find("{", matches[0].end())
    if opening < 0:
        raise AssertionError(f"{description} branch has no body")
    return braced_body(source, opening, description)


EXPECTED_HELPER_BODY = compact(
    """{
        if (result == nullptr || value.empty())
            return false;
        unsigned parsed = 0;
        for (const unsigned char character : value)
        {
            if (character < '0' || character > '9')
                return false;
            const unsigned digit = character - '0';
            if (parsed > (std::numeric_limits<unsigned>::max() - digit) / 10)
                return false;
            parsed = parsed * 10 + digit;
        }
        if (parsed == 0)
            return false;
        *result = parsed;
        return true;
    }"""
)

EXPECTED_POLICY_BODY = compact(
    """{
        return !title.empty() ||
               (music && (!artist.empty() || !album.empty() ||
                          !album_artist.empty() || has_track_number ||
                          has_disc_number));
    }"""
)


def validate_helper(source: str) -> None:
    signature = (
        "chromecast_positive_metadata_integer(std::string_view value, "
        "unsigned *result)"
    )
    if compact(source).count(compact(signature)) != 1:
        raise AssertionError("metadata integer helper signature is not unique")
    body = function_body(source, signature)
    if compact(body) != EXPECTED_HELPER_BODY:
        raise AssertionError(
            "metadata integer helper no longer performs the exact complete, "
            "ASCII-only, positive, overflow-checked parse"
        )
    forbidden = ("strtol", "strtoul", "stoi", "stoul", "isdigit", "stringstream")
    if any(token in body for token in forbidden):
        raise AssertionError("metadata integer helper uses a partial or locale parser")

    policy_signature = (
        "chromecast_should_emit_metadata(bool music, std::string_view title,"
    )
    if compact(source).count(compact(policy_signature)) != 1:
        raise AssertionError("metadata-presence policy helper is not unique")
    policy_body = function_body(source, policy_signature)
    if compact(policy_body) != EXPECTED_POLICY_BODY:
        raise AssertionError(
            "music-field optionality or generic title-only policy changed"
        )


def validate_production(source: str) -> None:
    get_media = function_body(
        source, "std::string ChromecastCommunication::GetMedia("
    )
    decision_match = re.search(
        r"if\s*\(\s*chromecast_should_emit_metadata\s*\(.*?"
        r"has_discnumber\s*\)\s*\)",
        get_media,
        flags=re.DOTALL,
    )
    if decision_match is None:
        raise AssertionError("metadata-presence policy is not used in GetMedia")
    extraction = conditional_body(
        get_media[: decision_match.start()],
        r"if\s*\(\s*b_music\s*\)",
        "music metadata extraction",
    )
    metadata_opening = get_media.find("{", decision_match.end())
    if metadata_opening < 0:
        raise AssertionError("metadata-presence decision has no body")
    metadata = braced_body(get_media, metadata_opening, "metadata object emission")
    emission = conditional_body(
        metadata,
        r"if\s*\(\s*b_music\s*\)",
        "music metadata emission",
    )
    get_compact = compact(get_media)
    extraction_compact = compact(extraction)
    metadata_compact = compact(metadata)
    emission_compact = compact(emission)

    declarations = (
        "unsignedtracknumber=0;unsigneddiscnumber=0;"
        "boolhas_tracknumber=false;boolhas_discnumber=false;"
    )
    if get_compact.count(declarations) != 1:
        raise AssertionError("numeric metadata values and validity flags are not exact")

    required_extraction = (
        "constchar*consttrack=vlc_meta_Get(p_meta,vlc_meta_TrackNumber);"
        "constchar*constdisc=vlc_meta_Get(p_meta,vlc_meta_DiscNumber);"
        "has_tracknumber=track!=nullptr&&"
        "chromecast_positive_metadata_integer(track,&tracknumber);"
        "has_discnumber=disc!=nullptr&&"
        "chromecast_positive_metadata_integer(disc,&discnumber);"
    )
    if extraction_compact.count(required_extraction) != 1:
        raise AssertionError(
            "track/disc values are not parsed once from their complete raw VLC values"
        )
    if extraction_compact.count("chromecast_positive_metadata_integer(") != 2:
        raise AssertionError("production does not bind both numeric fields to the helper")
    if "if(b_music&&!title.empty())" in get_compact:
        raise AssertionError("music fields are still gated on the primary title")
    if "meta_get_escaped(p_meta,vlc_meta_TrackNumber)" in get_compact:
        raise AssertionError("trackNumber is parsed after JSON escaping")
    if "meta_get_escaped(p_meta,vlc_meta_DiscNumber)" in get_compact:
        raise AssertionError("discNumber is parsed after JSON escaping")

    decision = (
        "chromecast_should_emit_metadata(b_music,title,artist,album,"
        "albumartist,has_tracknumber,has_discnumber)"
    )
    if get_compact.count(decision) != 1:
        raise AssertionError("GetMedia does not use the exact metadata-presence policy")
    fallback = (
        "if(title.empty()){"
        "title=meta_get_escaped(p_meta,vlc_meta_NowPlaying);"
        "if(title.empty())"
        "title=meta_get_escaped(p_meta,vlc_meta_ESNowPlaying);"
        "}"
    )
    if get_compact.count(fallback) != 1:
        raise AssertionError("NowPlaying/ESNowPlaying fallback sequence changed")
    if get_compact.find(fallback) > get_compact.find(decision):
        raise AssertionError("NowPlaying title fallback must precede metadata emission")
    title_emission = 'if(!title.empty())ss<<",\\"title\\":\\""<<title<<"\\"";'
    if metadata_compact.count(title_emission) != 1:
        raise AssertionError("title must be omitted rather than emitted empty")
    if metadata_compact.count('\\"title\\"') != 1:
        raise AssertionError("title emission is missing or ambiguous")

    textual_fields = (
        (
            "artist",
            "artist",
            "vlc_meta_Artist",
        ),
        (
            "album",
            "albumName",
            "vlc_meta_Album",
        ),
        (
            "albumartist",
            "albumArtist",
            "vlc_meta_AlbumArtist",
        ),
    )
    for variable, json_key, metadata_key in textual_fields:
        extraction_token = f"{variable}=meta_get_escaped(p_meta,{metadata_key});"
        emission_token = (
            f'if(!{variable}.empty())ss<<",\\"{json_key}\\":\\""'
            f'<<{variable}<<"\\"";'
        )
        if extraction_compact.count(extraction_token) != 1:
            raise AssertionError(f"{json_key} extraction is not exact")
        if emission_compact.count(emission_token) != 1:
            raise AssertionError(f"{json_key} emission is not exact")

    if '\\"album\\":' in emission_compact:
        raise AssertionError("legacy non-schema album key remains")
    if emission_compact.count('\\"albumName\\"') != 1:
        raise AssertionError("albumName key is missing or ambiguous")

    numeric_fields = (
        ("tracknumber", "has_tracknumber", "trackNumber"),
        ("discnumber", "has_discnumber", "discNumber"),
    )
    for variable, flag, json_key in numeric_fields:
        token = f'if({flag})ss<<",\\"{json_key}\\":"<<{variable};'
        if emission_compact.count(token) != 1:
            raise AssertionError(
                f"{json_key} is not emitted once as an unquoted valid integer"
            )
        if f'\\"{json_key}\\":\\"' in emission_compact:
            raise AssertionError(f"{json_key} is still emitted as a JSON string")
        if emission_compact.count(f'\\"{json_key}\\"') != 1:
            raise AssertionError(f"{json_key} emission is ambiguous")


def validate_sources(sources: Mapping[str, str]) -> None:
    if set(sources) != set(PATHS):
        raise AssertionError("0036 source inventory is not exact")
    validate_helper(sources["protocol"])
    validate_production(sources["communication"])


def patch_changes(patch: str) -> tuple[tuple[str, ...], Counter[str], Counter[str]]:
    paths: list[str] = []
    added: Counter[str] = Counter()
    removed: Counter[str] = Counter()
    for line in patch.splitlines():
        match = re.fullmatch(r"diff --git a/(.+) b/(.+)", line)
        if match:
            if match.group(1) != match.group(2):
                raise AssertionError("0036 cannot rename a VLC path")
            paths.append(match.group(1))
            continue
        if line.startswith("+++") or line.startswith("---"):
            continue
        if line.startswith("+"):
            added[line[1:]] += 1
        elif line.startswith("-"):
            removed[line[1:]] += 1
    return tuple(paths), added, removed


EXPECTED_ADDED = Counter(
    (
        "    unsigned tracknumber = 0;",
        "    unsigned discnumber = 0;",
        "    bool has_tracknumber = false;",
        "    bool has_discnumber = false;",
        "        if( b_music )",
        "            const char *const track = vlc_meta_Get( p_meta, vlc_meta_TrackNumber );",
        "            const char *const disc = vlc_meta_Get( p_meta, vlc_meta_DiscNumber );",
        "            has_tracknumber = track != nullptr &&",
        "                chromecast_positive_metadata_integer( track, &tracknumber );",
        "            has_discnumber = disc != nullptr &&",
        "                chromecast_positive_metadata_integer( disc, &discnumber );",
        "        if ( chromecast_should_emit_metadata( b_music, title, artist, album,",
        "                                              albumartist, has_tracknumber,",
        "                                              has_discnumber ) )",
        '               << " \\"metadataType\\":" << ( b_music ? "3" : "0" );',
        "            if( !title.empty() )",
        '                ss << ",\\"title\\":\\"" << title << "\\"";',
        '                    ss << ",\\"albumName\\":\\"" << album << "\\"";',
        "                if( has_tracknumber )",
        '                    ss << ",\\"trackNumber\\":" << tracknumber;',
        "                if( has_discnumber )",
        '                    ss << ",\\"discNumber\\":" << discnumber;',
        "/* Cast's music metadata schema requires trackNumber and discNumber to be",
        " * positive JSON integers. Parse the complete VLC metadata value without",
        " * accepting locale whitespace, a sign, a fraction, or arithmetic overflow. */",
        "static inline bool",
        "chromecast_positive_metadata_integer(std::string_view value, unsigned *result)",
        "{",
        "    if (result == nullptr || value.empty())",
        "        return false;",
        "",
        "    unsigned parsed = 0;",
        "    for (const unsigned char character : value)",
        "    {",
        "        if (character < '0' || character > '9')",
        "            return false;",
        "        const unsigned digit = character - '0';",
        "        if (parsed > (std::numeric_limits<unsigned>::max() - digit) / 10)",
        "            return false;",
        "        parsed = parsed * 10 + digit;",
        "    }",
        "",
        "    if (parsed == 0)",
        "        return false;",
        "    *result = parsed;",
        "    return true;",
        "}",
        "",
        "/* Music fields in Cast's metadata schema are individually optional. Generic",
        " * metadata keeps VLC's existing title requirement; music metadata may be",
        " * useful when any supported music field is present. Artwork-only policy is",
        " * intentionally left to the caller's existing behavior. */",
        "static inline bool",
        "chromecast_should_emit_metadata(bool music, std::string_view title,",
        "                                std::string_view artist,",
        "                                std::string_view album,",
        "                                std::string_view album_artist,",
        "                                bool has_track_number,",
        "                                bool has_disc_number)",
        "{",
        "    return !title.empty() ||",
        "           (music && (!artist.empty() || !album.empty() ||",
        "                      !album_artist.empty() || has_track_number ||",
        "                      has_disc_number));",
        "}",
        "",
    )
)

EXPECTED_REMOVED = Counter(
    (
        "    std::string tracknumber;",
        "    std::string discnumber;",
        "        if( b_music && !title.empty() )",
        "            tracknumber = meta_get_escaped( p_meta, vlc_meta_TrackNumber );",
        "            discnumber = meta_get_escaped( p_meta, vlc_meta_DiscNumber );",
        "        if ( !title.empty() )",
        '               << " \\"metadataType\\":" << ( b_music ? "3" : "0" )',
        '               << ",\\"title\\":\\"" << title << "\\"";',
        '                    ss << ",\\"album\\":\\"" << album << "\\"";',
        "                if( !tracknumber.empty() )",
        '                    ss << ",\\"trackNumber\\":\\"" << tracknumber << "\\"";',
        "                if( !discnumber.empty() )",
        '                    ss << ",\\"discNumber\\":\\"" << discnumber << "\\"";',
    )
)


def validate_patch(patch: str) -> None:
    paths, added, removed = patch_changes(patch)
    if paths != PATCH_PATHS:
        raise AssertionError(
            f"0036 patch paths changed: expected {PATCH_PATHS!r}, got {paths!r}"
        )
    if added != EXPECTED_ADDED or removed != EXPECTED_REMOVED:
        raise AssertionError("0036 contains an incomplete or non-contract code delta")


def replace_once(source: str, old: str, new: str, description: str) -> str:
    if source.count(old) != 1:
        raise AssertionError(f"{description} fixture is not unique")
    return source.replace(old, new, 1)


SUPERSEDED_CHUNKS = (
    (
        "    unsigned tracknumber = 0;\n"
        "    unsigned discnumber = 0;\n"
        "    bool has_tracknumber = false;\n"
        "    bool has_discnumber = false;",
        "    std::string tracknumber;\n"
        "    std::string discnumber;",
    ),
    (
        "        if( b_music )\n"
        "        {\n"
        "            artist = meta_get_escaped( p_meta, vlc_meta_Artist );",
        "        if( b_music && !title.empty() )\n"
        "        {\n"
        "            artist = meta_get_escaped( p_meta, vlc_meta_Artist );",
    ),
    (
        "            const char *const track = vlc_meta_Get( p_meta, vlc_meta_TrackNumber );\n"
        "            const char *const disc = vlc_meta_Get( p_meta, vlc_meta_DiscNumber );\n"
        "            has_tracknumber = track != nullptr &&\n"
        "                chromecast_positive_metadata_integer( track, &tracknumber );\n"
        "            has_discnumber = disc != nullptr &&\n"
        "                chromecast_positive_metadata_integer( disc, &discnumber );",
        "            tracknumber = meta_get_escaped( p_meta, vlc_meta_TrackNumber );\n"
        "            discnumber = meta_get_escaped( p_meta, vlc_meta_DiscNumber );",
    ),
    (
        "        if ( chromecast_should_emit_metadata( b_music, title, artist, album,\n"
        "                                              albumartist, has_tracknumber,\n"
        "                                              has_discnumber ) )\n"
        "        {\n"
        "            ss << \"\\\"metadata\\\":{\"\n"
        "               << \" \\\"metadataType\\\":\" << ( b_music ? \"3\" : \"0\" );\n"
        "            if( !title.empty() )\n"
        "                ss << \",\\\"title\\\":\\\"\" << title << \"\\\"\";",
        "        if ( !title.empty() )\n"
        "        {\n"
        "            ss << \"\\\"metadata\\\":{\"\n"
        "               << \" \\\"metadataType\\\":\" << ( b_music ? \"3\" : \"0\" )\n"
        "               << \",\\\"title\\\":\\\"\" << title << \"\\\"\";",
    ),
    (
        '                    ss << ",\\"albumName\\":\\"" << album << "\\"";',
        '                    ss << ",\\"album\\":\\"" << album << "\\"";',
    ),
    (
        "                if( has_tracknumber )\n"
        '                    ss << ",\\"trackNumber\\":" << tracknumber;\n'
        "                if( has_discnumber )\n"
        '                    ss << ",\\"discNumber\\":" << discnumber;',
        "                if( !tracknumber.empty() )\n"
        '                    ss << ",\\"trackNumber\\":\\"" << tracknumber << "\\"";\n'
        "                if( !discnumber.empty() )\n"
        '                    ss << ",\\"discNumber\\":\\"" << discnumber << "\\"";',
    ),
)


def reconstruct_frozen_0035(communication: str) -> str:
    reconstructed = communication
    for index, (post_0036, post_0035) in enumerate(SUPERSEDED_CHUNKS, 1):
        reconstructed = replace_once(
            reconstructed,
            post_0036,
            post_0035,
            f"superseded 0035 metadata chunk {index}",
        )
    return reconstructed


def load_frozen_checker(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("frozen_0035_checker", path)
    if spec is None or spec.loader is None:
        raise AssertionError("cannot load frozen 0035 checker")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_frozen_0035_base(
    sources: Mapping[str, str], frozen_checker: Path, frozen_patch: Path
) -> tuple[int, int]:
    checker = load_frozen_checker(frozen_checker)
    legacy_sources = {
        "communication": reconstruct_frozen_0035(sources["communication"]),
        "cast": sources["cast"],
        "dlna": sources["dlna"],
    }
    patch = frozen_patch.read_text(encoding="utf-8")
    checker.validate_patch(patch)
    checker.validate_sources(legacy_sources)
    return (
        checker.run_source_mutations(legacy_sources),
        checker.run_patch_mutations(patch),
    )


def mutate_source(
    sources: Mapping[str, str], key: str, old: str, new: str
) -> dict[str, str]:
    mutated = dict(sources)
    mutated[key] = replace_once(mutated[key], old, new, f"{key}:{old}")
    return mutated


def run_source_mutations(sources: Mapping[str, str]) -> int:
    mutations = (
        ("communication", '\\"albumName\\"', '\\"album\\"'),
        ("communication", '\\"artist\\"', '\\"wrongArtist\\"'),
        (
            "communication",
            'ss << ",\\"trackNumber\\":" << tracknumber;',
            'ss << ",\\"trackNumber\\":\\"" << tracknumber << "\\"";',
        ),
        (
            "communication",
            'ss << ",\\"discNumber\\":" << discnumber;',
            'ss << ",\\"discNumber\\":\\"" << discnumber << "\\"";',
        ),
        ("communication", "if( has_tracknumber )", "if( !has_tracknumber )"),
        ("communication", "if( has_discnumber )", "if( !has_discnumber )"),
        (
            "communication",
            "        if( b_music )\n"
            "        {\n"
            "            artist = meta_get_escaped( p_meta, vlc_meta_Artist );",
            "        if( b_music && !title.empty() )\n"
            "        {\n"
            "            artist = meta_get_escaped( p_meta, vlc_meta_Artist );",
        ),
        (
            "communication",
            "chromecast_should_emit_metadata( b_music, title, artist, album,",
            "!title.empty() || chromecast_should_emit_metadata( b_music, title, artist, album,",
        ),
        ("communication", "if( !title.empty() )", "if( title.empty() )"),
        (
            "communication",
            "vlc_meta_NowPlaying",
            "vlc_meta_Title",
        ),
        (
            "communication",
            "vlc_meta_Artist",
            "vlc_meta_Album",
        ),
        (
            "communication",
            "vlc_meta_Get( p_meta, vlc_meta_TrackNumber )",
            "vlc_meta_Get( p_meta, vlc_meta_DiscNumber )",
        ),
        (
            "communication",
            "chromecast_positive_metadata_integer( track, &tracknumber )",
            "true",
        ),
        (
            "protocol",
            "result == nullptr || value.empty()",
            "result == nullptr",
        ),
        (
            "protocol",
            "character < '0' || character > '9'",
            "character > '9'",
        ),
        (
            "protocol",
            "character < '0' || character > '9'",
            "character < '0'",
        ),
        (
            "protocol",
            "parsed > (std::numeric_limits<unsigned>::max() - digit) / 10",
            "parsed >= (std::numeric_limits<unsigned>::max() - digit) / 10",
        ),
        ("protocol", "if (parsed == 0)", "if (parsed > 0)"),
        (
            "protocol",
            "parsed = parsed * 10 + digit;",
            "parsed = parsed * 10 + 1;",
        ),
        ("protocol", "*result = parsed;", "*result = 1;"),
        (
            "protocol",
            "music && (!artist.empty()",
            "true && (!artist.empty()",
        ),
    )
    for index, (key, old, new) in enumerate(mutations, 1):
        mutated = mutate_source(sources, key, old, new)
        try:
            validate_sources(mutated)
        except AssertionError:
            continue
        raise AssertionError(f"0036 source mutation {index} escaped: {key}:{old}")
    return len(mutations)


def run_patch_mutations(patch: str) -> int:
    mutations = (
        (
            "diff --git a/modules/stream_out/chromecast/chromecast_protocol.hpp "
            "b/modules/stream_out/chromecast/chromecast_protocol.hpp",
            "diff --git a/modules/stream_out/chromecast/chromecast_protocol.hpp "
            "b/modules/stream_out/chromecast/other.hpp",
        ),
        ('+                    ss << ",\\"albumName\\":', '+                    ss << ",\\"album\\":'),
        (
            '+                    ss << ",\\"trackNumber\\":" << tracknumber;',
            '+                    ss << ",\\"trackNumber\\":\\"" << tracknumber;',
        ),
        (
            "+        if (character < '0' || character > '9')",
            "+        if (character > '9')",
        ),
        (
            "+        if (parsed > (std::numeric_limits<unsigned>::max() - digit) / 10)",
            "+        if (false)",
        ),
        (
            "+        if( b_music )",
            "+        if( b_music && !title.empty() )",
        ),
        (
            "+        if ( chromecast_should_emit_metadata( b_music, title, artist, album,",
            "+        if ( !title.empty() && chromecast_should_emit_metadata( b_music, title, artist, album,",
        ),
    )
    for index, (old, new) in enumerate(mutations, 1):
        if patch.count(old) != 1:
            raise AssertionError(f"patch mutation fixture is not unique: {old!r}")
        mutated = patch.replace(old, new, 1)
        try:
            validate_patch(mutated)
        except AssertionError:
            continue
        raise AssertionError(f"0036 patch mutation {index} escaped: {old}")
    return len(mutations)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vlc_source_root", type=Path)
    parser.add_argument("patch", type=Path)
    parser.add_argument("frozen_0035_checker", type=Path)
    parser.add_argument("frozen_0035_patch", type=Path)
    arguments = parser.parse_args()

    sources: dict[str, str] = {}
    root = arguments.vlc_source_root.resolve()
    for key, relative in PATHS.items():
        path = root / relative
        if not path.is_file():
            raise SystemExit(f"missing 0036 validation input: {path}")
        sources[key] = path.read_text(encoding="utf-8")
    for path in (
        arguments.patch,
        arguments.frozen_0035_checker,
        arguments.frozen_0035_patch,
    ):
        if not path.is_file():
            raise SystemExit(f"missing 0036 contract input: {path}")

    patch = arguments.patch.read_text(encoding="utf-8")
    validate_patch(patch)
    validate_sources(sources)
    source_mutations = run_source_mutations(sources)
    patch_mutations = run_patch_mutations(patch)
    legacy_source_mutations, legacy_patch_mutations = validate_frozen_0035_base(
        sources,
        arguments.frozen_0035_checker,
        arguments.frozen_0035_patch,
    )
    print(
        "PASS Chromecast 0036 source proof: "
        f"files={len(sources)} source_mutations={source_mutations} "
        f"patch_mutations={patch_mutations} "
        f"frozen_0035_source_mutations={legacy_source_mutations} "
        f"frozen_0035_patch_mutations={legacy_patch_mutations}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
