#!/usr/bin/env python3
"""Deterministic HTTP media server with loop, stall, and disconnect endpoints."""

from __future__ import annotations

import argparse
import json
import mimetypes
import os
import re
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlsplit


class RangeNotSatisfiable(ValueError):
    pass


class FixtureHandler(BaseHTTPRequestHandler):
    server: "FixtureHTTPServer"
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:
        started = time.monotonic()
        status = HTTPStatus.OK
        self.response_status = HTTPStatus.OK
        self.response_content_range: str | None = None
        transferred = 0
        try:
            route = unquote(urlsplit(self.path).path)
            if route == "/healthz":
                payload = json.dumps({"status": "ok"}).encode()
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                transferred = len(payload)
                return

            match = re.fullmatch(r"/fault/trigger/([A-Za-z0-9._-]+)", route)
            if match:
                generation = self.server.trigger_stall(match.group(1))
                payload = json.dumps({"generation": generation}).encode()
                self.send_response(HTTPStatus.OK)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
                transferred = len(payload)
                return

            match = re.fullmatch(
                r"/fault/gated-stall/([A-Za-z0-9._-]+)/([0-9]+(?:\.[0-9]+)?)/(.+)",
                route,
            )
            if match:
                transferred = self._serve_loop(
                    self._safe_path(match.group(3)),
                    stall_token=match.group(1),
                    stall_seconds=float(match.group(2)),
                )
                return

            match = re.fullmatch(r"/live/(.+)", route)
            if match:
                transferred = self._serve_loop(self._safe_path(match.group(1)))
                return

            match = re.fullmatch(r"/fault/stall/([0-9]+(?:\.[0-9]+)?)/(.+)", route)
            if match:
                transferred = self._serve_file(
                    self._safe_path(match.group(2)), stall_seconds=float(match.group(1))
                )
                return

            match = re.fullmatch(r"/fault/close/(\d+)/(.+)", route)
            if match:
                transferred = self._serve_file(
                    self._safe_path(match.group(2)), close_after=int(match.group(1))
                )
                return

            match = re.fullmatch(r"/fault/status/(\d{3})", route)
            if match:
                status = HTTPStatus(int(match.group(1)))
                self.response_status = status
                self.send_error(status)
                return

            match = re.fullmatch(r"/files/(.+)", route)
            if match:
                transferred = self._serve_file(self._safe_path(match.group(1)))
                return

            status = HTTPStatus.NOT_FOUND
            self.response_status = status
            self.send_error(status)
        except (BrokenPipeError, ConnectionResetError):
            status = HTTPStatus.PARTIAL_CONTENT
            self.response_status = status
        except (FileNotFoundError, IsADirectoryError):
            status = HTTPStatus.NOT_FOUND
            self.response_status = status
            self.send_error(status)
        except ValueError as error:
            status = HTTPStatus.BAD_REQUEST
            self.response_status = status
            self.send_error(status, str(error))
        finally:
            status = self.response_status
            self.server.record(
                {
                    "timestamp": datetime.now(timezone.utc).isoformat(),
                    "client": self.client_address[0],
                    "method": "GET",
                    "path": self.path,
                    "status": int(status),
                    "requestRange": self.headers.get("Range"),
                    "responseContentRange": self.response_content_range,
                    "bytes": transferred,
                    "durationSeconds": round(time.monotonic() - started, 6),
                }
            )

    def _safe_path(self, relative: str) -> Path:
        candidate = (self.server.root / relative).resolve()
        if candidate != self.server.root and self.server.root not in candidate.parents:
            raise ValueError("path escapes fixture root")
        if not candidate.is_file():
            raise FileNotFoundError(candidate)
        return candidate

    def _serve_loop(
        self,
        path: Path,
        *,
        stall_token: str | None = None,
        stall_seconds: float = 0,
    ) -> int:
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(HTTPStatus.OK)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        transferred = 0
        observed_stall_generation = 0
        if stall_token:
            observed_stall_generation, triggered_at = self.server.stall_state(stall_token)
            remaining = triggered_at + stall_seconds - time.monotonic()
            if observed_stall_generation > 0 and remaining > 0:
                time.sleep(remaining)
        while True:
            with path.open("rb") as source:
                while chunk := source.read(self.server.chunk_size):
                    self.wfile.write(chunk)
                    self.wfile.flush()
                    transferred += len(chunk)
                    if stall_token:
                        generation, triggered_at = self.server.stall_state(stall_token)
                        if generation > observed_stall_generation:
                            observed_stall_generation = generation
                            remaining = triggered_at + stall_seconds - time.monotonic()
                            if remaining > 0:
                                time.sleep(remaining)
                    if self.server.chunk_delay:
                        time.sleep(self.server.chunk_delay)

    def _serve_file(
        self, path: Path, *, stall_seconds: float = 0, close_after: int | None = None
    ) -> int:
        size = path.stat().st_size
        try:
            start, end, partial = self._range(size)
        except RangeNotSatisfiable:
            self.response_status = HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE
            self.response_content_range = f"bytes */{size}"
            self.send_response(HTTPStatus.REQUESTED_RANGE_NOT_SATISFIABLE)
            self.send_header("Content-Range", self.response_content_range)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return 0
        length = end - start + 1
        advertised_length = length if close_after is None else min(length, close_after + 1)
        self.response_status = HTTPStatus.PARTIAL_CONTENT if partial else HTTPStatus.OK
        self.send_response(self.response_status)
        self.send_header("Content-Type", mimetypes.guess_type(path.name)[0] or "application/octet-stream")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.response_content_range = f"bytes {start}-{end}/{size}"
            self.send_header("Content-Range", self.response_content_range)
        self.end_headers()

        transferred = 0
        stalled = False
        with path.open("rb") as source:
            source.seek(start)
            remaining = length
            while remaining:
                limit = min(self.server.chunk_size, remaining)
                if close_after is not None:
                    limit = min(limit, advertised_length - transferred)
                    if limit <= 0:
                        self.close_connection = True
                        return transferred
                chunk = source.read(limit)
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
                transferred += len(chunk)
                remaining -= len(chunk)
                if stall_seconds and not stalled and transferred >= max(1, length // 4):
                    stalled = True
                    time.sleep(stall_seconds)
        return transferred

    def _range(self, size: int) -> tuple[int, int, bool]:
        header = self.headers.get("Range")
        if not header:
            return 0, size - 1, False
        match = re.fullmatch(r"bytes=(\d*)-(\d*)", header.strip())
        if not match or (not match.group(1) and not match.group(2)):
            raise ValueError("unsupported byte range")
        if match.group(1):
            start = int(match.group(1))
            end = int(match.group(2)) if match.group(2) else size - 1
        else:
            suffix = int(match.group(2))
            start = max(0, size - suffix)
            end = size - 1
        if start >= size or end < start:
            raise RangeNotSatisfiable("range outside file")
        return start, min(end, size - 1), True

    def log_message(self, format: str, *args: object) -> None:
        if self.server.verbose:
            super().log_message(format, *args)


class FixtureHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(
        self,
        address: tuple[str, int],
        root: Path,
        request_log: Path | None,
        chunk_size: int,
        chunk_delay: float,
        verbose: bool,
    ) -> None:
        super().__init__(address, FixtureHandler)
        self.root = root.resolve()
        self.request_log = request_log
        self.chunk_size = chunk_size
        self.chunk_delay = chunk_delay
        self.verbose = verbose
        self._stall_lock = threading.Lock()
        self._stall_generations: dict[str, int] = {}
        self._stall_triggered_at: dict[str, float] = {}

    def trigger_stall(self, token: str) -> int:
        with self._stall_lock:
            generation = self._stall_generations.get(token, 0) + 1
            self._stall_generations[token] = generation
            self._stall_triggered_at[token] = time.monotonic()
            return generation

    def stall_state(self, token: str) -> tuple[int, float]:
        with self._stall_lock:
            return (
                self._stall_generations.get(token, 0),
                self._stall_triggered_at.get(token, 0),
            )

    def handle_error(self, request: object, client_address: tuple[str, int]) -> None:
        # Media clients commonly abandon a keep-alive connection after a seek
        # or EOF probe. BaseServer otherwise prints a full traceback even
        # though the request itself completed and was recorded successfully.
        # Preserve tracebacks for every unexpected server failure.
        error = sys.exc_info()[1]
        if isinstance(error, (BrokenPipeError, ConnectionResetError)):
            return
        super().handle_error(request, client_address)

    def record(self, value: dict) -> None:
        if self.request_log is None:
            return
        with self.request_log.open("a") as output:
            output.write(json.dumps(value, sort_keys=True) + "\n")


def lan_address() -> str:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as connection:
        connection.connect(("192.0.2.1", 80))
        return connection.getsockname()[0]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--advertise-host")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument("--request-log", type=Path)
    parser.add_argument("--chunk-size", type=int, default=7520)
    parser.add_argument("--chunk-delay", type=float, default=0.02)
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    if not args.root.is_dir():
        parser.error(f"fixture root does not exist: {args.root}")
    server = FixtureHTTPServer(
        (args.host, args.port),
        args.root,
        args.request_log,
        args.chunk_size,
        args.chunk_delay,
        args.verbose,
    )
    advertised = args.advertise_host or lan_address()
    ready = {"host": advertised, "port": server.server_port, "baseURL": f"http://{advertised}:{server.server_port}"}
    if args.ready_file:
        args.ready_file.write_text(json.dumps(ready, indent=2, sort_keys=True) + "\n")
    print(json.dumps(ready, sort_keys=True), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
