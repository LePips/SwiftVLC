#!/usr/bin/env python3
"""Fail-closed source, replay, and mutation proof for VLC patch 0037.

Patch 0037 is intentionally validated as behavior, not as a coverage token:

* every demux, sout chain, HTTP stream, receiver LOAD, and callback carries a
  nonzero generation/token identity;
* STOP-to-LOAD handoff keeps the successor queued until the old session is
  terminal and re-arbitrates changes made while artwork I/O releases the lock;
* EOF, retry, pause, metadata, pacing, and clock observations cannot cross
  generations;
* the HTTP endpoint accepts only the exact LOAD token and exact live client;
* artwork callbacks own an immutable source context with paired lifetime; and
* the inherited 0036 metadata contract is checked against the actual final
  source, while its frozen mutation suite runs only after the full 0037 patch
  reverses byte-for-byte to the exact 0036 predecessor; and
* that reconstructed predecessor also passes the frozen 0035 and 0034 proofs.

The native probe executes the pure receiver-loading and stream-token helpers.
This checker binds those helpers to all production call sites and rejects
targeted source mutations independently of the exact patch hash.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
from pathlib import Path
import re
from typing import Mapping


PATHS = {
    "cast": "modules/stream_out/chromecast/cast.cpp",
    "header": "modules/stream_out/chromecast/chromecast.h",
    "common": "modules/stream_out/chromecast/chromecast_common.h",
    "communication": "modules/stream_out/chromecast/chromecast_communication.cpp",
    "controller": "modules/stream_out/chromecast/chromecast_ctrl.cpp",
    "demux": "modules/stream_out/chromecast/chromecast_demux.cpp",
    "dlna": "modules/stream_out/dlna/dlna.cpp",
    "protocol": "modules/stream_out/chromecast/chromecast_protocol.hpp",
    "eof": "modules/stream_out/chromecast/chromecast_demux_eof.hpp",
    "makefile": "modules/stream_out/Makefile.am",
    "meson": "modules/stream_out/chromecast/meson.build",
}

PATCH_PATHS = tuple(PATHS[key] for key in (
    "cast", "header", "common", "communication", "controller", "demux",
    "protocol",
))

EXPECTED_PATCH_SHA256 = (
    "dd3c672da9b7a6fcd82e6eadd298d1c5f86ce75e55d86800de8fd83683461105"
)
EXPECTED_SCHEMA_CHECKER_SHA256 = (
    "39fcc62fe9ac56359de49dcd22a54601e9f79d8b20b099fff117661be20ba909"
)
EXPECTED_SCHEMA_PATCH_SHA256 = (
    "d2e040c8db4ff529766be4bab875519e8e16242bed4bc645c4a485e422e47295"
)
EXPECTED_WARNING_CHECKER_SHA256 = (
    "155f6fc4207a160ad6811c8ca56cb96b5b38ce836db9a517b2bc2fb4dac64fdc"
)
EXPECTED_WARNING_PATCH_SHA256 = (
    "e14238bd31c42e8fa6b864746beeb3284ef485546228ea9c9f6181adc075983d"
)
EXPECTED_BASE_CHECKER_SHA256 = (
    "0bd1b049b103f4a4a2c5ad3f6de23eb97f9fa48be63dcfe65cc460761332704f"
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
                return source[opening:index + 1]
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


def require(source: str, *tokens: str) -> None:
    for token in tokens:
        if token not in source:
            raise AssertionError(f"missing production invariant {token!r}")


def forbid(source: str, *tokens: str) -> None:
    for token in tokens:
        if token in source:
            raise AssertionError(f"forbidden production invariant {token!r}")


def ordered(source: str, *tokens: str) -> None:
    cursor = 0
    for token in tokens:
        position = source.find(token, cursor)
        if position < 0:
            raise AssertionError(f"missing/out-of-order invariant {token!r}")
        cursor = position + len(token)


def direct_statement_match(
    body: str,
    pattern: re.Pattern[str],
    description: str,
    *,
    reject_prior_transfer: bool = False,
) -> re.Match[str]:
    """Require one literal statement/pipeline in the function's outer body."""

    source = without_comments(body)
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
            while end < match.start() and (
                source[end].isalnum() or source[end] == "_"
            ):
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
        transfers = ", ".join(prior_top_level_transfers)
        raise AssertionError(
            f"{description} follows a top-level control transfer: {transfers}"
        )
    return match


def validate_common(source: str) -> None:
    value = compact(source)
    require(
        value,
        "typedefuint64_tcc_input_generation_t;",
        "typedefuint64_tcc_stream_token_t;",
        "typedefvoid(*on_input_event_itf)(void*data,cc_input_generation_t,enumcc_input_event,unioncc_input_arg);",
        "cc_input_generation_t(*pf_begin_input)(void*,boolinitially_paused);",
        "void(*pf_end_input)(void*,cc_input_generation_t);",
        "bool(*pf_set_demux_enabled)(void*,cc_input_generation_t,boolenabled,on_paused_changed_itf,void*);",
        "vlc_tick_t(*pf_get_time)(void*,cc_input_generation_t);",
        "int(*pf_pace)(void*,cc_input_generation_t);",
        "bool(*pf_send_input_event)(void*,cc_input_generation_t,enumcc_input_event,unioncc_input_arg);",
        "bool(*pf_set_pause_state)(void*,cc_input_generation_t,boolpaused);",
        "bool(*pf_set_meta)(void*,cc_input_generation_t,vlc_meta_t*p_meta);",
        "bool(*pf_set_input_length)(void*,cc_input_generation_t,vlc_tick_tlength);",
    )


def validate_protocol(source: str) -> None:
    loading = compact(function_body(
        source, "chromecast_initial_load_is_pending("
    ))
    if loading != (
        '{return!played_once&&controller_starting&&player_state=="IDLE"'
        '&&extended_player_state=="LOADING"&&idle_reason.empty();}'
    ):
        raise AssertionError(
            "initial LOAD helper must require pre-play controller state, exact "
            "receiver IDLE/LOADING, and no terminal idleReason"
        )

    query = compact(function_body(
        source, "chromecast_stream_query(uint64_t stream_token)"
    ))
    require(query, "if(stream_token==0)return{};",
            'return"streamToken="+std::to_string(stream_token);')

    match = compact(function_body(
        source, "chromecast_stream_query_matches(std::string_view query,"
    ))
    require(
        match,
        'staticconstexprstd::string_viewprefix="streamToken=";',
        "expected_stream_token==0",
        "query.size()<=prefix.size()",
        "query.compare(0,prefix.size(),prefix)!=0",
        "value.size()>1&&value.front()=='0'",
        "if(c<'0'||c>'9')returnfalse;",
        "parsed>(std::numeric_limits<uint64_t>::max()-digit)/10",
        "returnparsed==expected_stream_token;",
    )
    forbid(match, "strtoull", "atoi(")

    url = compact(function_body(
        source, "chromecast_stream_url(const std::string &base_url,"
    ))
    ordered(
        url,
        "conststd::stringquery=chromecast_stream_query(stream_token);",
        "if(base_url.empty()||path.empty()||query.empty())return{};",
        'returnbase_url+path+"?"+query;',
    )


def validate_communication(header: str, source: str) -> None:
    header_value = compact(header)
    source_value = compact(source)
    require(
        header_value,
        "unsignedmsgPlayerLoad(conststd::string&destinationId,cc_stream_token_tstream_token,",
        "std::stringGetMedia(cc_stream_token_tstream_token,",
    )
    media = compact(function_body(
        source, "std::string ChromecastCommunication::GetMedia("
    ))
    ordered(
        media,
        "conststd::stringserver_base_url=getServerBaseURL();",
        "conststd::stringchromecast_url=chromecast_stream_url(server_base_url,m_serverPath,stream_token);",
        "if(chromecast_url.empty())",
        "chromecast_media_fields(chromecast_url,mime,input_length)",
    )
    direct_statement_match(
        function_body(source, "std::string ChromecastCommunication::GetMedia("),
        STREAM_URL_STATEMENT,
        "reachable stream-token URL construction",
        reject_prior_transfer=True,
    )
    direct_statement_match(
        function_body(source, "std::string ChromecastCommunication::GetMedia("),
        MEDIA_FIELDS_STATEMENT,
        "reachable stream-token media-field construction",
        reject_prior_transfer=True,
    )
    expected_media_suffix = (
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
    if not media.endswith(expected_media_suffix):
        raise AssertionError(
            "GetMedia token URL, media fields, and publication must be one "
            "exact reachable pipeline"
        )
    load = compact(function_body(
        source, "unsigned ChromecastCommunication::msgPlayerLoad("
    ))
    ordered(
        load,
        "conststd::stringmedia=GetMedia(stream_token,mime,p_meta,input_length);",
        "if(media.empty())returnkInvalidId;",
        "chromecast_load_payload(media,id)",
        "pushMediaPlayerMessage(destinationId,ss)",
    )
    expected_load = (
        "{unsignedid=getNextRequestId();"
        "conststd::stringmedia=GetMedia(stream_token,mime,p_meta,input_length);"
        "if(media.empty())returnkInvalidId;"
        "conststd::stringpayload=chromecast_load_payload(media,id);"
        "if(payload.empty())returnkInvalidId;"
        "std::stringstreamss(payload);"
        "returnpushMediaPlayerMessage(destinationId,ss)==VLC_SUCCESS?"
        "id:kInvalidId;}"
    )
    if load != expected_load:
        raise AssertionError(
            "msgPlayerLoad must directly bind the owned token, fail-closed "
            "payload, send, and request id"
        )
    forbid(source_value, "GetMedia(mime,p_meta,input_length)")


def validate_header(source: str) -> None:
    value = compact(source)
    require(
        value,
        "cc_input_generation_tgenerationForNewStream()const;",
        "boolmayBuildChain(cc_input_generation_t)const;",
        "boolsetRetryOnFail(cc_input_generation_t,bool);",
        "boolsetHasInput(cc_input_generation_t,cc_stream_token_t,",
        "boolrequestPlayerStop(cc_input_generation_t);",
        "boolsetPacing(cc_input_generation_t,booldo_pace);",
        "intpace(cc_input_generation_t);",
        "boolsendInputEvent(cc_input_generation_t,enumcc_input_eventevent,",
        "boolqueuedInputCanCommit(cc_input_generation_t,cc_stream_token_t)const;",
        "boolm_load_commit_in_progress;",
        "cc_input_generation_tm_queued_load_generation;",
        "cc_stream_token_tm_queued_stream_token;",
        "cc_input_generation_tm_active_input_generation;",
        "boolm_active_input_owner_live;",
        "cc_input_generation_tm_pending_input_generation;",
        "boolm_pending_input_owner_live;",
        "boolm_pending_input_eof_known;",
        "boolm_input_eof_known;",
        "chromecast_artwork_file_sys_t*m_httpd_file_sys;",
    )
    forbid(value, "boolm_request_load;", "voidsetHasInput(")


def validate_cast(source: str) -> None:
    value = compact(source)
    require(
        value,
        "cc_input_generation_tm_generation;",
        "cc_stream_token_tm_next_stream_token;",
        "cc_stream_token_tm_stream_token;",
        "cc_input_generation_tchain_generation;",
        "cc_stream_token_tchain_stream_token;",
        "cc_input_generation_tremote_generation;",
        "boolchain_claimed;",
        "boolgeneration_rejected;",
        "cc_input_generation_tgeneration;",
    )
    forbid(value, "cc_has_input", "access_out_live.clear(")

    stop = compact(function_body(
        source, "void sout_access_out_sys_t::stop()"
    ))
    ordered(
        stop,
        "clearUnlocked();",
        "m_intf->setPacing(m_generation,false);",
        "m_generation=0;",
        "m_stream_token=0;",
        "m_client=NULL;",
        "vlc_fifo_Unlock(m_fifo);",
        "vlc_fifo_Signal(m_fifo);",
    )

    prepare = compact(function_body(
        source, "cc_stream_token_t sout_access_out_sys_t::prepare("
    ))
    ordered(
        prepare,
        "clearUnlocked();",
        "m_intf->setPacing(m_generation,false);",
        "m_generation=generation;",
        "do++m_next_stream_token;while(m_next_stream_token==0);",
        "m_stream_token=m_next_stream_token;",
        "m_client=NULL;",
        "m_eof=false;",
        "returnm_stream_token;",
    )

    url = compact(function_body(
        source, "int sout_access_out_sys_t::url_cb("
    ))
    ordered(
        url,
        "vlc_fifo_Lock(m_fifo);",
        "constchar*query_args=reinterpret_cast<constchar*>(query->psz_args);",
        "!chromecast_stream_query_matches(query_args,m_stream_token)",
        "answer->i_status=410;",
        "vlc_fifo_Unlock(m_fifo);",
        "restoreCopy();",
        "m_client=cl;",
        "while(m_client==cl",
        "if(m_client==cl&&vlc_fifo_GetBytes(m_fifo)>0)",
    )
    if url.count("m_client==cl") < 2:
        raise AssertionError("HTTP callbacks must revalidate the exact client")
    forbid(url, "if(m_client&&", "while(m_client&&")

    add = compact(function_body(
        source, "static void *Add(sout_stream_t *p_stream,"
    ))
    ordered(
        add,
        "constcc_input_generation_tgeneration=p_sys->p_intf->generationForNewStream();",
        "if(generation==0)",
        "for(constsout_stream_id_sys_t*existing:p_sys->streams)",
        "if(existing->generation!=generation)",
        "if(p_sys->streams.empty())p_sys->cc_eof=false;",
        "p_sys_id->generation=generation;",
    )

    start = compact(function_body(
        source, "bool sout_stream_sys_t::startSoutChain("
    ))
    ordered(
        start,
        "!p_intf->mayBuildChain(generation)",
        "if(stream->generation!=generation)",
        "chain_generation=generation;",
        "chain_stream_token=access_out_live.prepare(p_stream,generation,mime);",
        "if(chain_stream_token==0)",
        "p_out=sout_StreamChainNew(",
        "if(!p_intf->setRetryOnFail(generation,transcodingCanFallback()))",
    )
    forbid(start, "es_format_Clean(")

    proxy = compact(function_body(
        source, "static int ProxySend("
    ))
    ordered(
        proxy,
        "p_sys->p_intf->setHasInput(p_sys->chain_generation,p_sys->chain_stream_token,p_sys->mime)",
        "p_sys->generation_rejected=true;",
        "returnVLC_EGENERIC;",
        "p_sys->remote_generation=p_sys->chain_generation;",
        "p_sys->chain_claimed=true;",
    )

    send = compact(function_body(source, "static int Send("))
    require(
        send,
        "p_sys->chain_generation==0",
        "p_sys->chain_stream_token==0",
        "id->generation!=p_sys->chain_generation",
        "if(p_sys->generation_rejected)",
        "p_sys->stopSoutChain(p_stream);",
        "p_sys->access_out_live.stop();",
    )

    callback = compact(function_body(
        source, "static void on_input_event_cb("
    ))
    ordered(
        callback,
        "boolgeneration_known=false;",
        "for(constsout_stream_id_sys_t*stream:p_sys->streams)",
        "if(stream->generation==generation)",
        "if(!generation_known)",
        "return;",
        "switch(event)",
    )
    forbid(
        callback,
        "generation==p_sys->remote_generation",
        "p_sys->p_intf->mayBuildChain(generation)",
    )
    require(
        callback,
        "caseCC_INPUT_EVENT_EOF:",
        "p_sys->cc_eof=arg.eof;",
        "caseCC_INPUT_EVENT_RETRY:",
        "p_sys->access_out_live.stop();",
    )

    close = compact(function_body(
        source, "static void Close(sout_stream_t *p_stream)"
    ))
    ordered(
        close,
        "p_intf->setOnInputEventCb(NULL,NULL);",
        "p_sys->access_out_live.stop();",
        "deletep_sys;",
        "deletep_intf;",
        "httpd_HostDelete(httpd_host);",
    )


def validate_controller(source: str) -> None:
    value = compact(source)
    require(
        value,
        "structchromecast_artwork_file_sys_t{intf_sys_t*owner;conststd::stringsource_artwork;};",
    )
    destructor = compact(function_body(source, "intf_sys_t::~intf_sys_t()"))
    ordered(
        destructor,
        "if(m_httpd_file)httpd_FileDelete(m_httpd_file);",
        "deletem_httpd_file_sys;",
        "free(m_art_url);",
    )

    artwork_callback = compact(function_body(
        source, "static int httpd_file_fill_cb( httpd_file_sys_t *data, httpd_file_t *,"
    ))
    require(
        artwork_callback,
        "static_cast<chromecast_artwork_file_sys_t*>((void*)data)",
        "file_sys->owner->httpd_file_fill(file_sys->source_artwork,pp_data,pi_data)",
    )

    artwork = compact(function_body(
        source, "bool intf_sys_t::prepareHttpArtwork("
    ))
    direct_statement_match(
        function_body(source, "bool intf_sys_t::prepareHttpArtwork("),
        PREPARE_ARTWORK_PREFIX,
        "artwork generation/token commit prefix",
        reject_prior_transfer=True,
    )
    direct_statement_match(
        function_body(source, "bool intf_sys_t::prepareHttpArtwork("),
        FINAL_TRUE_RETURN,
        "artwork transaction terminal publication",
        reject_prior_transfer=True,
    )
    ordered(
        artwork,
        "if(!queuedInputCanCommit(generation,stream_token))returnfalse;",
        "conststd::stringsource_artwork(psz_art);",
        "new(std::nothrow)chromecast_artwork_file_sys_t{this,source_artwork}",
        "m_lock.unlock();",
        "httpd_FileNew(",
        "m_lock.lock();",
        "constbooltransaction_valid=queuedInputCanCommit(generation,stream_token)",
        "m_httpd_file=candidate;",
        "m_httpd_file_sys=candidate_file_sys;",
        "httpd_FileDelete(old_httpd_file);",
        "deleteold_file_sys;",
        "if(!queuedInputCanCommit(generation,stream_token))returnfalse;",
        "vlc_meta_Set(meta,vlc_meta_ArtworkURL,published.c_str());",
    )
    require(
        artwork,
        "source_artwork==current_artwork",
        "route==m_art_http_ip",
    )

    queued_commit = compact(function_body(
        source, "bool intf_sys_t::queuedInputCanCommit("
    ))
    require(
        queued_commit,
        "queuedInputCanLoad(generation,stream_token)",
        "!m_request_stop",
        "m_state!=Stopping",
        "!isStatePlaying()",
        "isStateReady()&&!m_appTransportId.empty()",
        "m_communication!=NULL",
        "m_communication->isConnected()",
    )

    load_source = function_body(source, "void intf_sys_t::tryLoad()")
    load = compact(load_source)
    require(load, "for(;;){")
    loop_match = direct_statement_match(
        load_source,
        TRY_LOAD_LOOP,
        "tryLoad transaction loop",
        reject_prior_transfer=True,
    )
    loop = braced_body(
        load_source,
        loop_match.end() - 1,
        "tryLoad transaction loop",
    )
    direct_statement_match(
        loop,
        TRY_LOAD_COMMIT_PIPELINE,
        "tryLoad LOAD attribution/state pipeline",
        reject_prior_transfer=True,
    )
    ordered(
        load,
        "constcc_input_generation_tgeneration=m_queued_load_generation;",
        "constcc_stream_token_tstream_token=m_queued_stream_token;",
        "if(!queuedInputCanLoad(generation,stream_token))",
        "if(m_request_stop||m_state==Stopping)return;",
        "if(isStatePlaying())",
        "doStop();",
        "if(isStateReady()&&m_appTransportId.empty())",
        "m_state=Connected;",
        "m_load_commit_in_progress=true;",
        "prepareHttpArtwork(generation,stream_token,&published_artwork_url)",
        "m_load_commit_in_progress=false;",
        "if(m_queued_load_generation!=0)continue;",
        "if(generation==m_pending_input_generation)promotePendingInput();",
        "m_mime=m_queued_mime;",
        "m_art_http_url=published_artwork_url;",
        "clearQueuedInput();",
        "std::swap(m_msgQueue,empty);",
        "clearMediaSessionState();",
        "m_communication->msgPlayerLoad(m_appTransportId,stream_token,m_mime,m_meta,m_input_length)",
        "m_load_commit_in_progress=false;",
        "recordMediaRequest(chromecast_media_command::Load,request_id)",
        "m_state=Loading;",
    )

    begin = compact(function_body(
        source, "cc_input_generation_t intf_sys_t::beginInput("
    ))
    ordered(
        begin,
        "clearPendingInput();",
        "do++m_next_input_generation;",
        "while(m_next_input_generation==0||m_next_input_generation==m_active_input_generation);",
        "m_pending_input_generation=m_next_input_generation;",
        "m_pending_input_owner_live=true;",
        "m_pending_desired_paused=initially_paused;",
    )

    end = compact(function_body(
        source, "void intf_sys_t::endInput("
    ))
    require(
        end,
        "generation==m_pending_input_generation",
        "clearPendingInput();",
        "generation==m_active_input_generation",
        "m_active_input_owner_live=false;",
        "m_active_demux_enabled=false;",
        "m_pace=false;",
        "m_on_paused_changed=NULL;",
        "m_pace_cond.signal();",
    )

    promote = compact(function_body(
        source, "void intf_sys_t::promotePendingInput()"
    ))
    ordered(
        promote,
        "m_active_input_generation=m_pending_input_generation;",
        "m_active_input_owner_live=m_pending_input_owner_live;",
        "m_active_demux_enabled=m_pending_demux_enabled;",
        "m_input_eof=m_pending_input_eof;",
        "m_input_eof_known=m_pending_input_eof_known;",
        "m_meta=m_pending_meta;",
        "m_pending_meta=NULL;",
        "clearPendingInput();",
        "m_pace_cond.signal();",
    )

    set_input = compact(function_body(
        source, "bool intf_sys_t::setHasInput("
    ))
    ordered(
        set_input,
        "if(stream_token==0||!inputGenerationCanLoad(generation))returnfalse;",
        "m_queued_load_generation=generation;",
        "m_queued_stream_token=stream_token;",
        "m_queued_mime=mime_type;",
        "if(isStatePlaying()&&!m_request_stop)doStop();",
        "if(m_state==Stopped&&!m_appTransportId.empty())",
        "tryLoad();",
    )
    forbid(set_input, "clearMediaSessionState();", "promotePendingInput();")

    pace = compact(function_body(
        source, "int intf_sys_t::pace(cc_input_generation_t generation)"
    ))
    require(
        pace,
        "constautopending_owner=",
        "constautoactive_owner=",
        "if(!pending_owner()&&!active_owner())returnCC_PACE_ERR;",
        "if(pending_owner()&&m_state==Dead)returnCC_PACE_ERR;",
        "while(!m_interrupted&&ret==0)",
        "should_wait=m_pending_pace||m_pending_input_eof;",
        "should_wait=!isFinishedPlaying()&&(m_pace||m_input_eof);",
        "if(pending_owner())",
        "returnret==0?CC_PACE_OK:CC_PACE_OK_WAIT;",
        "if(!active_owner())returnCC_PACE_ERR;",
        "if(m_cc_eof)returnCC_PACE_OK_ENDED;",
        "m_state==LoadFailed&&m_retry_on_fail",
    )
    if pace.count("returnret==0?CC_PACE_OK:CC_PACE_OK_WAIT;") != 2:
        raise AssertionError("pending and active pacing must share bounded wait semantics")
    if pace.count("returnCC_PACE_OK_ENDED;") != 1:
        raise AssertionError("only receiver EOF may report Chromecast ended")
    forbid(pace, "if(m_pending_input_eof)returnCC_PACE_OK_ENDED;")

    event = compact(function_body(
        source, "bool intf_sys_t::sendInputEvent("
    ))
    require(
        event,
        "generation==m_pending_input_generation",
        "generation==m_active_input_generation",
        "if(event==CC_INPUT_EVENT_RETRY)returnfalse;",
        "input_eof_known=&m_pending_input_eof_known;",
        "input_eof_known=&m_input_eof_known;",
        "if(!*input_eof_known||*input_eof!=arg.eof)",
        "*input_eof_known=true;",
        "on_input_event(data,generation,event,arg);",
    )

    media = compact(function_body(
        source, "bool intf_sys_t::processMediaMessage("
    ))
    require(
        media,
        "chromecast_initial_load_is_pending(m_played_once,m_state==Loading||m_state==Buffering,new_player_state,extended_player_state,idle_reason)",
        "if(receiver_loading)",
        'idle_reason=="INTERRUPTED"',
        'idle_reason=="ERROR"',
        'idle_reason=="CANCELLED"',
        'idle_reason=="FINISHED"',
        "constboollocal_stop=m_state==Stopping||m_request_stop||command==chromecast_media_command::Stop;",
        "m_cc_eof=finished&&!local_stop;",
        "setState(failed_load?LoadFailed:local_stop?Ready:finished?Ready:Stopped);",
    )
    forbid(
        media,
        "command==chromecast_media_command::Load&&receiver_loading",
    )

    request_stop = compact(function_body(
        source, "bool intf_sys_t::requestPlayerStop("
    ))
    ordered(
        request_stop,
        "if(generation==0)returnfalse;",
        "if(generation==m_queued_load_generation)",
        "clearQueuedInput();",
        "if(generation!=m_active_input_generation)returncanceled_queued_load;",
        "m_retry_on_fail=false;",
        "doStop();",
    )

    state = compact(function_body(source, "void intf_sys_t::setState("))
    ordered(
        state,
        "if(state==Stopped&&m_queued_load_generation!=0&&!m_appTransportId.empty())state=Ready;",
        "m_state=state;",
        "caseConnected:",
        "caseReady:",
        "tryLoad();",
        "caseLoadFailed:",
        "caseTakenOver:",
    )

    set_meta = compact(function_body(
        source, "bool intf_sys_t::setMeta("
    ))
    require(
        set_meta,
        "generation==m_pending_input_generation",
        "generation==m_active_input_generation",
        "if(p_meta!=NULL)vlc_meta_Delete(p_meta);",
        "if(*slot!=NULL)vlc_meta_Delete(*slot);",
    )
    expected_set_meta = (
        "{vlc::threads::mutex_lockerlock(m_lock);vlc_meta_t**slot;"
        "if(generation!=0&&generation==m_pending_input_generation&&"
        "m_pending_input_owner_live)slot=&m_pending_meta;"
        "elseif(generation!=0&&generation==m_active_input_generation&&"
        "m_active_input_owner_live)slot=&m_meta;else{if(p_meta!=NULL)"
        "vlc_meta_Delete(p_meta);returnfalse;}if(*slot!=NULL)"
        "vlc_meta_Delete(*slot);*slot=p_meta;if(slot==&m_meta)"
        "m_art_http_url.clear();returntrue;}"
    )
    if set_meta != expected_set_meta:
        raise AssertionError(
            "setMeta must preserve exact generation ownership and metadata transfer"
        )
    set_length = compact(function_body(
        source, "bool intf_sys_t::setInputLength("
    ))
    expected_set_length = (
        "{vlc::threads::mutex_lockerlock(m_lock);"
        "if(generation!=0&&generation==m_pending_input_generation&&"
        "m_pending_input_owner_live){m_pending_input_length=length;"
        "returntrue;}if(generation!=0&&generation==m_active_input_generation&&"
        "m_active_input_owner_live){m_input_length=length;returntrue;}"
        "returnfalse;}"
    )
    if set_length != expected_set_length:
        raise AssertionError(
            "setInputLength must preserve exact generation-bound duration publication"
        )
    forbid(value, "m_request_load")


def validate_demux(source: str) -> None:
    value = compact(source)
    require(
        value,
        "cc_input_generation_tm_generation;",
        "m_generation=p_renderer->pf_begin_input(p_renderer->p_opaque,m_cached_paused);",
        "p_renderer->pf_end_input(p_renderer->p_opaque,m_generation);",
        "p_renderer->pf_set_meta(p_renderer->p_opaque,m_generation,p_meta);",
        "p_renderer->pf_set_input_length(p_renderer->p_opaque,m_generation,m_length);",
        "p_renderer->pf_set_demux_enabled(p_renderer->p_opaque,m_generation,true,on_paused_changed_cb,p_demux);",
        "p_renderer->pf_send_input_event(p_renderer->p_opaque,m_generation,CC_INPUT_EVENT_EOF,cc_input_arg{false});",
        "p_renderer->pf_pace(p_renderer->p_opaque,m_generation)",
        "p_renderer->pf_get_time(p_renderer->p_opaque,m_generation)",
        "p_renderer->pf_set_pause_state(p_renderer->p_opaque,m_generation,paused)",
        "if(!m_enabled&&i_query!=DEMUX_FILTER_ENABLE)",
        "m_cached_paused=va_arg(ap,int)!=0;",
    )
    destructor = compact(function_body(source, "~demux_cc()"))
    ordered(destructor, "deinit();", "endInput();")
    control = compact(function_body(
        source, "int Control( demux_t *, int i_query"
    ))
    ordered(
        control,
        "caseDEMUX_FILTER_ENABLE:",
        "beginInput();",
        "m_enabled=true;",
        "init();",
        "caseDEMUX_FILTER_DISABLE:",
        "deinit();",
        "endInput();",
        "m_enabled=false;",
        "p_renderer=NULL;",
    )
    init = function_body(source, "void init()")
    direct_statement_match(
        init,
        DEMUX_DURATION_PUBLICATION,
        "generation-bound duration query/publication pipeline",
        reject_prior_transfer=True,
    )
    direct_statement_match(
        init,
        DEMUX_INIT_TERMINAL_RESET,
        "demux initialization terminal clock reset",
        reject_prior_transfer=True,
    )


def validate_sources(sources: Mapping[str, str]) -> None:
    if set(sources) != set(PATHS):
        raise AssertionError("0037 source inventory is not exact")
    validate_common(sources["common"])
    validate_protocol(sources["protocol"])
    validate_communication(sources["header"], sources["communication"])
    validate_header(sources["header"])
    validate_cast(sources["cast"])
    validate_controller(sources["controller"])
    validate_demux(sources["demux"])


def patch_sections(patch: str) -> list[tuple[str, list[str]]]:
    lines = patch.splitlines(keepends=True)
    sections: list[tuple[str, list[str]]] = []
    index = 0
    while index < len(lines):
        match = re.fullmatch(r"diff --git a/(.+) b/(.+)\n", lines[index])
        if match is None:
            raise AssertionError("0037 patch has content outside diff sections")
        if match.group(1) != match.group(2):
            raise AssertionError("0037 patch cannot rename a VLC path")
        path = match.group(1)
        end = index + 1
        while end < len(lines) and not lines[end].startswith("diff --git "):
            end += 1
        sections.append((path, lines[index:end]))
        index = end
    return sections


def validate_patch(patch: str) -> list[tuple[str, list[str]]]:
    actual_sha = hashlib.sha256(patch.encode("utf-8")).hexdigest()
    if actual_sha != EXPECTED_PATCH_SHA256:
        raise AssertionError(
            f"0037 patch hash changed: expected {EXPECTED_PATCH_SHA256}, "
            f"got {actual_sha}"
        )
    sections = patch_sections(patch)
    paths = tuple(path for path, _ in sections)
    if paths != PATCH_PATHS:
        raise AssertionError(
            f"0037 patch path inventory changed: expected {PATCH_PATHS!r}, "
            f"got {paths!r}"
        )
    for path, lines in sections:
        if f"--- a/{path}\n" not in lines or f"+++ b/{path}\n" not in lines:
            raise AssertionError(f"0037 patch lacks exact old/new path for {path}")
    return sections


HUNK = re.compile(
    r"@@ -([0-9]+)(?:,([0-9]+))? \+([0-9]+)(?:,([0-9]+))? @@"
)


def reverse_section(final_source: str, lines: list[str], path: str) -> str:
    final_lines = final_source.splitlines(keepends=True)
    output: list[str] = []
    cursor = 0
    index = next(
        (position for position, line in enumerate(lines)
         if line.startswith("@@ ")),
        -1,
    )
    if index < 0:
        raise AssertionError(f"0037 patch has no hunks for {path}")

    while index < len(lines):
        match = HUNK.match(lines[index])
        if match is None:
            raise AssertionError(f"invalid 0037 hunk header for {path}")
        old_start = int(match.group(1))
        old_count = int(match.group(2) or "1")
        new_start = int(match.group(3))
        new_count = int(match.group(4) or "1")
        target = max(new_start - 1, 0)
        if target < cursor:
            raise AssertionError(f"overlapping 0037 hunks for {path}")
        output.extend(final_lines[cursor:target])
        cursor = target
        old_used = 0
        new_used = 0
        index += 1
        while index < len(lines) and not lines[index].startswith("@@ "):
            line = lines[index]
            if line.startswith("\\ No newline"):
                raise AssertionError(f"unsupported no-newline marker in {path}")
            marker = line[:1]
            payload = line[1:]
            if marker in (" ", "+"):
                if cursor >= len(final_lines) or final_lines[cursor] != payload:
                    raise AssertionError(
                        f"0037 reverse replay disagrees with final source {path}"
                    )
                cursor += 1
                new_used += 1
            if marker in (" ", "-"):
                output.append(payload)
                old_used += 1
            if marker not in (" ", "+", "-"):
                raise AssertionError(f"invalid 0037 hunk line in {path}")
            index += 1
        if old_used != old_count or new_used != new_count:
            raise AssertionError(
                f"0037 hunk counts disagree for {path}: "
                f"old {old_used}/{old_count}, new {new_used}/{new_count}"
            )
        if old_start == 0 and old_count != 0:
            raise AssertionError(f"invalid old hunk origin for {path}")
    output.extend(final_lines[cursor:])
    return "".join(output)


def load_frozen_checker(
    checker_path: Path,
    expected_sha256: str,
    module_name: str,
    description: str,
):
    actual = hashlib.sha256(checker_path.read_bytes()).hexdigest()
    if actual != expected_sha256:
        raise AssertionError(
            f"{description} hash changed: expected {expected_sha256}, got {actual}"
        )
    spec = importlib.util.spec_from_file_location(module_name, checker_path)
    if spec is None or spec.loader is None:
        raise AssertionError(f"cannot load {description}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def validate_inherited(
    sources: Mapping[str, str],
    sections: list[tuple[str, list[str]]],
) -> tuple[int, int, int, int, int]:
    validation_dir = Path(__file__).resolve().parent
    patches_dir = validation_dir.parent
    schema_checker_path = validation_dir / "chromecast-metadata-schema-source-check.py"
    schema_patch_path = patches_dir / "0036-chromecast-metadata-schema-correctness.patch"
    warning_checker_path = validation_dir / "chromecast-metadata-warning-source-check.py"
    warning_patch_path = patches_dir / "0035-chromecast-metadata-warning.patch"

    schema_checker = load_frozen_checker(
        schema_checker_path,
        EXPECTED_SCHEMA_CHECKER_SHA256,
        "swiftvlc_chromecast_metadata_schema_0036",
        "frozen 0036 checker",
    )
    schema_patch_bytes = schema_patch_path.read_bytes()
    schema_patch_sha256 = hashlib.sha256(schema_patch_bytes).hexdigest()
    if schema_patch_sha256 != EXPECTED_SCHEMA_PATCH_SHA256:
        raise AssertionError(
            "frozen 0036 patch hash changed: expected "
            f"{EXPECTED_SCHEMA_PATCH_SHA256}, got {schema_patch_sha256}"
        )
    warning_checker_sha256 = hashlib.sha256(
        warning_checker_path.read_bytes()
    ).hexdigest()
    if warning_checker_sha256 != EXPECTED_WARNING_CHECKER_SHA256:
        raise AssertionError(
            "frozen 0035 checker hash changed: expected "
            f"{EXPECTED_WARNING_CHECKER_SHA256}, got {warning_checker_sha256}"
        )
    warning_patch_sha256 = hashlib.sha256(warning_patch_path.read_bytes()).hexdigest()
    if warning_patch_sha256 != EXPECTED_WARNING_PATCH_SHA256:
        raise AssertionError(
            "frozen 0035 patch hash changed: expected "
            f"{EXPECTED_WARNING_PATCH_SHA256}, got {warning_patch_sha256}"
        )

    # Patch 0037 may add text that duplicates one of frozen 0036's deliberately
    # fail-closed mutation fixtures. Validate the inherited 0036 production
    # contract on the actual final source, but never run its mutation harness
    # there: the harness belongs to the exact predecessor it was frozen with.
    final_schema_sources = {
        key: sources[key]
        for key in schema_checker.PATHS
    }
    schema_checker.validate_sources(final_schema_sources)

    reconstructed = dict(sources)
    by_relative = {relative: key for key, relative in PATHS.items()}
    for path, lines in sections:
        key = by_relative[path]
        reconstructed[key] = reverse_section(reconstructed[key], lines, path)

    predecessor_schema_sources = {
        key: reconstructed[key]
        for key in schema_checker.PATHS
    }
    schema_patch = schema_patch_bytes.decode("utf-8")
    schema_checker.validate_patch(schema_patch)
    schema_checker.validate_sources(predecessor_schema_sources)
    schema_source_mutations = schema_checker.run_source_mutations(
        predecessor_schema_sources
    )
    schema_patch_mutations = schema_checker.run_patch_mutations(schema_patch)
    warning_source_mutations, warning_patch_mutations = (
        schema_checker.validate_frozen_0035_base(
            predecessor_schema_sources,
            warning_checker_path,
            warning_patch_path,
        )
    )

    base_checker_path = validation_dir / "chromecast-state-source-check.py"
    base_checker = load_frozen_checker(
        base_checker_path,
        EXPECTED_BASE_CHECKER_SHA256,
        "swiftvlc_chromecast_state_0034",
        "frozen 0034 checker",
    )
    base_sources = {
        key: reconstructed[key]
        for key in base_checker.PATHS
    }
    base_checker.validate(base_sources)
    base_mutations = base_checker.run_negative_mutations(base_sources)
    return (
        schema_source_mutations,
        schema_patch_mutations,
        warning_source_mutations,
        warning_patch_mutations,
        base_mutations,
    )


def replace_once(
    sources: Mapping[str, str], key: str, old: str, new: str
) -> dict[str, str]:
    source = sources[key]
    if source.count(old) != 1:
        raise AssertionError(
            f"mutation fixture {key}:{old!r} must occur exactly once; "
            f"found {source.count(old)}"
        )
    mutated = dict(sources)
    mutated[key] = source.replace(old, new, 1)
    return mutated


def run_source_mutations(sources: Mapping[str, str]) -> int:
    mutations = (
        ("common", "typedef uint64_t cc_input_generation_t;",
         "typedef uint32_t cc_input_generation_t;"),
        ("common", "typedef uint64_t cc_stream_token_t;",
         "typedef uint32_t cc_stream_token_t;"),
        ("protocol", "&& idle_reason.empty();", "|| idle_reason.empty();"),
        ("protocol", "if (expected_stream_token == 0", "if (false"),
        ("protocol", "value.size() > 1 && value.front() == '0'", "false"),
        ("protocol",
         "parsed > (std::numeric_limits<uint64_t>::max() - digit) / 10",
         "false"),
        ("communication",
         "server_base_url, m_serverPath, stream_token",
         "server_base_url, m_serverPath, 1"),
        ("communication",
         "    const std::string chromecast_url = chromecast_stream_url(\n",
         "    return {};\n"
         "    const std::string chromecast_url = chromecast_stream_url(\n"),
        ("communication",
         "                                               vlc_tick_t input_length )\n"
         "{\n"
         "    std::stringstream ss;",
         "                                               vlc_tick_t input_length )\n"
         "{\n"
         "    if (true) return {};\n"
         "    std::stringstream ss;"),
        ("communication",
         "                                               vlc_tick_t input_length )\n"
         "{\n"
         "    std::stringstream ss;",
         "                                               vlc_tick_t input_length )\n"
         "{\n"
         "    if (1) { return {}; }\n"
         "    std::stringstream ss;"),
        ("communication",
         "    const std::string payload = chromecast_load_payload(media, id);\n",
         "    const std::string payload = chromecast_load_payload(media, id);\n"
         "    return kInvalidId;\n"),
        ("cast",
         "!chromecast_stream_query_matches(query_args, m_stream_token)",
         "false"),
        ("cast", "m_client == cl && vlc_fifo_GetBytes(m_fifo) < i_min_buffer",
         "m_client && vlc_fifo_GetBytes(m_fifo) < i_min_buffer"),
        ("cast", "m_stream_token = 0;", "/* stale token retained */"),
        ("cast", "id->generation != p_sys->chain_generation", "false"),
        ("cast", "bool generation_known = false;",
         "bool generation_known = generation == p_sys->remote_generation;"),
        ("cast", "p_intf->setOnInputEventCb(NULL, NULL);",
         "/* callback left attached */"),
        ("controller", "const std::string source_artwork;",
         "std::string source_artwork;"),
        ("controller",
         "    published_url->clear();\n"
         "    if (!queuedInputCanCommit(generation, stream_token))",
         "    published_url->clear();\n"
         "    return false;\n"
         "    if (!queuedInputCanCommit(generation, stream_token))"),
        ("controller",
         "    if (!queuedInputCanCommit(generation, stream_token))\n"
         "        return false;\n\n"
         "    const auto input_meta",
         "    if (!queuedInputCanCommit(generation, stream_token))\n"
         "        return false;\n"
         "    return true;\n\n"
         "    const auto input_meta"),
        ("controller",
         "    if (!queuedInputCanCommit(generation, stream_token))\n"
         "        return false;\n\n"
         "    const auto input_meta",
         "    if (!queuedInputCanCommit(generation, stream_token))\n"
         "        return false;\n"
         "    if (true) return false;\n\n"
         "    const auto input_meta"),
        ("controller",
         "void intf_sys_t::tryLoad()\n{\n    for (;;)",
         "void intf_sys_t::tryLoad()\n{\n    return;\n    for (;;)") ,
        ("controller",
         "void intf_sys_t::tryLoad()\n{\n    for (;;)",
         "void intf_sys_t::tryLoad()\n{\n"
         "    if (!false) return;\n"
         "    for (;;)") ,
        ("controller",
         "                                           m_mime, m_meta, m_input_length);\n"
         "        m_load_commit_in_progress = false;",
         "                                           m_mime, m_meta, m_input_length);\n"
         "        return;\n"
         "        m_load_commit_in_progress = false;"),
        ("controller",
         "bool intf_sys_t::setMeta(cc_input_generation_t generation,\n"
         "                         vlc_meta_t *p_meta)\n"
         "{\n    vlc::threads::mutex_locker lock( m_lock );",
         "bool intf_sys_t::setMeta(cc_input_generation_t generation,\n"
         "                         vlc_meta_t *p_meta)\n"
         "{\n    return false;\n"
         "    vlc::threads::mutex_locker lock( m_lock );"),
        ("controller",
         "bool intf_sys_t::setInputLength(cc_input_generation_t generation,\n"
         "                                vlc_tick_t length)\n"
         "{\n    vlc::threads::mutex_locker lock( m_lock );",
         "bool intf_sys_t::setInputLength(cc_input_generation_t generation,\n"
         "                                vlc_tick_t length)\n"
         "{\n    return true;\n"
         "    vlc::threads::mutex_locker lock( m_lock );"),
        ("controller", "&& isStateReady() && !m_appTransportId.empty()",
         "&& isStateReady() || !m_appTransportId.empty()"),
        ("controller", "if (m_queued_load_generation != 0)\n                continue;",
         "if (false)\n                continue;"),
        ("controller",
         "if (generation == m_pending_input_generation)\n"
         "            promotePendingInput();",
         "if (false)\n            promotePendingInput();"),
        ("controller", "m_queued_load_generation = generation;",
         "m_queued_load_generation = 0;"),
        ("controller", "if (isStatePlaying() && !m_request_stop)",
         "if (false)"),
        ("controller",
         "        if (m_state == Dead)\n"
         "            return CC_PACE_ERR;\n"
         "        return ret == 0 ? CC_PACE_OK : CC_PACE_OK_WAIT;",
         "        if (m_state == Dead)\n"
         "            return CC_PACE_ERR;\n"
         "        return CC_PACE_OK_ENDED;"),
        ("controller", "m_cc_eof = finished && !local_stop;",
         "m_cc_eof = finished;"),
        ("controller",
         "if (!*input_eof_known || *input_eof != arg.eof)",
         "if (*input_eof != arg.eof)"),
        ("controller", "m_active_input_owner_live = false;",
         "m_active_input_owner_live = true;"),
        ("controller", "input_eof_known = &m_pending_input_eof_known;",
         "input_eof_known = &m_input_eof_known;"),
        ("demux", "pf_end_input( p_renderer->p_opaque, m_generation );",
         "/* generation owner leaked */"),
        ("demux",
         "            });\n"
         "        p_renderer->pf_set_input_length( p_renderer->p_opaque, m_generation,",
         "            });\n"
         "        return;\n"
         "        p_renderer->pf_set_input_length( p_renderer->p_opaque, m_generation,"),
        ("demux",
         "                                         m_length );\n\n"
         "        int i_current_title;",
         "                                         m_length );\n"
         "        return;\n\n"
         "        int i_current_title;"),
        ("demux",
         "                                         m_length );\n\n"
         "        int i_current_title;",
         "                                         m_length );\n"
         "        if (true) { return; }\n\n"
         "        int i_current_title;"),
        ("demux",
         "        int i_current_title;\n"
         "        if( demux_Control",
         "        int i_current_title;\n"
         "        return;\n"
         "        if( demux_Control"),
        ("demux",
         "            }\n"
         "        }\n\n"
         "        es_out_Control( p_demux->s->out, ES_OUT_RESET_PCR );",
         "            }\n"
         "        }\n"
         "        return;\n\n"
         "        es_out_Control( p_demux->s->out, ES_OUT_RESET_PCR );"),
        ("demux",
         "        es_out_Control( p_demux->s->out, ES_OUT_RESET_PCR );\n\n"
         "        p_renderer->pf_set_demux_enabled",
         "        es_out_Control( p_demux->s->out, ES_OUT_RESET_PCR );\n"
         "        return;\n\n"
         "        p_renderer->pf_set_demux_enabled"),
        ("demux",
         "                                         on_paused_changed_cb, p_demux);\n\n"
         "        resetTimes();",
         "                                         on_paused_changed_cb, p_demux);\n"
         "        return;\n\n"
         "        resetTimes();"),
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
            "diff --git a/modules/stream_out/chromecast/cast.cpp "
            "b/modules/stream_out/chromecast/cast.cpp",
            "diff --git a/modules/stream_out/chromecast/cast.cpp "
            "b/modules/stream_out/chromecast/other.cpp",
        ),
        (
            "!chromecast_stream_query_matches(query_args, m_stream_token)",
            "false",
        ),
        (
            "m_cc_eof = finished && !local_stop;",
            "m_cc_eof = finished;",
        ),
    )
    for index, (old, new) in enumerate(mutations, 1):
        if old not in patch:
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
        source_path = root / relative
        if not source_path.is_file():
            raise SystemExit(f"missing 0037 validation input: {source_path}")
        sources[key] = source_path.read_text(encoding="utf-8")

    patch = arguments.patch.read_text(encoding="utf-8")
    sections = validate_patch(patch)
    validate_sources(sources)
    (
        schema_source_mutations,
        schema_patch_mutations,
        warning_source_mutations,
        warning_patch_mutations,
        base_mutations,
    ) = validate_inherited(sources, sections)
    source_mutations = run_source_mutations(sources)
    patch_mutations = run_patch_mutations(patch)

    print(
        "PASS Chromecast 0037 source proof: "
        f"files={len(sources)} "
        f"inherited_0036_source_mutations={schema_source_mutations} "
        f"inherited_0036_patch_mutations={schema_patch_mutations} "
        f"inherited_0035_source_mutations={warning_source_mutations} "
        f"inherited_0035_patch_mutations={warning_patch_mutations} "
        f"inherited_0034_mutations={base_mutations} "
        f"source_mutations={source_mutations} "
        f"patch_mutations={patch_mutations}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
