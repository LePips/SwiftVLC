#!/usr/bin/env python3
"""Fail-closed source and state-contract proof for VLC patch 0040."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re
from typing import Callable


DECODER_PATH = "src/input/decoder.c"
EXPECTED_PATCH_SHA256 = (
    "a4945772122ce3d02f9a5c0c7136fa5dae940f251081238260b760b86c834681"
)
# Filled after the runtime probe is frozen. The validator and asset manifest
# independently bind this checker; keeping the probe hash here prevents a
# source-only pass from silently accepting a weakened runtime oracle.
EXPECTED_PROBE_SHA256 = (
    "4315e376376fc6ccbff83b7c76de06d0b540eb8ccc1bb5914cbea6f9b5dd2fe1"
)

PENDING_BLOCK = """        if (!Decoder_HasFrameNextObserverLocked(owner)
         && (owner->frames_countdown > 0
          || owner->strict_frame_request_id != 0))
            return false;"""

STOPPED_BLOCK = """        if (!Decoder_HasStartedVoutLocked(owner))
        {
            assert(owner->strict_frame_request_id == 0);
            assert(!Decoder_HasFrameNextObserverLocked(owner));
            return true;
        }"""

VOUT_QUERY = "        return vout_IsEmpty(owner->video.vout);"


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


def validate_helper(source: str) -> None:
    helper = function_slice(
        source,
        "static bool Decoder_HasStartedVoutLocked",
        "static atomic_uint_fast64_t frame_next_observer_nonce",
    )
    require_count(
        helper,
        "vlc_fifo_Assert(owner->p_fifo);",
        1,
        "started-vout helper FIFO assertion",
    )
    require_count(
        helper,
        "return owner->video.vout != NULL && owner->video.started;",
        1,
        "started-vout lifecycle predicate",
    )


def validate_drained_contract(source: str) -> None:
    drained = function_slice(
        source,
        "static bool vlc_input_decoder_IsDrainedLocked",
        "bool vlc_input_decoder_IsDrained(",
    )
    require_count(drained, PENDING_BLOCK, 1, "decoder-owned pending-work branch")
    require_count(drained, STOPPED_BLOCK, 1, "stopped-vout teardown branch")
    require_count(drained, VOUT_QUERY, 1, "render-thread emptiness query")

    pending_index = drained.index(PENDING_BLOCK)
    stopped_index = drained.index(STOPPED_BLOCK)
    query_index = drained.index(VOUT_QUERY)
    if not stopped_index < pending_index < query_index:
        raise AssertionError(
            "drain ordering must bypass an unstarted vout, preserve pending "
            "work for a started output, then consult its render thread"
        )

    require_count(
        drained,
        "vout_IsEmpty(",
        3,
        "vout_IsEmpty documentation plus executable call",
    )
    executable_prefix = drained[:query_index]
    if re.search(r"\breturn\s+vout_IsEmpty\s*\(", executable_prefix):
        raise AssertionError("vout_IsEmpty remains reachable before the started gate")


def validate_transition_contract(source: str) -> None:
    update = function_slice(
        source,
        "static int ModuleThread_UpdateVideoFormat",
        "static int CreateVoutIfNeeded",
    )
    try:
        cancellation = update.index(
            "Decoder_CancelStrictFrameLocked(p_owner, 0, 0, true);"
        )
        stopped = update.index("p_owner->video.started = false;")
        request = update.index("input_resource_RequestVout(")
        started = update.index("p_owner->video.started = true;")
    except ValueError as error:
        raise AssertionError("vout transition lifecycle marker is missing") from error
    if not cancellation < stopped < request < started:
        raise AssertionError(
            "vout transition must cancel observers, close admission, request "
            "the output, then reopen admission only on success"
        )

    replacement = function_slice(
        source,
        "static int CreateVoutIfNeeded(vlc_input_decoder_t *p_owner)\n{",
        "static vlc_decoder_device * ModuleThread_GetDecoderDevice",
    )
    try:
        replacement_cancellation = replacement.index(
            "Decoder_CancelStrictFrameLocked(p_owner, 0, 0, true);"
        )
        detached = replacement.index("p_owner->video.vout = NULL;")
        replacement_stopped = replacement.index("p_owner->video.started = false;")
        unlocked = replacement.index("vlc_fifo_Unlock( p_owner->p_fifo );")
        replacement_request = replacement.index("input_resource_RequestVout(")
    except ValueError as error:
        raise AssertionError("replacement-vout lifecycle marker is missing") from error
    if not (
        replacement_cancellation
        < detached
        < replacement_stopped
        < unlocked
        < replacement_request
    ):
        raise AssertionError(
            "vout replacement must cancel observers before detaching and "
            "closing admission, then request the replacement outside the FIFO"
        )

    require_count(
        source,
        "p_owner->video.started = false;",
        3,
        "initialized plus two runtime stopped-vout transitions",
    )
    require_count(
        source,
        "p_owner->video.started = true;",
        1,
        "successful started-vout transition",
    )


def validate_source(source: str) -> None:
    validate_helper(source)
    validate_drained_contract(source)
    validate_transition_contract(source)


def patch_sections(patch: str) -> tuple[str, ...]:
    matches = list(re.finditer(r"^diff --git a/(.+) b/(.+)$", patch, re.MULTILINE))
    paths: list[str] = []
    for match in matches:
        old_path, new_path = match.groups()
        if old_path != new_path:
            raise AssertionError("0040 cannot rename a VLC path")
        paths.append(old_path)
    return tuple(paths)


def validate_patch(patch: str) -> None:
    if patch_sections(patch) != (DECODER_PATH,):
        raise AssertionError("0040 must modify only src/input/decoder.c")
    if any(
        marker in patch
        for marker in ("GIT binary patch", "new file mode", "deleted file mode")
    ):
        raise AssertionError("0040 must be a text-only edit of an existing VLC file")
    actual = sha256_bytes(patch.encode("utf-8"))
    if actual != EXPECTED_PATCH_SHA256:
        raise AssertionError(
            f"0040 patch changed: expected {EXPECTED_PATCH_SHA256}, got {actual}"
        )


def validate_probe(probe: bytes) -> None:
    actual = sha256_bytes(probe)
    if actual != EXPECTED_PROBE_SHA256:
        raise AssertionError(
            "headless teardown runtime probe changed: "
            f"expected {EXPECTED_PROBE_SHA256}, got {actual}"
        )


def replace_once(source: str, old: str, new: str, description: str) -> str:
    if source.count(old) != 1:
        raise AssertionError(f"checker mutation fixture is ambiguous: {description}")
    return source.replace(old, new, 1)


def expect_rejected(source: str, mutate: Callable[[str], str], name: str) -> None:
    mutated = mutate(source)
    if mutated == source:
        raise AssertionError(f"source mutation {name!r} changed nothing")
    try:
        validate_source(mutated)
    except AssertionError:
        return
    raise AssertionError(f"source mutation survived validation: {name}")


def validate_mutations(source: str, patch: str, probe: bytes) -> int:
    adjacent = STOPPED_BLOCK + "\n\n" + PENDING_BLOCK
    reversed_order = PENDING_BLOCK + "\n\n" + STOPPED_BLOCK
    mutations: tuple[tuple[str, Callable[[str], str]], ...] = (
        (
            "remove stopped-vout guard",
            lambda value: replace_once(value, STOPPED_BLOCK, "", "stopped guard"),
        ),
        (
            "report stopped output non-empty",
            lambda value: replace_once(
                value,
                STOPPED_BLOCK,
                STOPPED_BLOCK.replace("return true;", "return false;"),
                "stopped return value",
            ),
        ),
        (
            "erase observer invariant",
            lambda value: replace_once(
                value,
                STOPPED_BLOCK,
                STOPPED_BLOCK.replace(
                    "            assert(!Decoder_HasFrameNextObserverLocked(owner));\n",
                    "",
                ),
                "observer assertion",
            ),
        ),
        (
            "erase strict-request invariant",
            lambda value: replace_once(
                value,
                STOPPED_BLOCK,
                STOPPED_BLOCK.replace(
                    "            assert(owner->strict_frame_request_id == 0);\n",
                    "",
                ),
                "strict-request assertion",
            ),
        ),
        (
            "move stopped gate after pending work",
            lambda value: replace_once(
                value, adjacent, reversed_order, "drain branch ordering"
            ),
        ),
        (
            "query vout before lifecycle gate",
            lambda value: replace_once(
                value,
                STOPPED_BLOCK + "\n\n" + PENDING_BLOCK + "\n" + VOUT_QUERY,
                VOUT_QUERY + "\n\n" + STOPPED_BLOCK + "\n\n" + PENDING_BLOCK,
                "query ordering",
            ),
        ),
        (
            "weaken started helper",
            lambda value: replace_once(
                value,
                "return owner->video.vout != NULL && owner->video.started;",
                "return owner->video.vout != NULL;",
                "started helper",
            ),
        ),
        (
            "lose pending strict request",
            lambda value: replace_once(
                value,
                PENDING_BLOCK,
                PENDING_BLOCK.replace(
                    "          || owner->strict_frame_request_id != 0))",
                    "          && owner->strict_frame_request_id != 0))",
                ),
                "pending strict disjunction",
            ),
        ),
        (
            "close admission before cancellation",
            lambda value: replace_once(
                value,
                "    Decoder_CancelStrictFrameLocked(p_owner, 0, 0, true);\n"
                "    vout_configuration_t cfg = {",
                "    vout_configuration_t cfg = {",
                "transition cancellation",
            ),
        ),
        (
            "reopen admission as stopped",
            lambda value: replace_once(
                value,
                "        p_owner->video.started = true;",
                "        p_owner->video.started = false;",
                "successful admission",
            ),
        ),
        (
            "detach replacement without cancellation",
            lambda value: replace_once(
                value,
                "    Decoder_CancelStrictFrameLocked(p_owner, 0, 0, true);\n"
                "    vout_thread_t *p_vout = p_owner->video.vout;",
                "    vout_thread_t *p_vout = p_owner->video.vout;",
                "replacement transition cancellation",
            ),
        ),
    )
    for name, mutate in mutations:
        expect_rejected(source, mutate, name)

    try:
        validate_patch(patch + "\n")
    except AssertionError:
        pass
    else:
        raise AssertionError("0040 patch mutation survived validation")

    mutated_probe = probe + b"\n"
    try:
        validate_probe(mutated_probe)
    except AssertionError:
        pass
    else:
        raise AssertionError("runtime probe mutation survived validation")
    return len(mutations) + 2


def drain_decision(
    *, started: bool, observer: bool, frames: int, strict: int, vout_empty: bool
) -> tuple[bool, bool]:
    """Executable model of the three ordered branches; returns result/called-vout."""
    if not started:
        if observer or strict != 0:
            raise AssertionError("stopped vout retained strict final-output work")
        return True, False
    if not observer and (frames > 0 or strict != 0):
        return False, False
    return vout_empty, True


def validate_state_matrix() -> int:
    cases = (
        (dict(started=False, observer=False, frames=0, strict=0, vout_empty=False), (True, False)),
        (dict(started=False, observer=False, frames=1, strict=0, vout_empty=False), (True, False)),
        (dict(started=True, observer=False, frames=0, strict=0, vout_empty=True), (True, True)),
        (dict(started=True, observer=False, frames=0, strict=0, vout_empty=False), (False, True)),
        (dict(started=True, observer=False, frames=1, strict=0, vout_empty=True), (False, False)),
        (dict(started=True, observer=False, frames=0, strict=7, vout_empty=True), (False, False)),
        (dict(started=True, observer=True, frames=0, strict=0, vout_empty=True), (True, True)),
    )
    for inputs, expected in cases:
        actual = drain_decision(**inputs)
        if actual != expected:
            raise AssertionError(
                f"drain state {inputs!r} produced {actual!r}, expected {expected!r}"
            )
    try:
        drain_decision(started=False, observer=True, frames=0, strict=0,
                       vout_empty=True)
    except AssertionError:
        pass
    else:
        raise AssertionError("stopped-vout observer invariant was not enforced")
    try:
        drain_decision(started=False, observer=False, frames=0, strict=7,
                       vout_empty=True)
    except AssertionError:
        pass
    else:
        raise AssertionError("stopped-vout strict invariant was not enforced")
    return len(cases) + 2


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("patch", type=Path)
    parser.add_argument("probe", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    source_root = arguments.source_root.resolve()
    patch_path = arguments.patch.resolve()
    probe_path = arguments.probe.resolve()
    decoder_path = source_root / DECODER_PATH
    for description, path in (
        ("patched decoder source", decoder_path),
        ("0040 patch", patch_path),
        ("headless teardown probe", probe_path),
    ):
        if not path.is_file():
            raise SystemExit(f"missing {description}: {path}")

    source = decoder_path.read_text(encoding="utf-8")
    patch = patch_path.read_text(encoding="utf-8")
    probe = probe_path.read_bytes()
    validate_source(source)
    validate_patch(patch)
    validate_probe(probe)
    mutations = validate_mutations(source, patch, probe)
    states = validate_state_matrix()
    print(
        "PASS headless vout teardown source proof: "
        f"paths=1 mutations={mutations} states={states} "
        f"patch_sha={EXPECTED_PATCH_SHA256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
