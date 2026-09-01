#!/usr/bin/env python3
"""Structural proof for SwiftVLC's audited post-pin stability backports.

The linked native probe runs VLC's real JSON parser, json_get_str(), URL
composer, and the Cast helpers used by production. This checker additionally
binds those helpers to every production call site and rejects regressions that
could otherwise leave the probe green while runtime code bypasses the policy.
"""

from pathlib import Path
import re
import sys

RESTORE_ARTWORK_STATEMENT = re.compile(r"\brestoreHttpArtwork\s*\(\s*\)\s*;")
CLEAR_ARTWORK_ROUTE_STATEMENT = re.compile(
    r"\bm_art_http_ip\s*\.\s*clear\s*\(\s*\)\s*;"
)
DEMUX_DURATION_QUERY_STATEMENT = re.compile(
    r"\bm_length\s*=\s*chromecast_query_demux_input_length\s*\(\s*"
    r"\[\s*this\s*\]\s*\(\s*vlc_tick_t\s*\*\s*duration\s*,\s*"
    r"bool\s*\*\s*live\s*\)\s*\{\s*return\s+demux_Control\s*\(\s*"
    r"p_demux\s*->\s*s\s*,\s*DEMUX_GET_LENGTH\s*,\s*duration\s*,\s*"
    r"live\s*\)\s*;\s*\}\s*\)\s*;",
    re.MULTILINE,
)
STREAM_URL_STATEMENT = re.compile(
    r"\bconst\s+std::string\s+chromecast_url\s*=\s*"
    r"chromecast_stream_url\s*\(\s*server_base_url\s*,\s*m_serverPath\s*,\s*"
    r"stream_token\s*\)\s*;"
)
MEDIA_FIELDS_STATEMENT = re.compile(
    r"\bconst\s+std::string\s+media_fields\s*=\s*"
    r"chromecast_media_fields\s*\(\s*chromecast_url\s*,\s*mime\s*,\s*"
    r"input_length\s*\)\s*;"
)
GET_MEDIA_STATEMENT = re.compile(
    r"\bconst\s+std::string\s+media\s*=\s*GetMedia\s*\(\s*stream_token\s*,\s*"
    r"mime\s*,\s*p_meta\s*,\s*input_length\s*\)\s*;"
)
LOAD_PAYLOAD_STATEMENT = re.compile(
    r"\bconst\s+std::string\s+payload\s*=\s*"
    r"chromecast_load_payload\s*\(\s*media\s*,\s*id\s*\)\s*;"
)
PREPARE_ARTWORK_PREFIX = re.compile(
    r"\bassert\s*\(\s*published_url\s*!=\s*NULL\s*\)\s*;\s*"
    r"published_url\s*->\s*clear\s*\(\s*\)\s*;\s*"
    r"if\s*\(\s*!queuedInputCanCommit\s*\(\s*generation\s*,\s*"
    r"stream_token\s*\)\s*\)\s*return\s+false\s*;"
)
FINAL_TRUE_RETURN = re.compile(r"\breturn\s+true\s*;\s*\}\s*$")
TRY_LOAD_LOOP = re.compile(r"\bfor\s*\(\s*;\s*;\s*\)\s*\{")
TRY_LOAD_COMMIT_PIPELINE = re.compile(
    r"\bconst\s+unsigned\s+request_id\s*=\s*"
    r"m_communication\s*->\s*msgPlayerLoad\s*\(\s*m_appTransportId\s*,\s*"
    r"stream_token\s*,\s*m_mime\s*,\s*m_meta\s*,\s*m_input_length\s*\)\s*;\s*"
    r"m_load_commit_in_progress\s*=\s*false\s*;\s*"
    r"if\s*\(\s*recordMediaRequest\s*\(\s*chromecast_media_command::Load\s*,\s*"
    r"request_id\s*\)\s*\)\s*\{\s*m_state\s*=\s*Loading\s*;\s*"
    r"armStateDeadline\s*\(\s*Loading\s*\)\s*;\s*"
    r"updateProgressWatchdog\s*\(\s*Loading\s*\)\s*;\s*\}\s*"
    r"else\s+setState\s*\(\s*LoadFailed\s*\)\s*;\s*return\s*;"
)
DEMUX_DURATION_PUBLICATION = re.compile(
    r"\bm_length\s*=\s*chromecast_query_demux_input_length\s*\(\s*"
    r"\[\s*this\s*\]\s*\(\s*vlc_tick_t\s*\*\s*duration\s*,\s*"
    r"bool\s*\*\s*live\s*\)\s*\{\s*return\s+demux_Control\s*\(\s*"
    r"p_demux\s*->\s*s\s*,\s*DEMUX_GET_LENGTH\s*,\s*duration\s*,\s*"
    r"live\s*\)\s*;\s*\}\s*\)\s*;\s*"
    r"p_renderer\s*->\s*pf_set_input_length\s*\(\s*p_renderer\s*->\s*"
    r"p_opaque\s*,\s*m_generation\s*,\s*m_length\s*\)\s*;",
    re.MULTILINE,
)
DEMUX_INIT_TERMINAL_RESET = re.compile(
    r"\bresetTimes\s*\(\s*\)\s*;\s*\}\s*$"
)
ALWAYS_TAKEN_GUARDED_TRANSFER = re.compile(
    r"if\s*\(\s*(?:true|1|!\s*false)\s*\)\s*"
    r"(?:\{\s*)?(return|throw|goto)\b"
)

EXPECTED_GET_MEDIA_SUFFIX = (
    "conststd::stringserver_base_url=getServerBaseURL();"
    "if(server_base_url.empty()){msg_Err(m_module,"
    '"RefusingtopublishanunreachableChromecastURL");return{};}'
    "conststd::stringchromecast_url=chromecast_stream_url("
    "server_base_url,m_serverPath,stream_token);"
    "if(chromecast_url.empty()){msg_Err(m_module,"
    '"RefusingtopublishanunownedChromecaststream");return{};}'
    'msg_Dbg(m_module,"s_chromecast_url:%s",chromecast_url.c_str());'
    "conststd::stringmedia_fields=chromecast_media_fields("
    "chromecast_url,mime,input_length);"
    "if(media_fields.empty())return{};"
    "ss<<media_fields;returnss.str();}"
)
EXPECTED_PLAYER_LOAD_BODY = (
    "{unsignedid=getNextRequestId();"
    "conststd::stringmedia=GetMedia(stream_token,mime,p_meta,input_length);"
    "if(media.empty())returnkInvalidId;"
    "conststd::stringpayload=chromecast_load_payload(media,id);"
    "if(payload.empty())returnkInvalidId;"
    "std::stringstreamss(payload);"
    "returnpushMediaPlayerMessage(destinationId,ss)==VLC_SUCCESS?"
    "id:kInvalidId;}"
)
EXPECTED_SET_META_BODY = (
    "{vlc::threads::mutex_lockerlock(m_lock);vlc_meta_t**slot;"
    "if(generation!=0&&generation==m_pending_input_generation&&"
    "m_pending_input_owner_live)slot=&m_pending_meta;"
    "elseif(generation!=0&&generation==m_active_input_generation&&"
    "m_active_input_owner_live)slot=&m_meta;else{if(p_meta!=NULL)"
    "vlc_meta_Delete(p_meta);returnfalse;}if(*slot!=NULL)"
    "vlc_meta_Delete(*slot);*slot=p_meta;if(slot==&m_meta)"
    "m_art_http_url.clear();returntrue;}"
)
EXPECTED_SET_LENGTH_BODY = (
    "{vlc::threads::mutex_lockerlock(m_lock);"
    "if(generation!=0&&generation==m_pending_input_generation&&"
    "m_pending_input_owner_live){m_pending_input_length=length;"
    "returntrue;}if(generation!=0&&generation==m_active_input_generation&&"
    "m_active_input_owner_live){m_input_length=length;returntrue;}"
    "returnfalse;}"
)


def function_body(source: str, signature: str) -> str:
    start = -1
    while True:
        start = source.find(signature, start + 1)
        if start < 0:
            raise AssertionError(f"missing function: {signature}")
        opening = source.find("{", start)
        if opening < 0:
            raise AssertionError(f"missing body: {signature}")
        semicolon = source.find(";", start, opening)
        if semicolon < 0:
            break

    depth = 0
    for index in range(opening, len(source)):
        character = source[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[opening : index + 1]
    raise AssertionError(f"unterminated body: {signature}")


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
    raise AssertionError(f"unterminated body: {description}")


def ordered(body: str, *needles: str) -> None:
    cursor = 0
    for needle in needles:
        position = body.find(needle, cursor)
        if position < 0:
            raise AssertionError(f"missing/out-of-order invariant: {needle}")
        cursor = position + len(needle)


def require(body: str, *needles: str) -> None:
    for needle in needles:
        if needle not in body:
            raise AssertionError(f"missing invariant: {needle}")


def require_count(body: str, needle: str, expected: int) -> None:
    actual = body.count(needle)
    if actual != expected:
        raise AssertionError(
            f"invariant count changed for {needle!r}: expected {expected}, got {actual}"
        )


def forbid(body: str, *needles: str) -> None:
    for needle in needles:
        if needle in body:
            raise AssertionError(f"forbidden invariant: {needle}")


def forbid_regex(body: str, pattern: str, description: str) -> None:
    if re.search(pattern, body, re.MULTILINE | re.DOTALL) is not None:
        raise AssertionError(f"forbidden invariant: {description}")


def read(root: Path, relative: str) -> str:
    path = root / relative
    if not path.is_file():
        raise AssertionError(f"missing source file: {relative}")
    return path.read_text()


def without_cpp_comments(source: str) -> str:
    """Remove C/C++ comments without treating comment markers in literals as code."""

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
                raise AssertionError("unterminated C/C++ comment")
            result.extend(
                "\n" for character in source[index:closing] if character == "\n"
            )
            index = closing + 2
            continue
        result.append(character)
        index += 1
    return "".join(result)


def compact_cpp(source: str) -> str:
    return re.sub(r"\s+", "", without_cpp_comments(source))


def require_exact_compact(body: str, expected: str, description: str) -> None:
    if compact_cpp(body) != expected:
        raise AssertionError(f"{description} must remain an exact reachable pipeline")


def require_exact_compact_suffix(
    body: str, expected: str, description: str
) -> None:
    if not compact_cpp(body).endswith(expected):
        raise AssertionError(f"{description} must remain an exact reachable pipeline")


def direct_statement_match(
    body: str,
    pattern: re.Pattern[str],
    description: str,
    *,
    reject_prior_transfer: bool = False,
) -> re.Match[str]:
    """Require one literal, unconditional statement in the function's outer body.

    This is deliberately stricter than token ordering. A helper hidden in an
    ``if (false)``, placed after an unconditional transfer, or retained next to
    a different production return must not satisfy a release gate.
    """

    source = without_cpp_comments(body)
    matches = list(pattern.finditer(source))
    if len(matches) != 1:
        raise AssertionError(
            f"{description} must occur exactly once as a production statement; "
            f"found {len(matches)}"
        )
    match = matches[0]

    brace_depth = 0
    paren_depth = 0
    bracket_depth = 0
    statement_boundary = 0
    prior_top_level_transfers: list[str] = []
    index = 0
    quote: str | None = None
    while index < match.start():
        character = source[index]
        if quote is not None:
            if character == "\\" and index + 1 < match.start():
                index += 2
                continue
            if character == quote:
                quote = None
            index += 1
            continue
        if character in ('"', "'"):
            quote = character
            index += 1
            continue
        if character == "{":
            brace_depth += 1
            if brace_depth == 1 and paren_depth == 0 and bracket_depth == 0:
                statement_boundary = index + 1
        elif character == "}":
            brace_depth -= 1
            if brace_depth == 1 and paren_depth == 0 and bracket_depth == 0:
                statement_boundary = index + 1
        elif character == "(":
            paren_depth += 1
        elif character == ")":
            paren_depth -= 1
        elif character == "[":
            bracket_depth += 1
        elif character == "]":
            bracket_depth -= 1
        elif (
            character == ";"
            and brace_depth == 1
            and paren_depth == 0
            and bracket_depth == 0
        ):
            statement_boundary = index + 1
        elif (
            (character.isalpha() or character == "_")
            and brace_depth == 1
            and paren_depth == 0
            and bracket_depth == 0
        ):
            end = index + 1
            while end < match.start() and (source[end].isalnum() or source[end] == "_"):
                end += 1
            identifier = source[index:end]
            if (
                identifier == "if"
                and not source[statement_boundary:index].strip()
            ):
                guarded_transfer = ALWAYS_TAKEN_GUARDED_TRANSFER.match(
                    source, index
                )
                if guarded_transfer is not None:
                    prior_top_level_transfers.append(
                        "always-taken guarded " + guarded_transfer.group(1)
                    )
            # Only a transfer that begins its outer-body statement is
            # unconditional here. An unbraced guard such as
            # ``if (media.empty()) return kInvalidId;`` is intentionally
            # accepted because it does not make all later code unreachable.
            # Statically always-taken guards are recorded above as equivalent
            # to a direct outer-body transfer.
            if (
                identifier in ("return", "throw", "goto")
                and not source[statement_boundary:index].strip()
            ):
                prior_top_level_transfers.append(identifier)
            index = end
            continue
        index += 1

    if (brace_depth, paren_depth, bracket_depth) != (1, 0, 0):
        raise AssertionError(
            f"{description} is nested in a conditional, loop, lambda, or macro"
        )
    if source[statement_boundary : match.start()].strip():
        raise AssertionError(
            f"{description} is guarded, labelled, preprocessor-disabled, or detached"
        )
    if reject_prior_transfer and prior_top_level_transfers:
        raise AssertionError(
            f"{description} follows a top-level control transfer: "
            f"{prior_top_level_transfers[-1]}"
        )
    return match


def require_direct_return_wrapper(body: str, expression: str, description: str) -> None:
    expected = "{return" + compact_cpp(expression) + ";}"
    if compact_cpp(body) != expected:
        raise AssertionError(
            f"{description} must be the function's sole direct return expression"
        )


def validate(root: Path) -> None:
    player_input = read(root, "src/player/input.c")
    player = read(root, "src/player/player.c")
    timer = read(root, "src/player/timer.c")
    player_header = read(root, "src/player/player.h")
    decoder = read(root, "src/input/decoder.c")
    decoder_helpers = read(root, "src/input/decoder_helpers.c")
    transcode = read(root, "modules/stream_out/transcode/transcode.h")
    cast_header = read(root, "modules/stream_out/chromecast/chromecast.h")
    cast_common = read(root, "modules/stream_out/chromecast/chromecast_common.h")
    cast_protocol = read(root, "modules/stream_out/chromecast/chromecast_protocol.hpp")
    cast_duration = read(
        root, "modules/stream_out/chromecast/chromecast_demux_duration.hpp"
    )
    cast_communication = read(
        root, "modules/stream_out/chromecast/chromecast_communication.cpp"
    )
    cast_control = read(root, "modules/stream_out/chromecast/chromecast_ctrl.cpp")
    cast_demux = read(root, "modules/stream_out/chromecast/chromecast_demux.cpp")
    stream_makefile = read(root, "modules/stream_out/Makefile.am")
    cast_meson = read(root, "modules/stream_out/chromecast/meson.build")
    upnp_header = read(root, "modules/services_discovery/upnp-wrapper.hpp")
    upnp_source = read(root, "modules/services_discovery/upnp-wrapper.cpp")

    load_transition_markers = (
        "chromecast_stream_url(" in cast_protocol,
        "cc_stream_token_t stream_token" in cast_header,
        "cc_input_generation_t" in cast_common,
        "m_pending_input_generation" in cast_control,
        "m_generation" in cast_demux,
    )
    if any(load_transition_markers) and not all(load_transition_markers):
        raise AssertionError(
            "partial 0037 load-transition source markers; refusing to select "
            "either final or predecessor post-pin contract"
        )
    load_transition_contract = all(load_transition_markers)

    # Patch 0025 has three explicit singleton states. The last owner publishes
    # TearingDown under s_lock, destroys outside it so libupnp callbacks can
    # reenter, and only then clears the state and wakes waiting get() calls.
    require(
        upnp_header,
        "enum class InstanceState",
        "Absent,",
        "Live,",
        "TearingDown,",
        "static InstanceState s_state;",
        "static vlc::threads::condition_variable s_state_changed;",
    )
    require(
        upnp_source,
        "UpnpInstanceWrapper::InstanceState::Absent",
        "vlc::threads::condition_variable UpnpInstanceWrapper::s_state_changed;",
    )
    upnp_get = function_body(upnp_source, "UpnpInstanceWrapper::get(")
    ordered(
        upnp_get,
        "vlc::threads::mutex_locker lock( s_lock );",
        "while ( s_state == InstanceState::TearingDown )",
        "s_state_changed.wait( s_lock );",
        "s_state == InstanceState::Absent",
        "s_instance = instance;",
        "s_state = InstanceState::Live;",
        "s_instance->m_refcount++;",
    )
    upnp_release = function_body(upnp_source, "UpnpInstanceWrapper::release(")
    ordered(
        upnp_release,
        "vlc::threads::mutex_locker lock( s_lock );",
        "s_instance == this && m_refcount > 0",
        "--m_refcount == 0",
        "s_instance = NULL;",
        "s_state = InstanceState::TearingDown;",
        "delete p_delete;",
        "s_state = InstanceState::Absent;",
        "s_state_changed.broadcast();",
    )
    require_count(upnp_release, "delete p_delete;", 1)
    require_count(upnp_release, "s_state = InstanceState::TearingDown;", 1)
    require_count(upnp_release, "s_state = InstanceState::Absent;", 1)
    require_count(upnp_release, "s_state_changed.broadcast();", 1)
    require_count(upnp_release, "vlc::threads::mutex_locker lock( s_lock );", 2)
    release_delete = upnp_release.index("delete p_delete;")
    release_teardown = upnp_release.index("s_state = InstanceState::TearingDown;")
    transition_scope_end = upnp_release.find("\n    }", release_teardown)
    if transition_scope_end < 0 or transition_scope_end > release_delete:
        raise AssertionError("UPnP last delete still occurs while s_lock is held")
    upnp_destructor = function_body(
        upnp_source, "UpnpInstanceWrapper::~UpnpInstanceWrapper("
    )
    require(upnp_destructor, "UpnpFinish();")
    upnp_callback = function_body(upnp_source, "UpnpInstanceWrapper::Callback(")
    require(upnp_callback, "vlc::threads::mutex_locker lock( s_lock );")

    # ef2f3434 is the valid resume epoch consumed by patch 0014's stale-pause
    # filter. Resetting pause_date first and forwarding it would turn PLAYING
    # events back into INVALID and revive the stale notification race.
    handle_state = function_body(player_input, "vlc_player_input_HandleState(")
    ordered(
        handle_state,
        "case VLC_PLAYER_STATE_PLAYING:",
        "input->pause_date = VLC_TICK_INVALID;",
        "vlc_player_SignalAtoBLoop(player);",
        "VLC_PLAYER_TIMER_EVENT_PLAYING,",
        "state_date);",
        "case VLC_PLAYER_STATE_PAUSED:",
        "input->pause_date = state_date;",
        "vlc_player_SignalAtoBLoop(player);",
        "VLC_PLAYER_TIMER_EVENT_PAUSED,",
        "input->pause_date);",
    )
    playing_case = handle_state[
        handle_state.index("case VLC_PLAYER_STATE_PLAYING:") : handle_state.index(
            "case VLC_PLAYER_STATE_STARTED:"
        )
    ]
    forbid_regex(
        playing_case,
        r"VLC_PLAYER_TIMER_EVENT_PLAYING\s*,\s*input->pause_date",
        "PLAYING forwarded with cleared pause_date",
    )

    update_timer = function_body(timer, "vlc_player_UpdateTimerEvent(")
    require(
        player_header,
        "vlc_tick_t last_resume_date;",
        "vlc_tick_t reported_pause_date;",
    )
    ordered(
        update_timer,
        "case VLC_PLAYER_TIMER_EVENT_PAUSED:",
        "player->timer.last_resume_date == VLC_TICK_INVALID",
        "system_date >= player->timer.last_resume_date",
        "case VLC_PLAYER_TIMER_EVENT_PLAYING:",
        "player->timer.last_resume_date = system_date;",
        "player->timer.update_state = UPDATE_STATE_RESUMING;",
    )

    # 0ab833bf + f573990: pausing cannot spin on the A-B deadline, state
    # changes wake the policy, and installing a loop that already contains the
    # playhead does not issue a gratuitous seek back to A.
    deadline = function_body(player, "vlc_player_GetAtoBLoopDeadline(")
    require(deadline, "input->pause_date != VLC_TICK_INVALID", "return VLC_TICK_MIN;")
    set_loop_time = function_body(player, "vlc_player_SetAtoBLoopTime(")
    ordered(
        set_loop_time,
        "vlc_player_input_GetTime(input, false, vlc_tick_now())",
        "current == VLC_TICK_INVALID || current < a_time || current > b_time",
        "vlc_player_SetTime(player, a_time);",
    )
    set_loop_position = function_body(player, "vlc_player_SetAtoBLoopPosition(")
    ordered(
        set_loop_position,
        "vlc_player_input_GetPos(input, false, vlc_tick_now())",
        "current < a_pos || current > b_pos",
        "vlc_player_SetPosition(player, a_pos);",
    )

    # 2b807d98 + 2febc748: decoder_Clean unloads a module that may still read
    # fmt_in, so decoder/packetizer unload must precede owner format teardown.
    decoder_clean = function_body(decoder_helpers, "void decoder_Clean(")
    ordered(
        decoder_clean,
        "module_unneed(p_dec, p_dec->p_module);",
        "p_dec->p_module = NULL;",
        "es_format_Clean( &p_dec->fmt_out );",
    )
    transcode_delete = function_body(transcode, "static inline void dec_Delete(")
    ordered(
        transcode_delete,
        "decoder_Clean(p_dec);",
        "es_format_Clean( &p_owner->fmt_in );",
        "vlc_object_delete(p_dec);",
    )
    forbid(transcode_delete, "decoder_Destroy(")

    input_delete = function_body(decoder, "static void DeleteDecoder(")
    ordered(
        input_delete,
        "decoder_Clean( p_dec );",
        "if( p_owner->p_packetizer != NULL )",
        "decoder_Clean( p_owner->p_packetizer );",
        "es_format_Clean( &p_owner->dec_fmt_in );",
        "es_format_Clean( &p_owner->pktz_fmt_in );",
        "block_FifoRelease( p_owner->p_fifo );",
        "if( p_owner->p_packetizer != NULL )",
        "vlc_object_delete( p_owner->p_packetizer );",
        "vlc_object_delete( &p_owner->dec );",
    )
    forbid(input_delete, "decoder_Destroy(")

    # Exact cast sequence:
    # de592342 -> 8fbd8560 -> 37afe71 -> 5efe99a -> 8bc99a6 -> 39e7668.
    # The helper is an actual production wrapper over VLC's json_get_str, not
    # a probe-only JSON model, and every namespace dispatch uses it.
    require(
        cast_protocol,
        '#include "../../demux/json/json.h"',
        "json_get_str_view(",
        "json_get_str(object, key)",
        'value != NULL ? value : ""',
    )
    forbid(cast_control, "static inline std::string_view json_get_str_view")
    require(cast_control, '#include "chromecast_protocol.hpp"')
    for signature in (
        "bool intf_sys_t::processHeartBeatMessage(",
        "bool intf_sys_t::processReceiverMessage(",
        "bool intf_sys_t::processMediaMessage(",
        "void intf_sys_t::processConnectionMessage(",
    ):
        require(
            function_body(cast_control, signature),
            'json_get_str_view(entry, "type")',
        )

    # Direct std::string/string_view construction from nullable json_get_str
    # is precisely the UB fixed by 37afe. Keep this broad enough to reject
    # assignment, direct construction, and brace construction variants.
    forbid_regex(
        cast_control,
        r"std::string(?:_view)?(?:\s+[A-Za-z_]\w*)?\s*(?:=|\(|\{)\s*json_get_str\s*\(",
        "nullable json_get_str used to construct a C++ string/view",
    )

    process_connection = function_body(
        cast_control, "void intf_sys_t::processConnectionMessage("
    )
    ordered(process_connection, 'json_get_str_view(entry, "type")', 'type == "CLOSE"')
    forbid(process_connection, "json_get(entry", "msg.payload_utf8()")

    require(
        stream_makefile,
        "chromecast/chromecast_demux_duration.hpp",
        "chromecast/chromecast_protocol.hpp",
    )
    require(cast_meson, "chromecast_demux_duration.hpp", "chromecast_protocol.hpp")

    # 5efe99a URL formatting is now fail-closed: interface-scoped or
    # link-local addresses are not receiver-reachable identifiers and must
    # never reach artwork metadata, contentId, or LOAD.
    ipv4_policy = function_body(cast_protocol, "chromecast_ipv4_is_publishable(")
    ordered(
        ipv4_policy,
        "ntohl(address.s_addr)",
        "value != INADDR_ANY",
        "0xff000000",
        "0x7f000000",
        "!IN_MULTICAST(value)",
    )
    require_count(ipv4_policy, "return ", 1)
    publishable = function_body(cast_protocol, "chromecast_server_host_is_publishable(")
    ordered(
        publishable,
        "host.empty()",
        "host.find('%')",
        "inet_pton(AF_INET, host.c_str(), &ipv4)",
        "return chromecast_ipv4_is_publishable(ipv4);",
        "inet_pton(AF_INET6, host.c_str(), &ipv6)",
        "IN6_IS_ADDR_V4MAPPED(&ipv6)",
        "std::memcpy(&ipv4, &ipv6.s6_addr[12], sizeof(ipv4));",
        "return chromecast_ipv4_is_publishable(ipv4);",
        "IN6_IS_ADDR_UNSPECIFIED(&ipv6)",
        "IN6_IS_ADDR_LOOPBACK(&ipv6)",
        "IN6_IS_ADDR_LINKLOCAL(&ipv6)",
        "IN6_IS_ADDR_MULTICAST(&ipv6)",
    )
    require_count(publishable, "return ", 5)
    base_helper = function_body(cast_protocol, "chromecast_server_base_url(")
    ordered(
        base_helper,
        "chromecast_server_host_is_publishable(host)",
        "return {};",
        'components.psz_protocol = const_cast<char *>("http");',
        "components.psz_host = const_cast<char *>(host.c_str());",
        "components.i_port = port;",
        "vlc_uri_compose(&components)",
    )
    base_url = function_body(
        cast_communication, "ChromecastCommunication::getServerBaseURL() const"
    )
    require_direct_return_wrapper(
        base_url,
        "chromecast_server_base_url(m_serverIp, m_serverPort)",
        "ChromecastCommunication::getServerBaseURL",
    )

    artwork_url = function_body(cast_protocol, "chromecast_artwork_url(")
    ordered(artwork_url, "base_url.empty()", "path.empty()", "return base_url + path;")
    artwork_restore = function_body(
        cast_protocol, "chromecast_restore_wrapped_artwork_url("
    )
    ordered(
        artwork_restore,
        "!source_url.empty()",
        "!published_url.empty()",
        "current_url == published_url",
        "return source_url;",
        "return current_url;",
    )

    constructor = function_body(
        cast_communication, "ChromecastCommunication::ChromecastCommunication("
    )
    ordered(
        constructor,
        "net_GetSockAddress( vlc_tls_GetFD(m_tls), psz_localIP, NULL )",
        "chromecast_server_host_is_publishable(psz_localIP)",
        "vlc_tls_Close(m_tls);",
        "m_tls = NULL;",
        "m_serverIp = psz_localIP;",
    )

    get_media = function_body(
        cast_communication, "std::string ChromecastCommunication::GetMedia("
    )
    if load_transition_contract:
        ordered(
            get_media,
            "const std::string server_base_url = getServerBaseURL();",
            "if (server_base_url.empty())",
            "return {};",
            "const std::string chromecast_url = chromecast_stream_url(",
            "server_base_url, m_serverPath, stream_token);",
            "if (chromecast_url.empty())",
            "return {};",
            "chromecast_media_fields(chromecast_url, mime, input_length)",
            "if (media_fields.empty())",
            "return {};",
        )
        direct_statement_match(
            get_media,
            STREAM_URL_STATEMENT,
            "token-bound Chromecast stream URL",
            reject_prior_transfer=True,
        )
        direct_statement_match(
            get_media,
            MEDIA_FIELDS_STATEMENT,
            "token-bound Chromecast media fields",
            reject_prior_transfer=True,
        )
        require_exact_compact_suffix(
            get_media,
            EXPECTED_GET_MEDIA_SUFFIX,
            "GetMedia token URL, media fields, and publication",
        )
        forbid(
            get_media,
            "getServerBaseURL() + m_serverPath",
            "server_base_url + m_serverPath",
            "chromecast_stream_url(server_base_url, m_serverPath, 1)",
        )
    else:
        ordered(
            get_media,
            "const std::string server_base_url = getServerBaseURL();",
            "if (server_base_url.empty())",
            "return {};",
            "const std::string chromecast_url = server_base_url + m_serverPath;",
            "chromecast_media_fields(chromecast_url, mime, input_length)",
            "if (media_fields.empty())",
            "return {};",
        )
        forbid(get_media, "getServerBaseURL() + m_serverPath")

    media_fields = function_body(cast_protocol, "chromecast_media_fields(")
    ordered(
        media_fields,
        "if (content_id.empty())",
        "return {};",
        "chromecast_stream_type(input_length)",
        "if (buffered)",
        "secf_from_vlc_tick(input_length)",
    )
    stream_type = function_body(cast_protocol, "chromecast_stream_type(")
    ordered(
        stream_type,
        "input_length > VLC_TICK_0",
        'return "BUFFERED";',
        "input_length == INPUT_DURATION_INDEFINITE",
        'return "LIVE";',
        'return "NONE";',
    )

    load_helper = function_body(cast_protocol, "chromecast_load_payload(")
    ordered(
        load_helper,
        "if (media.empty())",
        "return {};",
        '"{\\"type\\":\\"LOAD\\",',
    )
    player_load = function_body(
        cast_communication, "unsigned ChromecastCommunication::msgPlayerLoad("
    )
    if load_transition_contract:
        ordered(
            player_load,
            "const std::string media = GetMedia(stream_token, mime, p_meta,",
            "input_length);",
            "if (media.empty())",
            "return kInvalidId;",
            "chromecast_load_payload(media, id)",
            "if (payload.empty())",
            "return kInvalidId;",
            "pushMediaPlayerMessage(",
        )
        direct_statement_match(
            player_load,
            GET_MEDIA_STATEMENT,
            "stream-token GetMedia call",
            reject_prior_transfer=True,
        )
        direct_statement_match(
            player_load,
            LOAD_PAYLOAD_STATEMENT,
            "LOAD payload construction",
            reject_prior_transfer=True,
        )
        require_exact_compact(
            player_load,
            EXPECTED_PLAYER_LOAD_BODY,
            "msgPlayerLoad owned-token/fail-closed send and request-id binding",
        )
    else:
        ordered(
            player_load,
            "const std::string media = GetMedia(mime, p_meta, input_length);",
            "if (media.empty())",
            "return kInvalidId;",
            "chromecast_load_payload(media, id)",
            "if (payload.empty())",
            "return kInvalidId;",
            "pushMediaPlayerMessage(",
        )
    forbid(
        cast_header
        + cast_common
        + cast_protocol
        + cast_communication
        + cast_control
        + cast_demux,
        "autoplay",
    )

    require(
        cast_header,
        "void restoreHttpArtwork();",
        "std::string       m_art_http_url;",
    )
    restore_artwork = function_body(
        cast_control, "void intf_sys_t::restoreHttpArtwork("
    )
    ordered(
        restore_artwork,
        "chromecast_restore_wrapped_artwork_url(",
        'm_art_url != NULL ? m_art_url : ""',
        "m_art_http_url",
        "vlc_meta_Set(m_meta, vlc_meta_ArtworkURL, restored.c_str());",
        "m_art_http_url.clear();",
    )
    if load_transition_contract:
        prepare_artwork = function_body(
            cast_control, "bool intf_sys_t::prepareHttpArtwork("
        )
        direct_statement_match(
            prepare_artwork,
            PREPARE_ARTWORK_PREFIX,
            "artwork generation/token commit prefix",
            reject_prior_transfer=True,
        )
        direct_statement_match(
            prepare_artwork,
            FINAL_TRUE_RETURN,
            "artwork transaction terminal publication",
            reject_prior_transfer=True,
        )
        ordered(
            prepare_artwork,
            "if (!queuedInputCanCommit(generation, stream_token))",
            "return false;",
            "if (m_art_http_ip.empty())",
            "return true;",
            "const std::string source_artwork(psz_art);",
            "new (std::nothrow) chromecast_artwork_file_sys_t{",
            "this, source_artwork}",
            "const std::string route = m_art_http_ip;",
            "m_lock.unlock();",
            "httpd_FileNew(",
            "m_lock.lock();",
            "const bool transaction_valid = queuedInputCanCommit(",
            "generation, stream_token)",
            "source_artwork == current_artwork;",
            "m_httpd_file = candidate;",
            "m_httpd_file_sys = candidate_file_sys;",
            "m_art_url = replacement_art_url;",
            "chromecast_artwork_url(m_art_http_ip, ss_art_idx.str())",
            "if (published.empty())",
            "return true;",
            "if (meta == NULL || !queuedInputCanCommit(generation, stream_token))",
            "return false;",
            "vlc_meta_Set(meta, vlc_meta_ArtworkURL, published.c_str());",
            "*published_url = published;",
            "return true;",
        )
        require_count(prepare_artwork, "chromecast_artwork_url(", 1)
        require_count(prepare_artwork, "m_art_url = replacement_art_url;", 1)
        require_count(prepare_artwork, "*published_url = published;", 1)
    else:
        prepare_artwork = function_body(
            cast_control, "void intf_sys_t::prepareHttpArtwork("
        )
        ordered(
            prepare_artwork,
            "if (m_art_http_ip.empty())",
            "return;",
            "char *source_artwork = strdup( psz_art );",
            "if (source_artwork == NULL)",
            "return;",
            "free( m_art_url );",
            "m_art_url = source_artwork;",
            "chromecast_artwork_url(m_art_http_ip, ss_art_idx.str())",
            "if (published.empty())",
            "return;",
            "m_art_http_url = published;",
            "vlc_meta_Set( m_meta, vlc_meta_ArtworkURL, published.c_str() );",
        )
        require_count(prepare_artwork, "chromecast_artwork_url(", 1)
        require_count(prepare_artwork, "m_art_http_url = published;", 1)
        require_count(prepare_artwork, "m_art_url = source_artwork;", 1)
    reinit = function_body(cast_control, "void intf_sys_t::reinit(")
    reinit_contract = [
        "restoreHttpArtwork();",
        "m_art_http_ip.clear();",
        "new ChromecastCommunication(",
        "new_communication->isConnected()",
        "m_art_http_ip = m_communication->getServerBaseURL();",
        "if (m_art_http_ip.empty())",
        "delete m_communication;",
        "return;",
    ]
    if not load_transition_contract:
        reinit_contract.append("prepareHttpArtwork();")
    reinit_contract.append("m_state = Authenticating;")
    ordered(reinit, *reinit_contract)
    require_count(reinit, "restoreHttpArtwork();", 1)
    require_count(reinit, "m_art_http_ip.clear();", 1)
    if load_transition_contract:
        forbid(reinit, "prepareHttpArtwork(")
    else:
        require_count(reinit, "prepareHttpArtwork();", 1)
    restore_call = direct_statement_match(
        reinit,
        RESTORE_ARTWORK_STATEMENT,
        "reinit old-route artwork restoration",
        reject_prior_transfer=False,
    )
    clear_call = direct_statement_match(
        reinit,
        CLEAR_ARTWORK_ROUTE_STATEMENT,
        "reinit old-route base invalidation",
        reject_prior_transfer=False,
    )
    reinit_source = without_cpp_comments(reinit)
    restore_prefix = compact_cpp(reinit_source[1 : restore_call.start()])
    if restore_prefix != (
        "assert(m_state==Dead);"
        "if(m_reconnecting)return;"
        "m_reconnecting=true;"
    ):
        raise AssertionError(
            "reinit may only guard an already-running reconnect before "
            "unconditional old-route artwork restoration"
        )
    if reinit_source[restore_call.end() : clear_call.start()].strip():
        raise AssertionError(
            "reinit must invalidate the old route immediately after unconditional "
            "artwork restoration"
        )

    if load_transition_contract:
        require(
            cast_header,
            "unsigned msgPlayerLoad( const std::string& destinationId,",
            "cc_stream_token_t stream_token,",
            "std::string GetMedia(cc_stream_token_t stream_token,",
            "std::string getServerBaseURL() const;",
            "bool isConnected() const",
            "bool setInputLength(cc_input_generation_t, vlc_tick_t length);",
            "vlc_tick_t m_input_length;",
        )
        require(
            cast_common,
            "bool (*pf_set_input_length)(void *, cc_input_generation_t,",
            "vlc_tick_t length);",
        )
    else:
        require(
            cast_header,
            "std::string getServerBaseURL() const;",
            "bool isConnected() const",
            "void setInputLength( vlc_tick_t length );",
            "vlc_tick_t m_input_length;",
        )
        require(
            cast_common,
            "void (*pf_set_input_length)(void*, vlc_tick_t length);",
        )
    constructor_start = cast_control.index("intf_sys_t::intf_sys_t(")
    constructor_end = cast_control.index("intf_sys_t::~intf_sys_t()", constructor_start)
    control_constructor = cast_control[constructor_start:constructor_end]
    ordered(
        control_constructor,
        "m_input_length( VLC_TICK_INVALID )",
        "m_art_http_ip = m_communication->getServerBaseURL();",
        "m_common.pf_set_input_length = set_input_length;",
    )
    if load_transition_contract:
        set_length = function_body(cast_control, "bool intf_sys_t::setInputLength(")
        ordered(
            set_length,
            "mutex_locker lock( m_lock );",
            "generation == m_pending_input_generation",
            "m_pending_input_length = length;",
            "generation == m_active_input_generation",
            "m_input_length = length;",
            "return false;",
        )
        require_exact_compact(
            set_length,
            EXPECTED_SET_LENGTH_BODY,
            "setInputLength generation-bound duration publication",
        )
        set_meta = function_body(cast_control, "bool intf_sys_t::setMeta(")
        ordered(
            set_meta,
            "*slot = p_meta;",
            "m_art_http_url.clear();",
            "return true;",
        )
        require_exact_compact(
            set_meta,
            EXPECTED_SET_META_BODY,
            "setMeta generation ownership and metadata transfer",
        )
        try_load = function_body(cast_control, "void intf_sys_t::tryLoad(")
        require(
            try_load,
            "prepareHttpArtwork(generation, stream_token,",
            "m_communication->msgPlayerLoad(m_appTransportId, stream_token,",
            "m_mime, m_meta, m_input_length)",
        )
        loop_match = direct_statement_match(
            try_load,
            TRY_LOAD_LOOP,
            "tryLoad transaction loop",
            reject_prior_transfer=True,
        )
        loop = braced_body(
            try_load,
            loop_match.end() - 1,
            "tryLoad transaction loop",
        )
        direct_statement_match(
            loop,
            TRY_LOAD_COMMIT_PIPELINE,
            "tryLoad LOAD attribution/state pipeline",
            reject_prior_transfer=True,
        )
    else:
        set_length = function_body(cast_control, "void intf_sys_t::setInputLength(")
        ordered(
            set_length,
            "mutex_locker lock( m_lock );",
            "m_input_length = length;",
        )
        set_meta = function_body(cast_control, "void intf_sys_t::setMeta(")
        ordered(set_meta, "m_meta = p_meta;", "m_art_http_url.clear();")
        try_load = function_body(cast_control, "void intf_sys_t::tryLoad(")
        require(
            try_load,
            "msgPlayerLoad( m_appTransportId, m_mime, m_meta, m_input_length )",
        )
    duration_policy = function_body(
        cast_duration, "chromecast_query_demux_input_length("
    )
    ordered(
        duration_policy,
        "duration = VLC_TICK_INVALID;",
        "bool live = false;",
        "query(&duration, &live) != VLC_SUCCESS",
        "return VLC_TICK_INVALID;",
        "if (live)",
        "return INPUT_DURATION_INDEFINITE;",
        "duration > VLC_TICK_0 ? duration : VLC_TICK_INVALID;",
    )
    require_count(duration_policy, "return ", 3)
    demux_init = function_body(cast_demux, "void init()")
    duration_contract = [
        "m_length = chromecast_query_demux_input_length(",
        "[this](vlc_tick_t *duration, bool *live)",
        "demux_Control(p_demux->s, DEMUX_GET_LENGTH,",
        "duration, live);",
    ]
    if load_transition_contract:
        duration_contract.extend(
            (
                "pf_set_input_length( p_renderer->p_opaque, m_generation,",
                "m_length );",
            )
        )
    else:
        duration_contract.append(
            "pf_set_input_length( p_renderer->p_opaque, m_length );"
        )
    ordered(demux_init, *duration_contract)
    require_count(demux_init, "chromecast_query_demux_input_length(", 1)
    require_count(demux_init, "DEMUX_GET_LENGTH", 1)
    forbid(demux_init, "b_unused_live", "m_length = -1", "&m_length")
    direct_statement_match(
        demux_init,
        DEMUX_DURATION_PUBLICATION
        if load_transition_contract
        else DEMUX_DURATION_QUERY_STATEMENT,
        "demux init duration/live query/publication",
        reject_prior_transfer=True,
    )
    direct_statement_match(
        demux_init,
        DEMUX_INIT_TERMINAL_RESET,
        "demux initialization terminal clock reset",
        reject_prior_transfer=True,
    )
    if load_transition_contract:
        require(
            cast_demux,
            "pf_set_input_length( p_renderer->p_opaque, m_generation,",
            "VLC_TICK_INVALID );",
        )
    else:
        require(
            cast_demux,
            "pf_set_input_length( p_renderer->p_opaque, VLC_TICK_INVALID );",
        )


def expect_rejected(action, description: str) -> None:
    try:
        action()
    except AssertionError:
        return
    raise AssertionError(f"validator self-test accepted bypass: {description}")


def self_test() -> None:
    direct_base_url = """
    {
        return chromecast_server_base_url(m_serverIp, m_serverPort);
    }
    """
    require_direct_return_wrapper(
        direct_base_url,
        "chromecast_server_base_url(m_serverIp, m_serverPort)",
        "self-test base URL",
    )
    expect_rejected(
        lambda: require_direct_return_wrapper(
            """
            {
                if (false)
                    return chromecast_server_base_url(m_serverIp, m_serverPort);
                return m_serverIp;
            }
            """,
            "chromecast_server_base_url(m_serverIp, m_serverPort)",
            "self-test base URL",
        ),
        "dead URL policy helper followed by raw server IP return",
    )

    direct_stream_url = """
    {
        const std::string chromecast_url = chromecast_stream_url(
            server_base_url, m_serverPath, stream_token);
        publish(chromecast_url);
    }
    """
    direct_statement_match(
        direct_stream_url,
        STREAM_URL_STATEMENT,
        "self-test token-bound Chromecast stream URL",
        reject_prior_transfer=True,
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                if (false) {
                    const std::string chromecast_url = chromecast_stream_url(
                        server_base_url, m_serverPath, stream_token);
                }
                publish(server_base_url + m_serverPath);
            }
            """,
            STREAM_URL_STATEMENT,
            "self-test token-bound Chromecast stream URL",
        ),
        "token-bound stream URL retained only in a dead conditional",
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                return {};
                const std::string chromecast_url = chromecast_stream_url(
                    server_base_url, m_serverPath, stream_token);
                publish(chromecast_url);
            }
            """,
            STREAM_URL_STATEMENT,
            "self-test token-bound Chromecast stream URL",
            reject_prior_transfer=True,
        ),
        "token-bound stream URL after an unconditional return",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_stream_url.replace(
                "const std::string chromecast_url",
                "if (true) return {};\n"
                "        const std::string chromecast_url",
                1,
            ),
            STREAM_URL_STATEMENT,
            "self-test token-bound Chromecast stream URL",
            reject_prior_transfer=True,
        ),
        "GetMedia killed by an always-true guarded return",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_stream_url.replace(
                "const std::string chromecast_url",
                "if (!false) { return {}; }\n"
                "        const std::string chromecast_url",
                1,
            ),
            STREAM_URL_STATEMENT,
            "self-test token-bound Chromecast stream URL",
            reject_prior_transfer=True,
        ),
        "GetMedia killed by a braced always-true guarded return",
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                const std::string chromecast_url = chromecast_stream_url(
                    server_base_url, m_serverPath, 1);
                publish(chromecast_url);
            }
            """,
            STREAM_URL_STATEMENT,
            "self-test token-bound Chromecast stream URL",
        ),
        "fixed token substituted for the owned stream token",
    )

    direct_restore = """
    {
        assert(m_state == Dead);
        restoreHttpArtwork();
        m_art_http_ip.clear();
    }
    """
    direct_statement_match(
        direct_restore,
        RESTORE_ARTWORK_STATEMENT,
        "self-test artwork restore",
        reject_prior_transfer=True,
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                assert(m_state == Dead);
                if (m_art_http_ip.empty())
                    restoreHttpArtwork();
                m_art_http_ip.clear();
            }
            """,
            RESTORE_ARTWORK_STATEMENT,
            "self-test artwork restore",
            reject_prior_transfer=True,
        ),
        "conditionally guarded old-route artwork restoration",
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                return;
                restoreHttpArtwork();
                m_art_http_ip.clear();
            }
            """,
            RESTORE_ARTWORK_STATEMENT,
            "self-test artwork restore",
            reject_prior_transfer=True,
        ),
        "old-route restoration after an unconditional return",
    )

    direct_duration_query = """
    {
        resetDemuxEof();
        m_can_seek = false;
        m_length = chromecast_query_demux_input_length(
            [this](vlc_tick_t *duration, bool *live) {
                return demux_Control(p_demux->s, DEMUX_GET_LENGTH,
                                     duration, live);
            });
        publish(m_length);
    }
    """
    direct_statement_match(
        direct_duration_query,
        DEMUX_DURATION_QUERY_STATEMENT,
        "self-test duration/live query",
        reject_prior_transfer=True,
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                m_can_seek = false;
                m_length = chromecast_query_demux_input_length(
                    [this](vlc_tick_t *duration, bool *live) {
                        if (false)
                            demux_Control(p_demux->s, DEMUX_GET_LENGTH,
                                          duration, live);
                        return VLC_EGENERIC;
                    });
                publish(m_length);
            }
            """,
            DEMUX_DURATION_QUERY_STATEMENT,
            "self-test duration/live query",
            reject_prior_transfer=True,
        ),
        "dead DEMUX_GET_LENGTH call with forced production failure",
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                m_can_seek = false;
                if (false) {
                    m_length = chromecast_query_demux_input_length(
                        [this](vlc_tick_t *duration, bool *live) {
                            return demux_Control(p_demux->s, DEMUX_GET_LENGTH,
                                                 duration, live);
                        });
                }
                publish(m_length);
            }
            """,
            DEMUX_DURATION_QUERY_STATEMENT,
            "self-test duration/live query",
            reject_prior_transfer=True,
        ),
        "correct duration query retained only in a dead conditional",
    )

    direct_media_fields = """
    {
        const std::string media_fields = chromecast_media_fields(
            chromecast_url, mime, input_length);
        publish(media_fields);
    }
    """
    direct_statement_match(
        direct_media_fields,
        MEDIA_FIELDS_STATEMENT,
        "self-test token-bound media fields",
        reject_prior_transfer=True,
    )
    expect_rejected(
        lambda: direct_statement_match(
            """
            {
                if (false) {
                    const std::string media_fields = chromecast_media_fields(
                        chromecast_url, mime, input_length);
                }
                publish(raw_media);
            }
            """,
            MEDIA_FIELDS_STATEMENT,
            "self-test token-bound media fields",
            reject_prior_transfer=True,
        ),
        "media-field construction retained only in a dead conditional",
    )

    direct_player_load = """
    {
        unsigned id = getNextRequestId();
        const std::string media = GetMedia(stream_token, mime, p_meta,
                                           input_length);
        if (media.empty())
            return kInvalidId;
        const std::string payload = chromecast_load_payload(media, id);
        if (payload.empty())
            return kInvalidId;
        std::stringstream ss(payload);
        return pushMediaPlayerMessage(destinationId, ss) == VLC_SUCCESS
             ? id : kInvalidId;
    }
    """
    direct_statement_match(
        direct_player_load,
        GET_MEDIA_STATEMENT,
        "self-test stream-token GetMedia call",
        reject_prior_transfer=True,
    )
    direct_statement_match(
        direct_player_load,
        LOAD_PAYLOAD_STATEMENT,
        "self-test LOAD payload construction",
        reject_prior_transfer=True,
    )
    require_exact_compact(
        direct_player_load,
        EXPECTED_PLAYER_LOAD_BODY,
        "self-test msgPlayerLoad pipeline",
    )
    expect_rejected(
        lambda: require_exact_compact(
            direct_player_load.replace(
                "const std::string payload = chromecast_load_payload(media, id);",
                "const std::string payload = chromecast_load_payload(media, id);"
                " return kInvalidId;",
            ),
            EXPECTED_PLAYER_LOAD_BODY,
            "self-test msgPlayerLoad pipeline",
        ),
        "LOAD payload constructed but never sent",
    )

    direct_prepare_prefix = """
    {
        assert(published_url != NULL);
        published_url->clear();
        if (!queuedInputCanCommit(generation, stream_token))
            return false;
        publish();
        return true;
    }
    """
    direct_statement_match(
        direct_prepare_prefix,
        PREPARE_ARTWORK_PREFIX,
        "self-test artwork commit prefix",
        reject_prior_transfer=True,
    )
    direct_statement_match(
        direct_prepare_prefix,
        FINAL_TRUE_RETURN,
        "self-test artwork terminal publication",
        reject_prior_transfer=True,
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_prepare_prefix.replace(
                "published_url->clear();",
                "published_url->clear(); return false;",
            ),
            PREPARE_ARTWORK_PREFIX,
            "self-test artwork commit prefix",
            reject_prior_transfer=True,
        ),
        "artwork preparation killed before its generation/token guard",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_prepare_prefix.replace(
                "return false;",
                "return false; return true;",
                1,
            ),
            FINAL_TRUE_RETURN,
            "self-test artwork terminal publication",
            reject_prior_transfer=True,
        ),
        "artwork transaction killed after its initial ownership guard",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_prepare_prefix.replace(
                "return false;\n        publish();",
                "return false;\n        if (true) return false;\n"
                "        publish();",
                1,
            ),
            FINAL_TRUE_RETURN,
            "self-test artwork terminal publication",
            reject_prior_transfer=True,
        ),
        "artwork transaction killed by an always-true guarded return",
    )

    direct_try_load = """
    {
        for (;;)
        {
            const unsigned request_id = m_communication->msgPlayerLoad(
                m_appTransportId, stream_token, m_mime, m_meta, m_input_length);
            m_load_commit_in_progress = false;
            if (recordMediaRequest(chromecast_media_command::Load, request_id))
            {
                m_state = Loading;
                armStateDeadline(Loading);
                updateProgressWatchdog(Loading);
            }
            else
                setState(LoadFailed);
            return;
        }
    }
    """
    loop_match = direct_statement_match(
        direct_try_load,
        TRY_LOAD_LOOP,
        "self-test tryLoad transaction loop",
        reject_prior_transfer=True,
    )
    direct_try_load_loop = braced_body(
        direct_try_load, loop_match.end() - 1, "self-test tryLoad loop"
    )
    direct_statement_match(
        direct_try_load_loop,
        TRY_LOAD_COMMIT_PIPELINE,
        "self-test tryLoad LOAD attribution/state pipeline",
        reject_prior_transfer=True,
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_try_load.replace("for (;;)", "return; for (;;)", 1),
            TRY_LOAD_LOOP,
            "self-test tryLoad transaction loop",
            reject_prior_transfer=True,
        ),
        "tryLoad killed before its transaction loop",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_try_load.replace(
                "for (;;)", "if (true) return;\n        for (;;)", 1
            ),
            TRY_LOAD_LOOP,
            "self-test tryLoad transaction loop",
            reject_prior_transfer=True,
        ),
        "tryLoad killed by an always-true guarded return",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_try_load_loop.replace(
                "m_load_commit_in_progress = false;",
                "return; m_load_commit_in_progress = false;",
                1,
            ),
            TRY_LOAD_COMMIT_PIPELINE,
            "self-test tryLoad LOAD attribution/state pipeline",
            reject_prior_transfer=True,
        ),
        "LOAD sent without request attribution or Loading state",
    )

    require_exact_compact(
        EXPECTED_SET_META_BODY,
        EXPECTED_SET_META_BODY,
        "self-test setMeta",
    )
    expect_rejected(
        lambda: require_exact_compact(
            EXPECTED_SET_META_BODY.replace("{", "{returnfalse;", 1),
            EXPECTED_SET_META_BODY,
            "self-test setMeta",
        ),
        "setMeta killed before taking generation-bound ownership",
    )
    require_exact_compact(
        EXPECTED_SET_LENGTH_BODY,
        EXPECTED_SET_LENGTH_BODY,
        "self-test setInputLength",
    )
    expect_rejected(
        lambda: require_exact_compact(
            EXPECTED_SET_LENGTH_BODY.replace("{", "{returntrue;", 1),
            EXPECTED_SET_LENGTH_BODY,
            "self-test setInputLength",
        ),
        "setInputLength reports success without publishing duration",
    )

    direct_duration_publication = """
    {
        m_length = chromecast_query_demux_input_length(
            [this](vlc_tick_t *duration, bool *live) {
                return demux_Control(p_demux->s, DEMUX_GET_LENGTH,
                                     duration, live);
            });
        p_renderer->pf_set_input_length(p_renderer->p_opaque, m_generation,
                                        m_length);
        int i_current_title;
        es_out_Control(p_demux->s->out, ES_OUT_RESET_PCR);
        p_renderer->pf_set_demux_enabled(
            p_renderer->p_opaque, m_generation, true,
            on_paused_changed_cb, p_demux);
        resetTimes();
    }
    """
    direct_statement_match(
        direct_duration_publication,
        DEMUX_DURATION_PUBLICATION,
        "self-test duration query/publication",
        reject_prior_transfer=True,
    )
    direct_statement_match(
        direct_duration_publication,
        DEMUX_INIT_TERMINAL_RESET,
        "self-test demux initialization terminal reset",
        reject_prior_transfer=True,
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_duration_publication.replace(
                "p_renderer->pf_set_input_length",
                "return; p_renderer->pf_set_input_length",
                1,
            ),
            DEMUX_DURATION_PUBLICATION,
            "self-test duration query/publication",
            reject_prior_transfer=True,
        ),
        "duration queried but never published to the owned generation",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_duration_publication.replace(
                "m_length);\n        int i_current_title;",
                "m_length); return;\n        int i_current_title;",
                1,
            ),
            DEMUX_INIT_TERMINAL_RESET,
            "self-test demux initialization terminal reset",
            reject_prior_transfer=True,
        ),
        "demux initialization killed after duration publication",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_duration_publication.replace(
                "m_length);\n        int i_current_title;",
                "m_length); if (true) return;\n"
                "        int i_current_title;",
                1,
            ),
            DEMUX_INIT_TERMINAL_RESET,
            "self-test demux initialization terminal reset",
            reject_prior_transfer=True,
        ),
        "demux initialization killed by an always-true guarded return",
    )
    expect_rejected(
        lambda: direct_statement_match(
            direct_duration_publication.replace(
                "on_paused_changed_cb, p_demux);\n        resetTimes();",
                "on_paused_changed_cb, p_demux); return;\n        resetTimes();",
                1,
            ),
            DEMUX_INIT_TERMINAL_RESET,
            "self-test demux initialization terminal reset",
            reject_prior_transfer=True,
        ),
        "demux initialization killed after enabling its owned generation",
    )


def main() -> int:
    if len(sys.argv) == 2 and sys.argv[1] == "--self-test":
        try:
            self_test()
        except AssertionError as error:
            print(
                f"post-pin stability source checker self-test failed: {error}",
                file=sys.stderr,
            )
            return 1
        print("post-pin stability source checker self-test passed")
        return 0
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} <patched-vlc-source> | --self-test")
    root = Path(sys.argv[1]).resolve()
    try:
        validate(root)
    except (AssertionError, OSError, UnicodeError) as error:
        print(f"post-pin stability source check failed: {error}", file=sys.stderr)
        return 1
    print("post-pin stability source check passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
