#!/usr/bin/env python3
"""Capture read-only, receiver-originated Chromecast playback evidence.

The probe opens a separate Cast-v2 TLS channel beside VLC's sender. It never
launches, loads, seeks, pauses, plays, stops, or changes volume. Its complete
write vocabulary is the device-auth challenge plus CONNECT, GET_STATUS, and
heartbeat PONG messages.

Google's Cast media protocol says BUFFERING does not advance currentTime and
identifies every playback with a receiver-issued mediaSessionId. This probe
therefore treats the receiver's correlated MEDIA_STATUS replies as the oracle;
local SwiftVLC/libVLC state is deliberately absent from the pass decision.

Protocol references:
https://developers.google.com/cast/docs/media/messages
https://chromium.googlesource.com/chromium/src/+/main/extensions/common/api/cast_channel/cast_channel.proto
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import math
import secrets
import socket
import ssl
import struct
import sys
import time
from pathlib import Path
from typing import Any, Callable, Sequence

CAST_PORT = 8009
# Google Cast caps the complete CastMessage protobuf carried by the four-byte
# transport frame at 64 KiB. Mirror libVLC's production boundary exactly so
# lab evidence cannot accept traffic the wrapper must reject.
MAX_FRAME_BYTES = 64 * 1024
DEFAULT_MEDIA_RECEIVER_APP_ID = "CC1AD845"
PLATFORM_RECEIVER_ID = "receiver-0"
NAMESPACE_DEVICE_AUTH = "urn:x-cast:com.google.cast.tp.deviceauth"
NAMESPACE_CONNECTION = "urn:x-cast:com.google.cast.tp.connection"
NAMESPACE_HEARTBEAT = "urn:x-cast:com.google.cast.tp.heartbeat"
NAMESPACE_RECEIVER = "urn:x-cast:com.google.cast.receiver"
NAMESPACE_MEDIA = "urn:x-cast:com.google.cast.media"
ALLOWED_PLAYER_STATES = frozenset({"IDLE", "PLAYING", "PAUSED", "BUFFERING"})
ALLOWED_OUTBOUND_JSON_TYPES = frozenset({"CONNECT", "GET_STATUS", "PONG"})


class ProbeError(RuntimeError):
    """Receiver evidence could not be captured without weakening its meaning."""


def encode_varint(value: int) -> bytes:
    if value < 0:
        raise ValueError("protobuf varints must be non-negative")
    encoded = bytearray()
    while value > 0x7F:
        encoded.append((value & 0x7F) | 0x80)
        value >>= 7
    encoded.append(value)
    return bytes(encoded)


def decode_varint(payload: bytes, offset: int = 0) -> tuple[int, int]:
    value = 0
    shift = 0
    for _ in range(10):
        if offset >= len(payload):
            raise ProbeError("truncated protobuf varint")
        byte = payload[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte & 0x80 == 0:
            return value, offset
        shift += 7
    raise ProbeError("protobuf varint exceeds 64 bits")


def encode_varint_field(number: int, value: int) -> bytes:
    return encode_varint((number << 3) | 0) + encode_varint(value)


def encode_bytes_field(number: int, value: bytes) -> bytes:
    return encode_varint((number << 3) | 2) + encode_varint(len(value)) + value


def protobuf_fields(payload: bytes) -> list[tuple[int, int, int | bytes]]:
    fields: list[tuple[int, int, int | bytes]] = []
    offset = 0
    while offset < len(payload):
        key, offset = decode_varint(payload, offset)
        number = key >> 3
        wire_type = key & 0x07
        if number == 0:
            raise ProbeError("protobuf field number zero is invalid")
        if wire_type == 0:
            value, offset = decode_varint(payload, offset)
        elif wire_type == 1:
            if offset + 8 > len(payload):
                raise ProbeError("truncated protobuf fixed64 field")
            value = payload[offset : offset + 8]
            offset += 8
        elif wire_type == 2:
            length, offset = decode_varint(payload, offset)
            end = offset + length
            if end > len(payload):
                raise ProbeError("truncated protobuf length-delimited field")
            value = payload[offset:end]
            offset = end
        elif wire_type == 5:
            if offset + 4 > len(payload):
                raise ProbeError("truncated protobuf fixed32 field")
            value = payload[offset : offset + 4]
            offset += 4
        else:
            raise ProbeError(f"unsupported protobuf wire type {wire_type}")
        fields.append((number, wire_type, value))
    return fields


def required_single_field(
    fields: Sequence[tuple[int, int, int | bytes]],
    number: int,
    wire_type: int,
    name: str,
) -> int | bytes:
    values = [
        value for field, wire, value in fields if field == number and wire == wire_type
    ]
    if len(values) != 1:
        raise ProbeError(f"CastMessage requires exactly one {name} field")
    return values[0]


@dataclasses.dataclass(frozen=True)
class CastMessage:
    source_id: str
    destination_id: str
    namespace: str
    payload_type: int
    payload: bytes

    def json_payload(self) -> dict[str, Any]:
        if self.payload_type != 0:
            raise ProbeError(f"{self.namespace} message is not a UTF-8 payload")
        try:
            value = json.loads(self.payload.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as error:
            raise ProbeError(f"invalid JSON in {self.namespace}: {error}") from error
        if not isinstance(value, dict):
            raise ProbeError(f"{self.namespace} payload must be a JSON object")
        return value


def encode_cast_message(message: CastMessage) -> bytes:
    if message.payload_type not in (0, 1):
        raise ValueError("CastMessage payload_type must be STRING(0) or BINARY(1)")
    if not message.source_id or not message.destination_id or not message.namespace:
        raise ValueError("CastMessage routing fields must be non-empty")
    payload_field = 6 if message.payload_type == 0 else 7
    return b"".join(
        (
            encode_varint_field(1, 0),
            encode_bytes_field(2, message.source_id.encode("utf-8")),
            encode_bytes_field(3, message.destination_id.encode("utf-8")),
            encode_bytes_field(4, message.namespace.encode("utf-8")),
            encode_varint_field(5, message.payload_type),
            encode_bytes_field(payload_field, message.payload),
        )
    )


def decode_cast_message(payload: bytes) -> CastMessage:
    fields = protobuf_fields(payload)
    version = required_single_field(fields, 1, 0, "protocol_version")
    if version != 0:
        raise ProbeError(f"unsupported Cast protocol version {version}")

    def text_field(number: int, name: str) -> str:
        raw = required_single_field(fields, number, 2, name)
        assert isinstance(raw, bytes)
        try:
            value = raw.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ProbeError(f"CastMessage {name} is not UTF-8") from error
        if not value:
            raise ProbeError(f"CastMessage {name} is empty")
        return value

    payload_type = required_single_field(fields, 5, 0, "payload_type")
    assert isinstance(payload_type, int)
    if payload_type not in (0, 1):
        raise ProbeError(f"unsupported Cast payload type {payload_type}")
    payload_field = 6 if payload_type == 0 else 7
    message_payload = required_single_field(fields, payload_field, 2, "payload")
    assert isinstance(message_payload, bytes)
    other_payload_field = 7 if payload_type == 0 else 6
    if any(field == other_payload_field for field, _, _ in fields):
        raise ProbeError("CastMessage carries both UTF-8 and binary payloads")
    return CastMessage(
        source_id=text_field(2, "source_id"),
        destination_id=text_field(3, "destination_id"),
        namespace=text_field(4, "namespace"),
        payload_type=payload_type,
        payload=message_payload,
    )


def frame_cast_message(message: CastMessage) -> bytes:
    payload = encode_cast_message(message)
    if len(payload) > MAX_FRAME_BYTES:
        raise ProbeError("outbound CastMessage exceeds the frame-size limit")
    return struct.pack(">I", len(payload)) + payload


def device_auth_outcome(payload: bytes) -> str:
    fields = protobuf_fields(payload)
    responses = [value for field, wire, value in fields if field == 2 and wire == 2]
    errors = [value for field, wire, value in fields if field == 3 and wire == 2]
    if len(responses) == 1 and not errors:
        response = responses[0]
        assert isinstance(response, bytes)
        nested = protobuf_fields(response)
        signatures = [
            value for field, wire, value in nested if field == 1 and wire == 2
        ]
        certificates = [
            value for field, wire, value in nested if field == 2 and wire == 2
        ]
        if (
            len(signatures) == 1
            and isinstance(signatures[0], bytes)
            and signatures[0]
            and len(certificates) == 1
            and isinstance(certificates[0], bytes)
            and certificates[0]
        ):
            return "response"
        return "invalid"
    if len(errors) == 1 and not responses:
        nested = protobuf_fields(errors[0]) if isinstance(errors[0], bytes) else []
        codes = [value for field, wire, value in nested if field == 1 and wire == 0]
        return f"error:{codes[0] if len(codes) == 1 else 'unknown'}"
    return "invalid"


def require_int(value: Any, name: str, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ProbeError(f"{name} must be an integer")
    if positive and value <= 0:
        raise ProbeError(f"{name} must be positive")
    return value


def require_number(value: Any, name: str, *, nonnegative: bool = False) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ProbeError(f"{name} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise ProbeError(f"{name} must be finite")
    if nonnegative and result < 0:
        raise ProbeError(f"{name} must be non-negative")
    return result


@dataclasses.dataclass(frozen=True)
class ReceiverApplication:
    app_id: str
    session_id: str
    transport_id: str
    display_name: str | None


def select_receiver_application(
    response: dict[str, Any], expected_app_id: str
) -> ReceiverApplication:
    status = response.get("status")
    if not isinstance(status, dict):
        raise ProbeError("RECEIVER_STATUS has no status object")
    applications = status.get("applications")
    if not isinstance(applications, list):
        raise ProbeError("RECEIVER_STATUS has no applications array")
    matches = [
        item
        for item in applications
        if isinstance(item, dict) and item.get("appId") == expected_app_id
    ]
    if len(matches) != 1:
        raise ProbeError(
            f"expected exactly one running {expected_app_id} receiver app, found {len(matches)}"
        )
    application = matches[0]
    session_id = application.get("sessionId")
    transport_id = application.get("transportId")
    display_name = application.get("displayName")
    if not isinstance(session_id, str) or not session_id:
        raise ProbeError("receiver application has no sessionId")
    if not isinstance(transport_id, str) or not transport_id:
        raise ProbeError("receiver application has no transportId")
    if display_name is not None and not isinstance(display_name, str):
        raise ProbeError("receiver application displayName is not a string")
    return ReceiverApplication(
        app_id=expected_app_id,
        session_id=session_id,
        transport_id=transport_id,
        display_name=display_name,
    )


@dataclasses.dataclass(frozen=True)
class MediaSample:
    host_monotonic_offset_seconds: float
    request_id: int
    media_session_id: int
    player_state: str
    current_time_seconds: float
    playback_rate: float
    content_id: str | None
    active_track_ids: tuple[int, ...]
    idle_reason: str | None

    def evidence(self) -> dict[str, Any]:
        return {
            "hostMonotonicOffsetSeconds": round(self.host_monotonic_offset_seconds, 6),
            "requestId": self.request_id,
            "mediaSessionId": self.media_session_id,
            "playerState": self.player_state,
            "currentTimeSeconds": self.current_time_seconds,
            "playbackRate": self.playback_rate,
            "contentId": self.content_id,
            "activeTrackIds": list(self.active_track_ids),
            "idleReason": self.idle_reason,
        }


def parse_media_sample(
    response: dict[str, Any], request_id: int, host_offset: float
) -> MediaSample:
    statuses = response.get("status")
    if not isinstance(statuses, list) or len(statuses) != 1:
        count = len(statuses) if isinstance(statuses, list) else 0
        raise ProbeError(
            f"MEDIA_STATUS must contain exactly one session, found {count}"
        )
    status = statuses[0]
    if not isinstance(status, dict):
        raise ProbeError("MEDIA_STATUS session is not an object")
    media_session_id = require_int(
        status.get("mediaSessionId"), "mediaSessionId", positive=True
    )
    player_state = status.get("playerState")
    if player_state not in ALLOWED_PLAYER_STATES:
        raise ProbeError(f"unsupported receiver playerState {player_state!r}")
    current_time = require_number(
        status.get("currentTime"), "currentTime", nonnegative=True
    )
    playback_rate = require_number(
        status.get("playbackRate"), "playbackRate", nonnegative=True
    )
    media = status.get("media")
    content_id: str | None = None
    if media is not None:
        if not isinstance(media, dict):
            raise ProbeError("MEDIA_STATUS media field is not an object")
        raw_content_id = media.get("contentId")
        if raw_content_id is not None:
            if not isinstance(raw_content_id, str) or not raw_content_id:
                raise ProbeError("MEDIA_STATUS contentId is not a non-empty string")
            content_id = raw_content_id
    raw_track_ids = status.get("activeTrackIds", [])
    if not isinstance(raw_track_ids, list):
        raise ProbeError("activeTrackIds is not an array")
    active_track_ids = tuple(
        require_int(value, "activeTrackIds entry", positive=True)
        for value in raw_track_ids
    )
    idle_reason = status.get("idleReason")
    if idle_reason is not None and not isinstance(idle_reason, str):
        raise ProbeError("idleReason is not a string")
    return MediaSample(
        host_monotonic_offset_seconds=host_offset,
        request_id=request_id,
        media_session_id=media_session_id,
        player_state=player_state,
        current_time_seconds=current_time,
        playback_rate=playback_rate,
        content_id=content_id,
        active_track_ids=active_track_ids,
        idle_reason=idle_reason,
    )


def bind_content_ids(
    samples: Sequence[MediaSample],
    expected_content_id: str | None,
    expected_content_token: str | None,
) -> tuple[list[MediaSample], str]:
    observed = {
        sample.content_id for sample in samples if sample.content_id is not None
    }
    if len(observed) != 1:
        raise ProbeError(
            "receiver evidence must expose exactly one non-empty contentId; "
            f"observed {sorted(observed)}"
        )
    content_id = next(iter(observed))
    if expected_content_id is not None and content_id != expected_content_id:
        raise ProbeError("receiver contentId does not equal the candidate fixture URL")
    if expected_content_token is not None and expected_content_token not in content_id:
        raise ProbeError(
            "receiver contentId does not carry the candidate fixture token"
        )
    return [
        dataclasses.replace(sample, content_id=sample.content_id or content_id)
        for sample in samples
    ], content_id


def evaluate_phase(
    samples: Sequence[MediaSample],
    phase: str,
    freeze_tolerance_seconds: float,
) -> dict[str, Any]:
    if len(samples) < 3:
        raise ProbeError("receiver clock proof requires at least three samples")
    host_span = (
        samples[-1].host_monotonic_offset_seconds
        - samples[0].host_monotonic_offset_seconds
    )
    if host_span < 1.5:
        raise ProbeError("receiver clock proof is shorter than 1.5 seconds")
    session_ids = {sample.media_session_id for sample in samples}
    content_ids = {sample.content_id for sample in samples}
    states = {sample.player_state for sample in samples}
    if len(session_ids) != 1:
        raise ProbeError("receiver mediaSessionId changed during the phase")
    if len(content_ids) != 1 or None in content_ids:
        raise ProbeError("receiver content binding changed during the phase")
    expected_state = phase.upper()
    if states != {expected_state}:
        raise ProbeError(
            f"{phase} phase contained receiver states {sorted(states)}, expected only {expected_state}"
        )

    times = [sample.current_time_seconds for sample in samples]
    receiver_delta = times[-1] - times[0]
    maximum_backward_step = max(
        (before - after for before, after in zip(times, times[1:])),
        default=0.0,
    )
    if maximum_backward_step > freeze_tolerance_seconds:
        raise ProbeError("receiver clock moved backwards during the phase")

    if phase == "playing":
        rates = [sample.playback_rate for sample in samples]
        if any(rate <= 0 for rate in rates):
            raise ProbeError("PLAYING status reported a non-positive playbackRate")
        minimum_expected = host_span * min(rates) * 0.40
        maximum_expected = host_span * max(rates) * 1.75 + 1.0
        if receiver_delta < minimum_expected:
            raise ProbeError(
                "receiver PLAYING clock did not advance with host elapsed time"
            )
        if receiver_delta > maximum_expected:
            raise ProbeError(
                "receiver clock jumped; the phase was not an uninterrupted play proof"
            )
    elif phase in ("paused", "buffering"):
        span = max(times) - min(times)
        if span > freeze_tolerance_seconds:
            raise ProbeError(f"receiver {expected_state} clock moved by {span:.6f}s")
    else:
        raise ProbeError(f"unsupported phase {phase!r}")

    return {
        "hostElapsedSeconds": round(host_span, 6),
        "receiverClockDeltaSeconds": round(receiver_delta, 6),
        "receiverClockSpanSeconds": round(max(times) - min(times), 6),
        "maximumBackwardStepSeconds": round(maximum_backward_step, 6),
        "mediaSessionId": samples[0].media_session_id,
        "contentId": samples[0].content_id,
        "playerState": expected_state,
        "sampleCount": len(samples),
        "outcome": "pass",
    }


class CastChannel:
    def __init__(
        self,
        connection: ssl.SSLSocket,
        source_id: str,
        timeout_seconds: float,
    ) -> None:
        self.connection = connection
        self.source_id = source_id
        self.timeout_seconds = timeout_seconds
        self.started = time.monotonic()
        self.transcript_hasher = hashlib.sha256()
        self.transcript: list[dict[str, Any]] = []
        self.request_id = secrets.randbelow(1_000_000_000) + 1

    def next_request_id(self) -> int:
        value = self.request_id
        self.request_id += 1
        return value

    def record(self, direction: str, frame: bytes, message: CastMessage) -> None:
        self.transcript_hasher.update(direction.encode("ascii"))
        self.transcript_hasher.update(struct.pack(">I", len(frame)))
        self.transcript_hasher.update(frame)
        entry: dict[str, Any] = {
            "direction": direction,
            "hostMonotonicOffsetSeconds": round(time.monotonic() - self.started, 6),
            "frameSHA256": hashlib.sha256(frame).hexdigest(),
            "frameBytes": len(frame),
            "sourceId": message.source_id,
            "destinationId": message.destination_id,
            "namespace": message.namespace,
            "payloadType": "string" if message.payload_type == 0 else "binary",
        }
        if message.payload_type == 0:
            entry["json"] = message.json_payload()
        else:
            entry["payloadSHA256"] = hashlib.sha256(message.payload).hexdigest()
            entry["payloadBytes"] = len(message.payload)
        self.transcript.append(entry)

    def send(self, message: CastMessage) -> None:
        if message.source_id != self.source_id:
            raise ProbeError("outbound CastMessage has a foreign sourceId")
        if message.payload_type == 0:
            message_type = message.json_payload().get("type")
            if message_type not in ALLOWED_OUTBOUND_JSON_TYPES:
                raise ProbeError(
                    f"write type {message_type!r} is forbidden to the read-only probe"
                )
        elif message.namespace != NAMESPACE_DEVICE_AUTH:
            raise ProbeError("binary writes are allowed only for device authentication")
        frame = frame_cast_message(message)
        self.connection.sendall(frame)
        self.record("send", frame, message)

    def send_json(
        self, namespace: str, destination_id: str, value: dict[str, Any]
    ) -> None:
        self.send(
            CastMessage(
                source_id=self.source_id,
                destination_id=destination_id,
                namespace=namespace,
                payload_type=0,
                payload=json.dumps(
                    value, separators=(",", ":"), sort_keys=True
                ).encode(),
            )
        )

    def receive(self, deadline: float) -> CastMessage:
        header = self.read_exact(4, deadline)
        length = struct.unpack(">I", header)[0]
        if length == 0 or length > MAX_FRAME_BYTES:
            raise ProbeError(f"receiver advertised invalid Cast frame length {length}")
        payload = self.read_exact(length, deadline)
        message = decode_cast_message(payload)
        frame = header + payload
        self.record("receive", frame, message)
        if message.destination_id != self.source_id:
            raise ProbeError(
                f"receiver message targeted foreign sender {message.destination_id!r}"
            )
        return message

    def read_exact(self, length: int, deadline: float) -> bytes:
        result = bytearray()
        while len(result) < length:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ProbeError("timed out waiting for a complete Cast frame")
            self.connection.settimeout(min(self.timeout_seconds, remaining))
            try:
                chunk = self.connection.recv(length - len(result))
            except (TimeoutError, socket.timeout) as error:
                raise ProbeError("timed out waiting for the Cast receiver") from error
            if not chunk:
                raise ProbeError("Cast receiver closed the TLS channel")
            result.extend(chunk)
        return bytes(result)

    def wait_for(
        self,
        predicate: Callable[[CastMessage], bool],
        description: str,
    ) -> CastMessage:
        deadline = time.monotonic() + self.timeout_seconds
        while True:
            message = self.receive(deadline)
            if message.namespace == NAMESPACE_HEARTBEAT:
                heartbeat = message.json_payload()
                if message.source_id != PLATFORM_RECEIVER_ID:
                    raise ProbeError("heartbeat came from a foreign Cast endpoint")
                if heartbeat.get("type") == "PING":
                    self.send_json(
                        NAMESPACE_HEARTBEAT,
                        PLATFORM_RECEIVER_ID,
                        {"type": "PONG"},
                    )
                continue
            if predicate(message):
                return message
            if time.monotonic() >= deadline:
                raise ProbeError(f"timed out waiting for {description}")

    def authenticate(self) -> None:
        # DeviceAuthMessage.challenge = an empty AuthChallenge message.
        self.send(
            CastMessage(
                source_id=self.source_id,
                destination_id=PLATFORM_RECEIVER_ID,
                namespace=NAMESPACE_DEVICE_AUTH,
                payload_type=1,
                payload=encode_bytes_field(1, b""),
            )
        )
        response = self.wait_for(
            lambda message: (
                message.namespace == NAMESPACE_DEVICE_AUTH
                and message.source_id == PLATFORM_RECEIVER_ID
                and message.payload_type == 1
            ),
            "device authentication",
        )
        outcome = device_auth_outcome(response.payload)
        if outcome != "response":
            raise ProbeError(f"Cast device authentication returned {outcome}")

    def connect_endpoint(self, destination_id: str) -> None:
        self.send_json(
            NAMESPACE_CONNECTION,
            destination_id,
            {"type": "CONNECT"},
        )

    def request_status(
        self, namespace: str, destination_id: str, response_type: str
    ) -> tuple[int, dict[str, Any]]:
        request_id = self.next_request_id()
        self.send_json(
            namespace,
            destination_id,
            {"requestId": request_id, "type": "GET_STATUS"},
        )

        def matches(message: CastMessage) -> bool:
            if (
                message.namespace != namespace
                or message.source_id != destination_id
                or message.payload_type != 0
            ):
                return False
            value = message.json_payload()
            return (
                value.get("type") == response_type
                and value.get("requestId") == request_id
            )

        message = self.wait_for(matches, f"{response_type} requestId {request_id}")
        return request_id, message.json_payload()


def open_channel(
    host: str, port: int, source_id: str, timeout_seconds: float
) -> tuple[CastChannel, str]:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    # Cast receivers present device certificates outside the public Web PKI.
    # The probe records the exact certificate fingerprint instead of pretending
    # that a public-CA trust decision authenticated the lab receiver.
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    raw = socket.create_connection((host, port), timeout=timeout_seconds)
    try:
        connection = context.wrap_socket(raw, server_hostname=host)
    except Exception:
        raw.close()
        raise
    certificate = connection.getpeercert(binary_form=True)
    if not certificate:
        connection.close()
        raise ProbeError("Cast TLS channel supplied no peer certificate")
    return (
        CastChannel(connection, source_id, timeout_seconds),
        hashlib.sha256(certificate).hexdigest(),
    )


def query_receiver_application(
    channel: CastChannel, expected_app_id: str
) -> ReceiverApplication:
    _, response = channel.request_status(
        NAMESPACE_RECEIVER,
        PLATFORM_RECEIVER_ID,
        "RECEIVER_STATUS",
    )
    return select_receiver_application(response, expected_app_id)


def capture(
    *,
    host: str,
    port: int,
    expected_app_id: str,
    expected_content_id: str | None,
    expected_content_token: str | None,
    phase: str,
    duration_seconds: float,
    interval_seconds: float,
    timeout_seconds: float,
    freeze_tolerance_seconds: float,
) -> dict[str, Any]:
    probe_token = secrets.token_hex(16)
    source_id = f"sender-swiftvlc-probe-{probe_token}"
    channel, certificate_sha256 = open_channel(host, port, source_id, timeout_seconds)
    try:
        channel.authenticate()
        channel.connect_endpoint(PLATFORM_RECEIVER_ID)
        before = query_receiver_application(channel, expected_app_id)
        channel.connect_endpoint(before.transport_id)

        samples: list[MediaSample] = []
        capture_started = time.monotonic()
        next_sample = capture_started
        while True:
            delay = next_sample - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            request_id, response = channel.request_status(
                NAMESPACE_MEDIA,
                before.transport_id,
                "MEDIA_STATUS",
            )
            offset = time.monotonic() - capture_started
            samples.append(parse_media_sample(response, request_id, offset))
            if offset >= duration_seconds:
                break
            next_sample += interval_seconds

        after = query_receiver_application(channel, expected_app_id)
        if after != before:
            raise ProbeError(
                "receiver application/session identity changed during capture"
            )
        samples, content_id = bind_content_ids(
            samples, expected_content_id, expected_content_token
        )
        evaluation = evaluate_phase(samples, phase, freeze_tolerance_seconds)
        return {
            "formatVersion": 1,
            "scenario": "cast-receiver-clock",
            "result": "pass",
            "releaseCredit": False,
            "releaseCreditReason": (
                "Standalone receiver evidence requires candidate/device orchestration "
                "and qualification-policy integration before it can satisfy a release row."
            ),
            "probeToken": probe_token,
            "receiver": {
                "host": host,
                "port": port,
                "tlsPeerCertificateSHA256": certificate_sha256,
                "application": dataclasses.asdict(before),
            },
            "binding": {
                "sourceId": source_id,
                "expectedAppId": expected_app_id,
                "expectedContentId": expected_content_id,
                "expectedContentTokenSHA256": (
                    hashlib.sha256(expected_content_token.encode()).hexdigest()
                    if expected_content_token is not None
                    else None
                ),
                "observedContentId": content_id,
                "mediaSessionId": samples[0].media_session_id,
            },
            "phase": phase,
            "evaluation": evaluation,
            "samples": [sample.evidence() for sample in samples],
            "transcript": {
                "sha256": channel.transcript_hasher.hexdigest(),
                "messageCount": len(channel.transcript),
                "messages": channel.transcript,
            },
            "outboundWritePolicy": sorted(ALLOWED_OUTBOUND_JSON_TYPES),
        }
    finally:
        channel.connection.close()


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{secrets.token_hex(8)}.tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")
    temporary.replace(path)


def parse_arguments(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--host", required=True, help="Chromecast IP address or host name"
    )
    parser.add_argument("--port", type=int, default=CAST_PORT)
    parser.add_argument("--app-id", default=DEFAULT_MEDIA_RECEIVER_APP_ID)
    binding = parser.add_mutually_exclusive_group(required=True)
    binding.add_argument("--expected-content-id")
    binding.add_argument("--expected-content-token")
    parser.add_argument(
        "--phase", choices=("playing", "paused", "buffering"), required=True
    )
    parser.add_argument("--duration", type=float, default=6.0)
    parser.add_argument("--interval", type=float, default=1.0)
    parser.add_argument("--timeout", type=float, default=8.0)
    parser.add_argument("--freeze-tolerance", type=float, default=0.15)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args(argv)
    if not 1 <= arguments.port <= 65535:
        parser.error("--port must be in 1...65535")
    if arguments.duration < 2.0:
        parser.error("--duration must be at least 2 seconds")
    if not 0.25 <= arguments.interval <= arguments.duration:
        parser.error("--interval must be between 0.25 seconds and --duration")
    if arguments.duration / arguments.interval < 2:
        parser.error("--duration/--interval must produce at least three samples")
    if arguments.timeout <= 0:
        parser.error("--timeout must be positive")
    if not 0 <= arguments.freeze_tolerance <= 0.5:
        parser.error("--freeze-tolerance must be in 0...0.5 seconds")
    token = arguments.expected_content_token
    if token is not None and len(token) < 8:
        parser.error("--expected-content-token must contain at least 8 characters")
    return arguments


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv if argv is not None else sys.argv[1:])
    try:
        evidence = capture(
            host=arguments.host,
            port=arguments.port,
            expected_app_id=arguments.app_id,
            expected_content_id=arguments.expected_content_id,
            expected_content_token=arguments.expected_content_token,
            phase=arguments.phase,
            duration_seconds=arguments.duration,
            interval_seconds=arguments.interval,
            timeout_seconds=arguments.timeout,
            freeze_tolerance_seconds=arguments.freeze_tolerance,
        )
    except Exception as error:
        evidence = {
            "formatVersion": 1,
            "scenario": "cast-receiver-clock",
            "result": "fail",
            "releaseCredit": False,
            "phase": arguments.phase,
            "receiver": {"host": arguments.host, "port": arguments.port},
            "errorType": type(error).__name__,
            "error": str(error),
        }
        atomic_write_json(arguments.output, evidence)
        print(f"Cast receiver probe failed: {error}", file=sys.stderr)
        return 1
    atomic_write_json(arguments.output, evidence)
    print(f"Cast receiver {arguments.phase} proof passed; evidence: {arguments.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
