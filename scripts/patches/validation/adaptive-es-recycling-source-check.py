#!/usr/bin/env python3
"""Fail-closed proof for demux codec-configuration identity and ES reuse."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
from typing import Callable


MAKEFILE_PATH = "modules/demux/Makefile.am"
HEADER_PATH = "modules/demux/codec_configuration.h"
ADAPTIVE_PATH = "modules/demux/adaptive/plumbing/FakeESOutID.cpp"
TEST_PATH = "modules/demux/adaptive/test/plumbing/FakeEsOut.cpp"
MP4_PATH = "modules/demux/mp4/mp4.c"
PATCH_PATHS = (
    MAKEFILE_PATH,
    HEADER_PATH,
    ADAPTIVE_PATH,
    TEST_PATH,
    MP4_PATH,
)
EXPECTED_PATCH_SHA256 = (
    "6675edb052faa037c763451b6c9aae9b43dc42769d9311332371eda8bd788611"
)
HELPER_NAME = "demux_IsCodecExtraDataIdentical"
HELPER_BODY = """static inline bool
demux_IsCodecExtraDataIdentical( const es_format_t *left,
                                 const es_format_t *right )
{
    return left->i_extra == right->i_extra &&
           (left->i_extra == 0 ||
            memcmp( left->p_extra, right->p_extra, left->i_extra ) == 0);
}"""


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def require_count(source: str, token: str, count: int, description: str) -> None:
    actual = source.count(token)
    if actual != count:
        raise AssertionError(
            f"{description} count is {actual}, expected exactly {count}"
        )


def function_slice(source: str, start_token: str, end_token: str) -> str:
    try:
        start = source.index(start_token)
        end = source.index(end_token, start + len(start_token))
    except ValueError as error:
        raise AssertionError(
            f"could not isolate source region {start_token!r} -> {end_token!r}"
        ) from error
    return source[start:end]


def validate_header(header: str) -> None:
    require_count(header, HELPER_BODY, 1, "shared byte-identity helper")
    require_count(header, "#ifndef VLC_DEMUX_CODEC_CONFIGURATION_H", 1, "include guard")
    require_count(header, "#define VLC_DEMUX_CODEC_CONFIGURATION_H", 1, "guard definition")
    require_count(header, "#include <vlc_es.h>", 1, "es_format declaration")
    require_count(header, "#include <string.h>", 1, "memcmp declaration")
    require_count(header, "!!memcmp", 0, "historically inverted memcmp result")


def validate_makefile(makefile: str) -> None:
    require_count(
        makefile,
        "noinst_HEADERS += demux/codec_configuration.h",
        1,
        "distributed internal helper header",
    )


def validate_adaptive_source(source: str) -> None:
    require_count(
        source,
        '#include "../../codec_configuration.h"',
        1,
        "adaptive helper include",
    )
    function = function_slice(
        source,
        "bool FakeESOutID::isCompatible(",
        "void FakeESOutID::setScheduledForDeletion()",
    )
    for codec in (
        "VLC_CODEC_H264",
        "VLC_CODEC_HEVC",
        "VLC_CODEC_VC1",
        "VLC_CODEC_AV1",
    ):
        require_count(function, codec, 1, f"{codec} guarded compatibility case")
    require_count(
        function,
        "fmt.i_extra == p_other->fmt.i_extra",
        1,
        "equal codec-configuration size gate",
    )
    require_count(
        function,
        "return demux_IsCodecExtraDataIdentical(&fmt, &p_other->fmt);",
        1,
        "adaptive byte-identity decision",
    )
    require_count(
        function,
        "!!memcmp(fmt.p_extra, p_other->fmt.p_extra, fmt.i_extra)",
        0,
        "inverted adaptive video byte comparison",
    )


def validate_mp4_source(source: str) -> None:
    require_count(
        source,
        '#include "../codec_configuration.h"',
        1,
        "MP4 helper include",
    )
    function = function_slice(
        source,
        "static bool FormatIsCompatible(",
        "static int TrackUpdateFormat(",
    )
    branch = """    if( p_fmt1->i_extra && p_fmt2->i_extra )
        return p_fmt1->i_codec == p_fmt2->i_codec &&
               demux_IsCodecExtraDataIdentical( p_fmt1, p_fmt2 );"""
    require_count(function, branch, 1, "MP4 byte-identity branch")
    require_count(function, "memcmp(", 0, "duplicated MP4 byte comparison")
    require_count(function, "!!memcmp", 0, "inverted MP4 byte comparison")
    require_count(
        source,
        "!FormatIsCompatible( &p_track->fmt, &tmpfmt )",
        1,
        "MP4 sample-description replacement decision",
    )


def validate_regression_test(test_source: str) -> None:
    check = function_slice(test_source, "static int check4(", "static int check2(")
    ordered_tokens = (
        "VLC_CODEC_H264, VLC_CODEC_HEVC, VLC_CODEC_VC1, VLC_CODEC_AV1",
        "es_format_Init(&candidate, VIDEO_ES, codec);",
        "FakeESOutID original(fakees, &candidate, source);",
        "FakeESOutID identical(fakees, &candidate, source);",
        "Expect(original.isCompatible(&identical));",
        "FakeESOutID discontinuity(fakees, &candidate, SrcID::make());",
        "Expect(!original.isCompatible(&discontinuity));",
        "FakeESOutID missingExtra(fakees, &candidate, source);",
        "Expect(!original.isCompatible(&missingExtra));",
        "FakeESOutID shorter(fakees, &candidate, source);",
        "Expect(!original.isCompatible(&shorter));",
        "FakeESOutID changed(fakees, &candidate, source);",
        "Expect(!original.isCompatible(&changed));",
        "es_format_Init(&fmt, VIDEO_ES, VLC_CODEC_H264);",
        "fmt.p_extra = malloc(sizeof(extra));",
        "memcpy(fmt.p_extra, extra, sizeof(extra));",
        "dummy->eslist.front()->b_selected = true;",
        "fakees->recycleAll();",
        "Expect(dummy->eslist.size() == 1);",
        "fakees->recycleAll();",
        "static_cast<uint8_t *>(fmt.p_extra)[3] ^= 1;",
        "Expect(dummy->eslist.size() == 2);",
        "fakees->gc();",
        "Expect(dummy->eslist.size() == 1);",
    )
    cursor = 0
    for token in ordered_tokens:
        index = check.find(token, cursor)
        if index < 0:
            raise AssertionError(
                f"adaptive ES regression test lacks ordered proof token: {token}"
            )
        cursor = index + len(token)

    require_count(check, "fakees->recycleAll();", 2, "recycling phases")
    require_count(check, "fakees->gc();", 2, "collection phases")
    require_count(
        check,
        "fakees->commandsQueue()->Process(drainTimes);",
        3,
        "real-ES command processing phases",
    )
    require_count(
        check,
        "Expect(dummy->eslist.front()->b_selected == true);",
        2,
        "selection-retention assertions",
    )
    require_count(
        test_source,
        "= { check0, check1, check2, check3, check4 };",
        1,
        "registered native regression test",
    )
    require_count(
        test_source,
        "int(* const tests[5])",
        1,
        "native regression test array bound",
    )


def patch_sections(patch: str) -> tuple[str, ...]:
    matches = list(re.finditer(r"^diff --git a/(.+) b/(.+)$", patch, re.MULTILINE))
    paths: list[str] = []
    for match in matches:
        old_path, new_path = match.groups()
        if old_path != new_path:
            raise AssertionError("0042 cannot rename a VLC path")
        paths.append(old_path)
    return tuple(paths)


def validate_patch(patch: str) -> None:
    if patch_sections(patch) != PATCH_PATHS:
        raise AssertionError(f"0042 path set/order changed: {patch_sections(patch)!r}")
    require_count(patch, "new file mode 100644", 1, "new helper header mode")
    require_count(
        patch,
        "diff --git a/modules/demux/codec_configuration.h "
        "b/modules/demux/codec_configuration.h\nnew file mode 100644",
        1,
        "new helper header patch",
    )
    if any(marker in patch for marker in ("GIT binary patch", "deleted file mode")):
        raise AssertionError("0042 must not contain a binary or deletion")
    actual = sha256_bytes(patch.encode("utf-8"))
    if actual != EXPECTED_PATCH_SHA256:
        raise AssertionError(
            f"0042 patch changed: expected {EXPECTED_PATCH_SHA256}, got {actual}"
        )


def replace_once(source: str, old: str, new: str, description: str) -> str:
    if source.count(old) != 1:
        raise AssertionError(f"checker mutation fixture is ambiguous: {description}")
    return source.replace(old, new, 1)


def expect_rejected(
    source: str,
    validate: Callable[[str], None],
    mutate: Callable[[str], str],
    name: str,
) -> None:
    mutated = mutate(source)
    if mutated == source:
        raise AssertionError(f"source mutation {name!r} changed nothing")
    try:
        validate(mutated)
    except AssertionError:
        return
    raise AssertionError(f"source mutation survived validation: {name}")


def validate_mutations(
    header: str,
    adaptive: str,
    mp4: str,
    test_source: str,
    patch: str,
) -> int:
    fixtures: tuple[
        tuple[str, str, Callable[[str], None], Callable[[str], str]], ...
    ] = (
        (
            "invert shared memcmp truth value",
            header,
            validate_header,
            lambda value: replace_once(value, "memcmp( left->p_extra, right->p_extra, left->i_extra ) == 0", "!!memcmp( left->p_extra, right->p_extra, left->i_extra )", "helper memcmp"),
        ),
        (
            "accept unequal configuration sizes",
            header,
            validate_header,
            lambda value: replace_once(value, "left->i_extra == right->i_extra", "left->i_extra != right->i_extra", "helper size equality"),
        ),
        (
            "bypass the adaptive shared helper",
            adaptive,
            validate_adaptive_source,
            lambda value: replace_once(value, "return demux_IsCodecExtraDataIdentical(&fmt, &p_other->fmt);", "return true;", "adaptive helper call"),
        ),
        (
            "drop adaptive HEVC coverage",
            adaptive,
            validate_adaptive_source,
            lambda value: replace_once(value, "        case VLC_CODEC_HEVC:\n", "", "HEVC case"),
        ),
        (
            "invert MP4 codec identity",
            mp4,
            validate_mp4_source,
            lambda value: replace_once(value, "return p_fmt1->i_codec == p_fmt2->i_codec &&", "return p_fmt1->i_codec != p_fmt2->i_codec &&", "MP4 codec equality"),
        ),
        (
            "bypass the MP4 shared helper",
            mp4,
            validate_mp4_source,
            lambda value: replace_once(value, "demux_IsCodecExtraDataIdentical( p_fmt1, p_fmt2 );", "true;", "MP4 helper call"),
        ),
        (
            "drop discontinuity source boundary assertion",
            test_source,
            validate_regression_test,
            lambda value: replace_once(value, "        Expect(!original.isCompatible(&discontinuity));\n", "", "source boundary"),
        ),
        (
            "do not change the integration codec configuration",
            test_source,
            validate_regression_test,
            lambda value: replace_once(value, "        fakees->recycleAll();\n        static_cast<uint8_t *>(fmt.p_extra)[3] ^= 1;\n        id = es_out_Add(out, &fmt);", "        fakees->recycleAll();\n        id = es_out_Add(out, &fmt);", "changed integration extradata"),
        ),
        (
            "expect changed configuration to reuse the old ES",
            test_source,
            validate_regression_test,
            lambda value: replace_once(value, "        Expect(dummy->eslist.size() == 2);\n        fakees->gc();", "        Expect(dummy->eslist.size() == 1);\n        fakees->gc();", "non-reuse assertion"),
        ),
        (
            "omit native test registration",
            test_source,
            validate_regression_test,
            lambda value: replace_once(value, "= { check0, check1, check2, check3, check4 };", "= { check0, check1, check2, check3 };", "test registration"),
        ),
    )
    for name, source, validate, mutate in fixtures:
        expect_rejected(source, validate, mutate, name)

    try:
        validate_patch(patch + "\n")
    except AssertionError:
        pass
    else:
        raise AssertionError("0042 patch mutation survived validation")
    return len(fixtures) + 1


def codec_extra_identical(left: bytes | None, right: bytes | None) -> bool:
    left_bytes = left or b""
    right_bytes = right or b""
    return len(left_bytes) == len(right_bytes) and left_bytes == right_bytes


def adaptive_video_compatible(
    left: bytes | None,
    right: bytes | None,
    *,
    same_source: bool,
) -> bool:
    return bool(left) and bool(right) and same_source and codec_extra_identical(left, right)


def mp4_extra_branch_compatible(
    left: bytes | None,
    right: bytes | None,
    *,
    same_codec: bool,
) -> bool:
    return bool(left) and bool(right) and same_codec and codec_extra_identical(left, right)


def validate_state_matrix() -> int:
    cases = (
        (b"\x01\x64\x00\x1f", b"\x01\x64\x00\x1f", True, True, True, True),
        (b"\x01\x64\x00\x1f", b"\x01\x64\x00\x1f", False, True, False, True),
        (b"\x01\x64\x00\x1f", b"\x01\x64\x00\x20", True, True, False, False),
        (b"\x01\x64", b"\x01\x64\x00", True, True, False, False),
        (b"\x01\x64", b"\x01\x64", True, False, True, False),
        (b"\x01\x64", None, True, True, False, False),
        (None, None, True, True, False, False),
    )
    for left, right, same_source, same_codec, expected_adaptive, expected_mp4 in cases:
        adaptive = adaptive_video_compatible(left, right, same_source=same_source)
        mp4 = mp4_extra_branch_compatible(left, right, same_codec=same_codec)
        if (adaptive, mp4) != (expected_adaptive, expected_mp4):
            raise AssertionError(
                f"codec state {(left, right, same_source, same_codec)!r} produced "
                f"{(adaptive, mp4)!r}, expected {(expected_adaptive, expected_mp4)!r}"
            )
    return len(cases)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("patch", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    source_root = arguments.source_root.resolve()
    patch_path = arguments.patch.resolve()
    paths = {relative: source_root / relative for relative in PATCH_PATHS}
    for relative, path in paths.items():
        if not path.is_file():
            raise SystemExit(f"missing patched VLC source: {relative}")
    if not patch_path.is_file():
        raise SystemExit(f"missing 0042 patch: {patch_path}")

    makefile = paths[MAKEFILE_PATH].read_text(encoding="utf-8")
    header = paths[HEADER_PATH].read_text(encoding="utf-8")
    adaptive = paths[ADAPTIVE_PATH].read_text(encoding="utf-8")
    test_source = paths[TEST_PATH].read_text(encoding="utf-8")
    mp4 = paths[MP4_PATH].read_text(encoding="utf-8")
    patch = patch_path.read_text(encoding="utf-8")
    validate_makefile(makefile)
    validate_header(header)
    validate_adaptive_source(adaptive)
    validate_mp4_source(mp4)
    validate_regression_test(test_source)
    validate_patch(patch)
    mutations = validate_mutations(header, adaptive, mp4, test_source, patch)
    states = validate_state_matrix()
    print(
        "PASS demux codec-configuration identity proof: "
        f"paths={len(PATCH_PATHS)} mutations={mutations} states={states} "
        f"patch_sha={EXPECTED_PATCH_SHA256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
