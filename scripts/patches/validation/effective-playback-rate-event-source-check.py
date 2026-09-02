#!/usr/bin/env python3
"""Structural and mutation proof for SwiftVLC's effective-rate event ABI."""

from pathlib import Path
import sys

from pip_extension_version import (
    BASE_SOURCE_KEYS,
    OPTIONAL_SUCCESSOR_SOURCE_KEYS,
    read_source_root,
    resolve_extension_version,
    run_negative_mutations,
)


def extension_sources(sources: dict[str, str]) -> dict[str, str]:
    keys = BASE_SOURCE_KEYS | OPTIONAL_SUCCESSOR_SOURCE_KEYS
    return {key: sources[key] for key in keys}


def function_body(source: str, signature: str) -> str:
    start = -1
    while True:
        start = source.find(signature, start + 1)
        if start < 0:
            raise AssertionError(f"missing function: {signature}")
        opening = source.find("{", start)
        if opening < 0:
            raise AssertionError(f"missing body: {signature}")
        if source.find(";", start, opening) < 0:
            break
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[opening:index + 1]
    raise AssertionError(f"unterminated body: {signature}")


def normalized(source: str) -> str:
    return " ".join(source.split())


def require(source: str, *needles: str) -> None:
    for needle in needles:
        if needle not in source:
            raise AssertionError(f"missing invariant: {needle}")


def forbid(source: str, *needles: str) -> None:
    for needle in needles:
        if needle in source:
            raise AssertionError(f"forbidden invariant: {needle}")


def ordered(source: str, *needles: str) -> None:
    cursor = 0
    for needle in needles:
        position = source.find(needle, cursor)
        if position < 0:
            raise AssertionError(f"missing/out-of-order invariant: {needle}")
        cursor = position + len(needle)


def rate_control_block(source: str) -> str:
    start = source.find("case INPUT_CONTROL_SET_RATE:")
    if start < 0:
        raise AssertionError("missing INPUT_CONTROL_SET_RATE")
    end = source.find("case INPUT_CONTROL_SET_PROGRAM:", start)
    if end < 0:
        raise AssertionError("unterminated INPUT_CONTROL_SET_RATE")
    return source[start:end]


def validate_public_abi(events: str, media_header: str) -> None:
    compact_events = normalized(events)
    compact_header = normalized(media_header)
    ordered(
        compact_events,
        "libvlc_MediaPlayerFrameStepCompleted,",
        "libvlc_MediaPlayerRateChanged,",
        "libvlc_MediaListItemAdded=0x200,",
    )
    require(
        compact_events,
        "struct { float new_rate; } media_player_rate_changed;",
        "effective player control-rate resolution was reported",
        "rate reported by the player at notification time",
        "measured media throughput",
        "queued to an active input",
        "rate remains unchanged",
        "no active input, or when queuing fails",
        "may repeat a previously reported value",
        "Events do not carry request identifiers",
    )
    rate_payload_start = compact_events.index(
        "struct { float new_rate; } media_player_rate_changed;")
    rate_payload_end = compact_events.index(
        "/* ESAdded, ESDeleted, ESUpdated */", rate_payload_start)
    forbid(compact_events[rate_payload_start:rate_payload_end], "request_id")
    require(
        compact_header,
        "Version 7 adds the public",
        "libvlc_MediaPlayerRateChanged event for effective player control-rate",
        "resolution notifications.",
    )


def validate_libvlc_bridge(media_player: str) -> None:
    compact = normalized(media_player)
    require(
        compact,
        "sizeof(((libvlc_event_t *)0)->u) == 24",
        "sizeof(libvlc_event_t) == 40",
        "offsetof(libvlc_event_t, u) == 16",
        "sizeof(((libvlc_event_t *)0)->u.media_player_rate_changed) == 4",
        "u.media_player_rate_changed.new_rate) == 16",
        ".on_rate_changed = on_rate_changed,",
    )
    callback = function_body(media_player, "on_rate_changed(")
    ordered(
        normalized(callback),
        "(void) new_rate;",
        "libvlc_media_player_t *mp = data;",
        ".type = libvlc_MediaPlayerRateChanged,",
        ".u.media_player_rate_changed.new_rate = vlc_player_GetRate(player),",
        "libvlc_event_send(&mp->event_manager, &event);",
    )
    forbid(callback, "request_id", "libvlc_media_player_get_rate")


def validate_core_resolution(player: str, player_header: str,
                             player_input: str, input_control: str) -> None:
    getter = function_body(player, "vlc_player_GetRate(")
    ordered(
        normalized(getter),
        "struct vlc_player_input *input = vlc_player_get_input_locked(player);",
        "if (input) return input->rate;",
        'else return var_GetFloat(player, "rate");',
    )

    request = function_body(player, "vlc_player_ChangeRate(")
    ordered(
        normalized(request),
        'var_SetFloat(player, "rate", rate);',
        "input_ControlPushHelper(input->thread, INPUT_CONTROL_SET_RATE,",
        "vlc_player_SendEvent(player, on_rate_changed, rate);",
    )
    require(
        request,
        "The event is sent from the thread processing the control",
        "else /* Send the event anyway since it's a global state */",
    )

    compact_player_header = normalized(player_header)
    rate_callback_start = compact_player_header.index(
        "Called when the player rate has changed")
    rate_callback_end = compact_player_header.index(
        "on_capabilities_changed", rate_callback_start)
    rate_callback_contract = compact_player_header[
        rate_callback_start:rate_callback_end]
    require(
        rate_callback_contract,
        "@param player locked player instance",
        "void (*on_rate_changed)(vlc_player_t *player, float new_rate, void *data);",
    )

    resolution = normalized(rate_control_block(input_control))
    ordered(
        resolution,
        "float rate = fabsf( param.val.f_float );",
        "rate = INPUT_RATE_MAX;",
        "rate = INPUT_RATE_MIN;",
        'msg_Dbg( p_input, "cannot change rate" ); rate = 1.f;',
        "demux_Control( priv->master->p_demux, DEMUX_SET_RATE, &rate )",
        "rate = priv->rate;",
        "if( rate != priv->rate )",
        "priv->rate = rate;",
        "input_SendEventRate( p_input, rate );",
    )

    delivery = function_body(player_input, "input_thread_Events(")
    ordered(
        normalized(delivery),
        "case INPUT_EVENT_RATE:",
        "input->rate = event->rate;",
        "vlc_player_SendEvent(player, on_rate_changed, input->rate);",
    )


def validate_all(sources: dict[str, str]) -> int:
    resolution = resolve_extension_version(extension_sources(sources))
    if resolution.version < 7:
        raise AssertionError(
            "effective-rate event requires extension version 7 or newer")
    validate_public_abi(sources["events"], sources["media_header"])
    validate_libvlc_bridge(sources["media_player"])
    validate_core_resolution(
        sources["player"], sources["player_header"],
        sources["player_input"], sources["input_control"])
    return resolution.version


def require_mutation_rejected(sources: dict[str, str], key: str,
                              old: str, new: str, description: str) -> None:
    if old not in sources[key]:
        raise AssertionError(f"cannot construct mutation: {description}")
    candidate = dict(sources)
    candidate[key] = candidate[key].replace(old, new, 1)
    try:
        validate_all(candidate)
    except AssertionError:
        return
    raise AssertionError(f"mutation escaped source gate: {description}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <patched-vlc-source>", file=sys.stderr)
        return 2
    root = Path(sys.argv[1]).resolve()
    paths = {
        "events": root / "include/vlc/libvlc_events.h",
        "media_header": root / "include/vlc/libvlc_media_player.h",
        "media_player": root / "lib/media_player.c",
        "exports": root / "lib/libvlc.sym",
        "player": root / "src/player/player.c",
        "player_header": root / "include/vlc_player.h",
        "player_input": root / "src/player/input.c",
        "input_control": root / "src/input/input.c",
    }
    for path in paths.values():
        if not path.is_file():
            raise AssertionError(f"missing effective-rate source input: {path}")
    sources = {name: path.read_text() for name, path in paths.items()}
    sources.update(read_source_root(root))
    integrated_extension_version = validate_all(sources)

    require_mutation_rejected(
        sources, "events",
        "libvlc_MediaPlayerRateChanged,",
        "libvlc_MediaPlayerRateChanged = libvlc_MediaPlayerRecordChanged,",
        "append-only event identity aliased an existing public event")
    require_mutation_rejected(
        sources, "events", "float new_rate;", "double new_rate;",
        "effective-rate payload grew the released event envelope")
    require_mutation_rejected(
        sources, "media_player",
        ".on_rate_changed = on_rate_changed,",
        ".on_rate_changed = NULL,",
        "libVLC listener dropped the core rate callback")
    require_mutation_rejected(
        sources, "media_player",
        ".u.media_player_rate_changed.new_rate = vlc_player_GetRate(player),",
        ".u.media_player_rate_changed.new_rate = new_rate,",
        "event payload exposed a requested/global callback value instead of "
        "the authoritative effective getter")
    require_mutation_rejected(
        sources, "media_player",
        ".type = libvlc_MediaPlayerRateChanged,",
        ".type = libvlc_MediaPlayerFrameStepCompleted,",
        "callback emitted the wrong public event identity")
    require_mutation_rejected(
        sources, "player_input",
        "vlc_player_SendEvent(player, on_rate_changed, input->rate);",
        "vlc_player_SendEvent(player, on_rate_changed, 1.f);",
        "libVLC bridge ignored the input-resolved rate")
    require_mutation_rejected(
        sources, "input_control",
        "input_SendEventRate( p_input, rate );",
        "input_SendEventRate( p_input, param.val.f_float );",
        "input published the requested rather than resolved rate")

    run_negative_mutations(
        extension_sources(sources), integrated_extension_version)

    print("PASS effective playback-rate event source and mutation contract "
          f"(integrated extension version {integrated_extension_version})")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"FAIL effective playback-rate event contract: {error}",
              file=sys.stderr)
        raise SystemExit(1)
