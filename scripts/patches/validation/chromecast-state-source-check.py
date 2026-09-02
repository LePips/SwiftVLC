#!/usr/bin/env python3
"""Structural and adversarial proof for SwiftVLC's native Cast state patch.

The native probe executes the exact policy helpers.  This checker binds those
helpers to the production controller, transport, and demux call sites and then
mutates each formerly unsafe branch.  A mutation must make validation fail;
retaining a helper or reassuring token in dead/commented code is insufficient.
"""

from __future__ import annotations

import argparse
from pathlib import Path
import re
from typing import Mapping


PATHS = {
    "header": "modules/stream_out/chromecast/chromecast.h",
    "protocol": "modules/stream_out/chromecast/chromecast_protocol.hpp",
    "communication": "modules/stream_out/chromecast/chromecast_communication.cpp",
    "controller": "modules/stream_out/chromecast/chromecast_ctrl.cpp",
    "demux": "modules/stream_out/chromecast/chromecast_demux.cpp",
    "eof": "modules/stream_out/chromecast/chromecast_demux_eof.hpp",
    "makefile": "modules/stream_out/Makefile.am",
    "meson": "modules/stream_out/chromecast/meson.build",
}


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


def function_body(source: str, signature: str) -> str:
    start = source.find(signature)
    if start < 0:
        raise AssertionError(f"missing function {signature}")
    opening = source.find("{", start + len(signature))
    if opening < 0:
        raise AssertionError(f"missing body for {signature}")
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
                raise AssertionError("unterminated source comment")
            index = closing + 2
            continue
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[opening : index + 1]
        index += 1
    raise AssertionError(f"unterminated body for {signature}")


def require(source: str, *tokens: str) -> None:
    for token in tokens:
        if token not in source:
            raise AssertionError(f"missing invariant {token!r}")


def forbid(source: str, *tokens: str) -> None:
    for token in tokens:
        if token in source:
            raise AssertionError(f"forbidden invariant {token!r}")


def ordered(source: str, *tokens: str) -> None:
    cursor = 0
    for token in tokens:
        position = source.find(token, cursor)
        if position < 0:
            raise AssertionError(f"missing/out-of-order invariant {token!r}")
        cursor = position + len(token)


def validate(sources: Mapping[str, str]) -> None:
    header = compact(sources["header"])
    protocol = compact(sources["protocol"])
    communication = compact(sources["communication"])
    controller_source = without_comments(sources["controller"])
    controller = compact(controller_source)
    demux = compact(sources["demux"])
    eof = compact(sources["eof"])
    makefile = compact(sources["makefile"])
    meson = compact(sources["meson"])

    require(
        protocol,
        "staticconstexprsize_tCHROMECAST_MESSAGE_MAX_SIZE=64u*1024u;",
        "staticconstexprintCHROMECAST_WRITE_TIMEOUT_MS=2000;",
        "if(target.id!=0)returnfalse;",
        "if(collision!=chromecast_media_command::None)returnfalse;",
        "target={request_id,deadline};",
        "deadline==VLC_TICK_INVALID",
        "vlc_tick_tnext_deadline()const",
        "candidate->deadline<deadline",
        "!std::isfinite(current_time)||current_time<0",
        "!std::isfinite(playback_rate)||playback_rate<0",
        'm_rate=player_state=="PLAYING"?playback_rate:0.;',
        "m_valid=true;",
        "if(!m_valid)returnVLC_TICK_INVALID;",
        "result==VLC_TICK_INVALID?VLC_TICK_0:result",
        "value>=std::ldexp(1.0,63)",
        "constint64_telapsed_ms=MS_FROM_VLC_TICK(now-begin);",
        "classchromecast_progress_watchdog",
        "if(m_deadline==VLC_TICK_INVALID)m_deadline=chromecast_deadline(now,timeout_ms);",
        "m_deadline!=VLC_TICK_INVALID&&now>=m_deadline",
        "chromecast_write_all_bounded(size_tsize,inttimeout_ms",
        "boolattempted=false;",
        "if(attempted&&chromecast_remaining_timeout_ms(begin,now(),timeout_ms)==0)",
        "attempted=true;",
        "constintready=wait(remaining);",
        "errno=ETIMEDOUT;",
    )
    ordered(protocol, "if(target.id!=0)returnfalse;", "target={request_id,deadline};")
    tracker_record = compact(function_body(sources["protocol"], "bool record("))
    require(
        tracker_record,
        "deadline==VLC_TICK_INVALID",
        "if(target.id!=0)returnfalse;",
        "target={request_id,deadline};",
    )
    forbid(
        function_body(sources["protocol"], "chromecast_remaining_timeout_ms"),
        "SEC_FROM_VLC_TICK",
    )

    require(
        header,
        "chromecast_media_request_trackerm_requests;",
        "boolm_desired_paused;",
        "std::atomic_boolm_terminal_transport;",
        "uint8_tm_pauseRetriesLeft;",
        "uint8_tm_stopRetriesLeft;",
        "uint8_tm_statusRetriesLeft;",
        "vlc_tick_tm_stateDeadline;",
        "chromecast_progress_watchdogm_progressWatchdog;",
        "chromecast_media_clockm_cc_clock;",
    )
    forbid(header, "m_last_request_id", "boolm_paused;", "m_cc_time_date")

    send_message = compact(function_body(
        sources["communication"], "ChromecastCommunication::sendMessage"
    ))
    ordered(
        send_message,
        "size_ti_size=msg.ByteSizeLong();",
        "if(i_size==0||i_size>CHROMECAST_MESSAGE_MAX_SIZE)",
        "new(std::nothrow)uint8_t[PACKET_HEADER_LEN+i_size]",
        "chromecast_write_all_bounded(",
        "frame_size,CHROMECAST_WRITE_TIMEOUT_MS",
    )
    require(
        send_message,
        "m_tls->ops->writev(m_tls,&iov,1)",
        "vlc_poll_i11e(&ufd,1,timeout_ms)",
        "constintsaved_errno=errno;",
    )
    forbid(send_message, "vlc_tls_Write(", "vlc_poll_i11e(&ufd,1,-1)")
    receive = compact(function_body(
        sources["communication"], "ChromecastCommunication::receive"
    ))
    require(
        receive,
        "*pb_timeout=false;",
        "constvlc_tick_tbegin=vlc_tick_now();",
        "chromecast_remaining_timeout_ms(begin,vlc_tick_now(),i_timeout)",
        "constintremaining=chromecast_remaining_timeout_ms(",
        "vlc_poll_i11e(ufd,1,remaining)",
    )
    ordered(
        receive,
        "constvlc_tick_tbegin=vlc_tick_now();",
        "constintremaining=chromecast_remaining_timeout_ms(",
        "vlc_poll_i11e(ufd,1,remaining)",
    )
    if receive.count("errno==EINTR&&i_received>0") < 2:
        raise AssertionError("both read and poll partial-EINTR paths must fail closed")
    if receive.count("errno=EPROTO;") < 2:
        raise AssertionError("partial-EINTR paths must not look like idle wakeups")
    require(
        communication,
        "m_receiver_requestId(chromecast_random_request_id())",
        "m_requestId(chromecast_random_request_id())",
    )

    require(
        controller,
        "#definePING_WAIT_TIME_MS6000",
        "#defineMEDIA_COMMAND_TIMEOUT_MS10000",
        "#defineMEDIA_LOAD_TIMEOUT_MS30000",
        "#defineCONTROL_STATE_TIMEOUT_MS15000",
        "#defineMEDIA_PROGRESS_TIMEOUT_MS30000",
    )
    dead = compact(function_body(sources["controller"],
                                 "void intf_sys_t::setConnectionDead"))
    ordered(
        dead,
        "m_terminal_transport.exchange(true,std::memory_order_acq_rel)",
        "clearMediaSessionState();",
        "setState(Dead);",
        "vlc_interrupt_raise(m_ctl_thread_interrupt);",
    )
    reinit = compact(function_body(sources["controller"],
                                   "void intf_sys_t::reinit"))
    ordered(
        reinit,
        "m_reconnecting=true;",
        "m_lock.unlock();",
        "vlc_join(m_chromecastThread,NULL);",
        "m_lock.lock();",
        "m_communication=NULL;",
        "deleteold_communication;",
    )
    main_loop = compact(function_body(sources["controller"],
                                      "void intf_sys_t::mainLoop"))
    require(
        main_loop,
        "!m_terminal_transport.load(std::memory_order_acquire)",
        "m_communication->msgAuth()==ChromecastCommunication::kInvalidId",
        "checkCommandAndStateDeadlines(now)",
        "nextMessageWaitTimeout(now,&heartbeat_timeout)",
        "handleMessages(wait_timeout_ms,heartbeat_timeout)",
        "checkCommandAndStateDeadlines(vlc_tick_now())",
    )
    if main_loop.count("checkCommandAndStateDeadlines(") < 2:
        raise AssertionError("controller deadlines must bracket each blocking receive")

    record_request = compact(function_body(
        sources["controller"], "bool intf_sys_t::recordMediaRequest"
    ))
    require(
        record_request,
        "command==chromecast_media_command::Load?MEDIA_LOAD_TIMEOUT_MS:MEDIA_COMMAND_TIMEOUT_MS",
        "m_requests.record(command,request_id,chromecast_deadline(vlc_tick_now(),timeout_ms))",
    )
    state_deadline = compact(function_body(
        sources["controller"], "void intf_sys_t::armStateDeadline"
    ))
    require(
        state_deadline,
        "caseAuthenticating:",
        "caseConnecting:",
        "caseLaunching:",
        "timeout_ms=CONTROL_STATE_TIMEOUT_MS;",
        "m_stateDeadline=timeout_ms==0?VLC_TICK_INVALID:chromecast_deadline(vlc_tick_now(),timeout_ms);",
    )
    forbid(state_deadline, "caseLoading:", "caseBuffering:")
    progress_watchdog = compact(function_body(
        sources["controller"], "void intf_sys_t::updateProgressWatchdog"
    ))
    require(
        progress_watchdog,
        "state==Loading||state==Buffering",
        "m_progressWatchdog.arm(vlc_tick_now(),MEDIA_PROGRESS_TIMEOUT_MS);",
        "m_progressWatchdog.clear();",
    )
    next_wait = compact(function_body(
        sources["controller"], "int intf_sys_t::nextMessageWaitTimeout"
    ))
    require(
        next_wait,
        "m_requests.next_deadline()",
        "m_progressWatchdog.deadline()",
        "*heartbeat_timeout=false;",
        "returnPING_WAIT_TIME_MS;",
    )
    deadlines = compact(function_body(
        sources["controller"], "bool intf_sys_t::checkCommandAndStateDeadlines"
    ))
    require(
        deadlines,
        "m_requests.expired(chromecast_media_command::Load,now)",
        "m_requests.expired(chromecast_media_command::Play,now)",
        "m_requests.expired(chromecast_media_command::Pause,now)",
        "m_requests.expired(chromecast_media_command::Stop,now)",
        "m_requests.expired(chromecast_media_command::Status,now)",
        "m_requests.discard(chromecast_media_command::Stop)",
        "m_requests.discard(chromecast_media_command::Status)",
        "m_pauseRetriesLeft==0",
        "m_stopRetriesLeft==0",
        "m_statusRetriesLeft==0",
        "m_progressWatchdog.expired(now)",
        "m_state!=Loading&&m_state!=Buffering",
        "if(m_played_once)",
        "setState(LoadFailed);",
        "m_stateDeadline!=VLC_TICK_INVALID&&now>=m_stateDeadline",
        "caseAuthenticating:",
        "caseConnecting:",
        "caseLaunching:",
        "setConnectionDead();",
    )
    clear_session = compact(function_body(
        sources["controller"], "void intf_sys_t::clearMediaSessionState"
    ))
    require(clear_session, "m_requests.clear();", "m_progressWatchdog.clear();")
    set_state = compact(function_body(
        sources["controller"], "void intf_sys_t::setState"
    ))
    ordered(
        set_state,
        "m_state=state;",
        "armStateDeadline(state);",
        "updateProgressWatchdog(state);",
    )

    handle = compact(function_body(sources["controller"],
                                   "bool intf_sys_t::handleMessages"))
    require(
        handle,
        "std::vector<uint8_t>packet(PACKET_HEADER_LEN+CHROMECAST_MESSAGE_MAX_SIZE);",
        "chromecast_remaining_timeout_ms(i_begin_time,vlc_tick_now(),timeout_ms)",
        "if(i_received>0&&remaining==0)",
        "if(i_ret>0||i_received>0)",
        "if(!heartbeat_timeout)returntrue;",
        "if(i_received==0)return!m_terminal_transport.load(",
        "i_payloadSize==0||i_payloadSize>CHROMECAST_MESSAGE_MAX_SIZE",
        "if(!msg.ParseFromArray(packet.data()+PACKET_HEADER_LEN,i_payloadSize))",
        "if(!processMessage(msg))",
        "m_communication->msgPing()==ChromecastCommunication::kInvalidId",
        "m_communication->msgReceiverGetStatus()==ChromecastCommunication::kInvalidId",
    )

    media = compact(function_body(sources["controller"],
                                  "bool intf_sys_t::processMediaMessage"))
    require(
        media,
        'if(type!="MEDIA_STATUS"&&request_id!=0&&command==chromecast_media_command::None)',
        "m_requests.pending(chromecast_media_command::Load)&&command!=chromecast_media_command::Load",
        "if(command!=chromecast_media_command::Load)",
        "for(size_ti=0;i<status->array.size;++i)",
        "if(command==chromecast_media_command::None)",
        "received_clock.update(json_get_num(media_status,\"currentTime\"),json_get_num(media_status,\"playbackRate\")",
        'json_get_str_view(extended_status,"playerState")=="LOADING"',
        'idle_reason=="INTERRUPTED"',
        'idle_reason=="ERROR"',
        'idle_reason=="CANCELLED"',
        'idle_reason=="FINISHED"',
        'type=="INVALID_REQUEST"||type=="INVALID_PLAYER_STATE"',
        "m_requests.acknowledge(request_id);",
        "m_pauseRetriesLeft==0",
        "--m_pauseRetriesLeft;",
        "m_stopRetriesLeft==0",
        "--m_stopRetriesLeft;",
    )
    ordered(
        media,
        "if(media_status==NULL)",
        "received_clock.update(",
        "m_requests.acknowledge(request_id);",
    )

    receiver = compact(function_body(sources["controller"],
                                     "bool intf_sys_t::processReceiverMessage"))
    require(
        receiver,
        'json_get_object(entry,"status")',
        "applications_value->type!=JSON_ARRAY",
        "application->type!=JSON_OBJECT",
        "app_id==NULL",
        "transport_id==NULL||*transport_id=='\\0'||p_app!=NULL",
        "caseBuffering:",
        "caseStopping:",
        "caseDead:returnfalse;",
        "m_terminal_transport.load(std::memory_order_acquire)",
    )
    heartbeat = compact(function_body(sources["controller"],
                                      "bool intf_sys_t::processHeartBeatMessage"))
    require(
        heartbeat,
        "vlc::threads::mutex_lockerlock(m_lock);",
        "m_communication->msgPong()==ChromecastCommunication::kInvalidId",
    )
    connection = compact(function_body(sources["controller"],
                                       "void intf_sys_t::processConnectionMessage"))
    require(
        connection,
        "m_terminal_transport.load(std::memory_order_acquire)",
        "constboolactive=isStatePlaying()||m_state==Stopping;",
        "if(active)setConnectionDead();",
    )
    pause = compact(function_body(sources["controller"],
                                  "void intf_sys_t::setPauseState"))
    ordered(pause, "m_desired_paused=paused;", "sendDesiredPauseState()")
    timestamp = compact(function_body(sources["controller"],
                                      "vlc_tick_t intf_sys_t::getPlaybackTimestamp"))
    require(timestamp, "if(!m_cc_clock.valid())returnVLC_TICK_INVALID;")

    require(
        eof,
        "if(drain()!=VLC_SUCCESS)returnfalse;",
        "boolempty=false;",
        "returnis_empty(&empty)==VLC_SUCCESS&&empty;",
    )
    require(
        demux,
        "constbooldrained_and_empty=chromecast_demux_drained_and_empty(",
        "if(drained_and_empty)p_renderer->pf_send_input_event(",
    )
    forbid(demux, "boolb_empty=true;")
    for inventory in (makefile, meson):
        require(
            inventory,
            "chromecast_demux_eof.hpp",
            "chromecast_protocol.hpp",
        )


def replace_once(sources: Mapping[str, str], key: str, old: str, new: str) -> dict[str, str]:
    value = sources[key]
    if value.count(old) < 1:
        raise AssertionError(
            f"mutation fixture {key}:{old!r} is missing"
        )
    mutated = dict(sources)
    mutated[key] = value.replace(old, new, 1)
    return mutated


def run_negative_mutations(sources: Mapping[str, str]) -> int:
    mutations = [
        ("protocol", "64u * 1024u", "1024u * 1024u"),
        ("protocol", "CHROMECAST_WRITE_TIMEOUT_MS = 2000", "CHROMECAST_WRITE_TIMEOUT_MS = 0"),
        ("protocol", "if (target.id != 0)", "if (false)"),
        ("protocol", "deadline == VLC_TICK_INVALID", "deadline < VLC_TICK_INVALID"),
        ("protocol", "candidate->deadline < deadline", "candidate->deadline > deadline"),
        ("protocol", "if (m_deadline == VLC_TICK_INVALID)", "if (true)"),
        ("protocol", "if (attempted", "if (false"),
        ("protocol", "const int ready = wait(remaining);", "const int ready = wait(-1);"),
        ("protocol", "current_time < 0", "current_time < -1"),
        ("protocol", "MS_FROM_VLC_TICK(now - begin)", "SEC_FROM_VLC_TICK(now - begin)"),
        ("communication", "i_size > CHROMECAST_MESSAGE_MAX_SIZE", "i_size >= CHROMECAST_MESSAGE_MAX_SIZE"),
        ("communication", "errno == EINTR && i_received > 0", "errno == EINTR && false"),
        ("communication", "vlc_poll_i11e(ufd, 1, remaining)", "vlc_poll_i11e(ufd, 1, i_timeout)"),
        ("communication", "frame_size, CHROMECAST_WRITE_TIMEOUT_MS", "frame_size, -1"),
        ("controller", 'type != "MEDIA_STATUS" && request_id != 0', "request_id != 0"),
        ("controller", "checkCommandAndStateDeadlines(now)", "true"),
        ("controller", "handleMessages(wait_timeout_ms, heartbeat_timeout)", "handleMessages(PING_WAIT_TIME_MS, true)"),
        ("controller", "m_requests.expired(chromecast_media_command::Load, now)", "false"),
        ("controller", "m_requests.expired(chromecast_media_command::Pause, now)", "false"),
        ("controller", "m_requests.expired(chromecast_media_command::Stop, now)", "false"),
        ("controller", "m_requests.expired(chromecast_media_command::Status, now)", "false"),
        ("controller", "state == Loading || state == Buffering", "state == Loading"),
        ("controller", "m_progressWatchdog.expired(now)", "false"),
        ("controller", "m_stateDeadline != VLC_TICK_INVALID && now >= m_stateDeadline", "false"),
        ("controller", "if (!heartbeat_timeout)", "if (false)"),
        ("controller", "if (i_ret > 0 || i_received > 0)", "if (false)"),
        ("controller", "if (!msg.ParseFromArray", "if (msg.ParseFromArray"),
        ("controller", 'type == "INVALID_REQUEST" || type == "INVALID_PLAYER_STATE"', 'type == "INVALID_REQUEST"'),
        ("controller", "m_terminal_transport.exchange(true, std::memory_order_acq_rel)", "m_terminal_transport.load(std::memory_order_relaxed)"),
        ("controller", "applications_value->type != JSON_ARRAY", "applications_value->type == JSON_ARRAY"),
        ("eof", "bool empty = false;", "bool empty = true;"),
        ("eof", "if (drain() != VLC_SUCCESS)", "if (drain() == VLC_SUCCESS)"),
        ("demux", "chromecast_demux_drained_and_empty(", "chromecast_demux_always_empty("),
    ]
    for index, (key, old, new) in enumerate(mutations, 1):
        mutated = replace_once(sources, key, old, new)
        try:
            validate(mutated)
        except AssertionError:
            continue
        raise AssertionError(f"negative mutation {index} escaped: {key}:{old}")
    return len(mutations)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("vlc_source_root", type=Path)
    arguments = parser.parse_args()
    root = arguments.vlc_source_root.resolve()
    sources: dict[str, str] = {}
    for key, relative in PATHS.items():
        path = root / relative
        if not path.is_file():
            raise SystemExit(f"missing Cast validation input: {path}")
        sources[key] = path.read_text()

    validate(sources)
    mutation_count = run_negative_mutations(sources)
    print(
        "PASS Chromecast source/state proof: "
        f"files={len(sources)} negative_mutations={mutation_count}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
