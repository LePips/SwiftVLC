#!/usr/bin/env python3

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import sys
import time
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
PROBE_PATH = REPO_ROOT / "scripts" / "cast-receiver-probe.py"
SPEC = importlib.util.spec_from_file_location("cast_receiver_probe", PROBE_PATH)
assert SPEC is not None and SPEC.loader is not None
PROBE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = PROBE
SPEC.loader.exec_module(PROBE)


class CastReceiverProbeTests(unittest.TestCase):
    class FakeConnection:
        def __init__(self, incoming: bytes = b"") -> None:
            self.incoming = bytearray(incoming)
            self.sent = bytearray()

        def settimeout(self, _: float) -> None:
            pass

        def recv(self, length: int) -> bytes:
            if not self.incoming:
                return b""
            amount = min(length, 3, len(self.incoming))
            value = bytes(self.incoming[:amount])
            del self.incoming[:amount]
            return value

        def sendall(self, value: bytes) -> None:
            self.sent.extend(value)

    def sample(
        self,
        offset: float,
        current_time: float,
        state: str,
        *,
        request_id: int = 1,
        session_id: int = 42,
        content_id: str | None = "http://fixture/candidate-token/movie.mp4",
        rate: float = 1.0,
    ):
        return PROBE.MediaSample(
            host_monotonic_offset_seconds=offset,
            request_id=request_id,
            media_session_id=session_id,
            player_state=state,
            current_time_seconds=current_time,
            playback_rate=rate,
            content_id=content_id,
            active_track_ids=(1, 2),
            idle_reason=None,
        )

    def message_with_encoded_size(self, expected_size: int):
        for payload_size in range(max(0, expected_size - 256), expected_size + 1):
            message = PROBE.CastMessage(
                source_id="sender-test",
                destination_id="receiver-0",
                namespace=PROBE.NAMESPACE_RECEIVER,
                payload_type=0,
                payload=b"x" * payload_size,
            )
            if len(PROBE.encode_cast_message(message)) == expected_size:
                return message
        self.fail(f"could not construct a {expected_size}-byte CastMessage")

    def test_cast_message_round_trip_preserves_routing_and_payload(self) -> None:
        message = PROBE.CastMessage(
            source_id="sender-test",
            destination_id="receiver-0",
            namespace=PROBE.NAMESPACE_RECEIVER,
            payload_type=0,
            payload=b'{"requestId":7,"type":"GET_STATUS"}',
        )

        encoded = PROBE.encode_cast_message(message)

        self.assertEqual(PROBE.decode_cast_message(encoded), message)
        framed = PROBE.frame_cast_message(message)
        self.assertEqual(int.from_bytes(framed[:4], "big"), len(encoded))
        self.assertEqual(framed[4:], encoded)

    def test_cast_transport_accepts_exact_64_kib_envelope(self) -> None:
        message = self.message_with_encoded_size(PROBE.MAX_FRAME_BYTES)

        framed = PROBE.frame_cast_message(message)

        self.assertEqual(int.from_bytes(framed[:4], "big"), 64 * 1024)
        self.assertEqual(len(framed), 4 + 64 * 1024)

    def test_cast_transport_rejects_envelope_over_64_kib(self) -> None:
        message = self.message_with_encoded_size(PROBE.MAX_FRAME_BYTES + 1)

        with self.assertRaisesRegex(PROBE.ProbeError, "frame-size limit"):
            PROBE.frame_cast_message(message)

        incoming = (PROBE.MAX_FRAME_BYTES + 1).to_bytes(4, "big")
        channel = PROBE.CastChannel(
            self.FakeConnection(incoming), "sender-test", 1
        )
        with self.assertRaisesRegex(PROBE.ProbeError, "invalid Cast frame length"):
            channel.receive(time.monotonic() + 1)

    def test_cast_message_decoder_skips_known_protobuf_wire_shapes(self) -> None:
        message = PROBE.CastMessage(
            source_id="receiver-0",
            destination_id="sender-test",
            namespace=PROBE.NAMESPACE_HEARTBEAT,
            payload_type=0,
            payload=b'{"type":"PING"}',
        )
        encoded = PROBE.encode_cast_message(message)
        encoded += PROBE.encode_varint_field(20, 99)
        encoded += PROBE.encode_bytes_field(21, b"future")

        self.assertEqual(PROBE.decode_cast_message(encoded), message)

    def test_cast_message_decoder_rejects_cross_payload_ambiguity(self) -> None:
        message = PROBE.CastMessage(
            source_id="receiver-0",
            destination_id="sender-test",
            namespace=PROBE.NAMESPACE_DEVICE_AUTH,
            payload_type=1,
            payload=b"auth",
        )
        encoded = PROBE.encode_cast_message(message) + PROBE.encode_bytes_field(
            6, b"{}"
        )

        with self.assertRaisesRegex(PROBE.ProbeError, "both UTF-8 and binary"):
            PROBE.decode_cast_message(encoded)

    def test_device_auth_response_is_distinguished_from_error(self) -> None:
        response = PROBE.encode_bytes_field(
            2,
            PROBE.encode_bytes_field(1, b"signature")
            + PROBE.encode_bytes_field(2, b"device-certificate"),
        )
        error = PROBE.encode_bytes_field(3, PROBE.encode_varint_field(1, 2))

        self.assertEqual(PROBE.device_auth_outcome(response), "response")
        self.assertEqual(PROBE.device_auth_outcome(error), "error:2")
        self.assertEqual(PROBE.device_auth_outcome(response + error), "invalid")
        self.assertEqual(
            PROBE.device_auth_outcome(
                PROBE.encode_bytes_field(2, PROBE.encode_bytes_field(1, b"signature"))
            ),
            "invalid",
        )

    def test_read_only_channel_rejects_playback_control_writes(self) -> None:
        connection = self.FakeConnection()
        channel = PROBE.CastChannel(connection, "sender-test", 1)
        message = PROBE.CastMessage(
            source_id="sender-test",
            destination_id="transport-1",
            namespace=PROBE.NAMESPACE_MEDIA,
            payload_type=0,
            payload=b'{"requestId":1,"type":"PAUSE"}',
        )

        with self.assertRaisesRegex(PROBE.ProbeError, "forbidden"):
            channel.send(message)
        self.assertEqual(connection.sent, b"")

    def test_status_query_ignores_stale_request_and_accepts_exact_response(
        self,
    ) -> None:
        def response(request_id: int) -> bytes:
            return PROBE.frame_cast_message(
                PROBE.CastMessage(
                    source_id="transport-1",
                    destination_id="sender-test",
                    namespace=PROBE.NAMESPACE_MEDIA,
                    payload_type=0,
                    payload=json.dumps(
                        {
                            "requestId": request_id,
                            "status": [],
                            "type": "MEDIA_STATUS",
                        },
                        separators=(",", ":"),
                    ).encode(),
                )
            )

        connection = self.FakeConnection(response(16) + response(17))
        channel = PROBE.CastChannel(connection, "sender-test", 1)
        channel.request_id = 17

        request_id, payload = channel.request_status(
            PROBE.NAMESPACE_MEDIA, "transport-1", "MEDIA_STATUS"
        )

        self.assertEqual(request_id, 17)
        self.assertEqual(payload["requestId"], 17)
        sent_length = int.from_bytes(connection.sent[:4], "big")
        sent = PROBE.decode_cast_message(bytes(connection.sent[4 : 4 + sent_length]))
        self.assertEqual(sent.json_payload()["requestId"], 17)

    def test_channel_rejects_message_for_another_sender(self) -> None:
        incoming = PROBE.frame_cast_message(
            PROBE.CastMessage(
                source_id="receiver-0",
                destination_id="sender-foreign",
                namespace=PROBE.NAMESPACE_HEARTBEAT,
                payload_type=0,
                payload=b'{"type":"PING"}',
            )
        )
        channel = PROBE.CastChannel(self.FakeConnection(incoming), "sender-test", 1)

        with self.assertRaisesRegex(PROBE.ProbeError, "foreign sender"):
            channel.receive(time.monotonic() + 1)

    def test_receiver_application_requires_one_exact_app_identity(self) -> None:
        response = {
            "status": {
                "applications": [
                    {
                        "appId": PROBE.DEFAULT_MEDIA_RECEIVER_APP_ID,
                        "sessionId": "session-1",
                        "transportId": "transport-1",
                        "displayName": "Default Media Receiver",
                    }
                ]
            }
        }

        application = PROBE.select_receiver_application(
            response, PROBE.DEFAULT_MEDIA_RECEIVER_APP_ID
        )

        self.assertEqual(application.session_id, "session-1")
        self.assertEqual(application.transport_id, "transport-1")

    def test_receiver_application_rejects_missing_or_duplicate_match(self) -> None:
        with self.assertRaisesRegex(PROBE.ProbeError, "found 0"):
            PROBE.select_receiver_application(
                {"status": {"applications": []}},
                PROBE.DEFAULT_MEDIA_RECEIVER_APP_ID,
            )
        duplicate = {
            "status": {
                "applications": [
                    {
                        "appId": PROBE.DEFAULT_MEDIA_RECEIVER_APP_ID,
                        "sessionId": "one",
                        "transportId": "one",
                    },
                    {
                        "appId": PROBE.DEFAULT_MEDIA_RECEIVER_APP_ID,
                        "sessionId": "two",
                        "transportId": "two",
                    },
                ]
            }
        }
        with self.assertRaisesRegex(PROBE.ProbeError, "found 2"):
            PROBE.select_receiver_application(
                duplicate, PROBE.DEFAULT_MEDIA_RECEIVER_APP_ID
            )

    def test_media_status_parser_retains_receiver_oracles(self) -> None:
        response = {
            "requestId": 71,
            "type": "MEDIA_STATUS",
            "status": [
                {
                    "mediaSessionId": 42,
                    "playerState": "PLAYING",
                    "currentTime": 12.25,
                    "playbackRate": 1,
                    "activeTrackIds": [3, 4],
                    "media": {"contentId": "http://fixture/token/movie.mp4"},
                }
            ],
        }

        sample = PROBE.parse_media_sample(response, 71, 0.25)

        self.assertEqual(sample.media_session_id, 42)
        self.assertEqual(sample.current_time_seconds, 12.25)
        self.assertEqual(sample.active_track_ids, (3, 4))
        self.assertEqual(sample.request_id, 71)

    def test_media_status_rejects_missing_negative_or_nonfinite_rate(self) -> None:
        base_status = {
            "mediaSessionId": 42,
            "playerState": "PAUSED",
            "currentTime": 0,
        }
        for value in (None, -1, float("nan"), float("inf")):
            with self.subTest(playback_rate=value):
                status = dict(base_status)
                if value is not None:
                    status["playbackRate"] = value
                with self.assertRaisesRegex(
                    PROBE.ProbeError, "playbackRate must"
                ):
                    PROBE.parse_media_sample(
                        {
                            "requestId": 71,
                            "type": "MEDIA_STATUS",
                            "status": [status],
                        },
                        71,
                        0,
                    )

    def test_media_status_rejects_missing_negative_or_nonfinite_time(self) -> None:
        base_status = {
            "mediaSessionId": 42,
            "playerState": "PLAYING",
            "playbackRate": 1,
        }
        for value in (None, -1, float("nan"), float("inf")):
            with self.subTest(current_time=value):
                status = dict(base_status)
                if value is not None:
                    status["currentTime"] = value
                with self.assertRaisesRegex(PROBE.ProbeError, "currentTime must"):
                    PROBE.parse_media_sample(
                        {
                            "requestId": 71,
                            "type": "MEDIA_STATUS",
                            "status": [status],
                        },
                        71,
                        0,
                    )

    def test_content_binding_fills_omitted_unchanged_media_fields(self) -> None:
        samples = [
            self.sample(0, 10, "PLAYING"),
            self.sample(1, 11, "PLAYING", content_id=None),
            self.sample(2, 12, "PLAYING", content_id=None),
        ]

        bound, content_id = PROBE.bind_content_ids(samples, None, "candidate-token")

        self.assertEqual(content_id, "http://fixture/candidate-token/movie.mp4")
        self.assertTrue(all(item.content_id == content_id for item in bound))

    def test_content_binding_rejects_foreign_fixture(self) -> None:
        samples = [
            self.sample(0, 10, "PLAYING"),
            self.sample(1, 11, "PLAYING"),
            self.sample(2, 12, "PLAYING"),
        ]
        with self.assertRaisesRegex(PROBE.ProbeError, "candidate fixture token"):
            PROBE.bind_content_ids(samples, None, "different-token")

    def test_playing_phase_requires_receiver_clock_advancement(self) -> None:
        samples = [
            self.sample(0, 10.0, "PLAYING"),
            self.sample(1, 11.0, "PLAYING"),
            self.sample(2, 12.0, "PLAYING"),
            self.sample(3, 13.0, "PLAYING"),
        ]

        result = PROBE.evaluate_phase(samples, "playing", 0.15)

        self.assertEqual(result["outcome"], "pass")
        self.assertEqual(result["receiverClockDeltaSeconds"], 3.0)

    def test_stale_playing_status_cannot_pass(self) -> None:
        samples = [
            self.sample(0, 10.0, "PLAYING"),
            self.sample(1, 10.0, "PLAYING"),
            self.sample(2, 10.0, "PLAYING"),
        ]
        with self.assertRaisesRegex(PROBE.ProbeError, "did not advance"):
            PROBE.evaluate_phase(samples, "playing", 0.15)

    def test_paused_and_buffering_phases_require_frozen_receiver_clock(self) -> None:
        for phase in ("paused", "buffering"):
            with self.subTest(phase=phase):
                state = phase.upper()
                samples = [
                    self.sample(0, 20.0, state, rate=0),
                    self.sample(1, 20.02, state, rate=0),
                    self.sample(2, 20.01, state, rate=0),
                ]
                result = PROBE.evaluate_phase(samples, phase, 0.15)
                self.assertEqual(result["outcome"], "pass")

    def test_frozen_phase_rejects_clock_extrapolation(self) -> None:
        samples = [
            self.sample(0, 20.0, "PAUSED", rate=0),
            self.sample(1, 21.0, "PAUSED", rate=0),
            self.sample(2, 22.0, "PAUSED", rate=0),
        ]
        with self.assertRaisesRegex(PROBE.ProbeError, "clock moved"):
            PROBE.evaluate_phase(samples, "paused", 0.15)

    def test_phase_rejects_cross_session_and_cross_content_samples(self) -> None:
        cross_session = [
            self.sample(0, 10, "PLAYING", session_id=42),
            self.sample(1, 11, "PLAYING", session_id=43),
            self.sample(2, 12, "PLAYING", session_id=43),
        ]
        with self.assertRaisesRegex(PROBE.ProbeError, "mediaSessionId changed"):
            PROBE.evaluate_phase(cross_session, "playing", 0.15)

        cross_content = [
            self.sample(0, 10, "PLAYING", content_id="first"),
            self.sample(1, 11, "PLAYING", content_id="second"),
            self.sample(2, 12, "PLAYING", content_id="second"),
        ]
        with self.assertRaisesRegex(PROBE.ProbeError, "content binding changed"):
            PROBE.evaluate_phase(cross_content, "playing", 0.15)

    def test_cli_requires_strong_content_binding(self) -> None:
        with contextlib.redirect_stderr(io.StringIO()):
            with self.assertRaises(SystemExit):
                PROBE.parse_arguments(
                    [
                        "--host",
                        "192.0.2.1",
                        "--phase",
                        "playing",
                        "--expected-content-token",
                        "short",
                        "--output",
                        "/tmp/evidence.json",
                    ]
                )


if __name__ == "__main__":
    unittest.main()
