#!/usr/bin/env python3
"""Run one command with wall-clock and output-idle deadlines.

The child starts in its own process group so a timeout or interruption cannot
leave xcodebuild helpers running after the qualification harness has stopped.
Combined stdout/stderr is written directly to the retained log named by the
caller; timeout diagnostics are retained there as well.
"""

from __future__ import annotations

import argparse
import os
import selectors
import signal
import subprocess
import sys
import time
from pathlib import Path

WALL_TIMEOUT_EXIT = 124
IDLE_TIMEOUT_EXIT = 125


class WatchdogError(ValueError):
    pass


def _positive_seconds(value: str) -> float:
    try:
        parsed = float(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be a number") from error
    if parsed <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _command_exit_code(return_code: int) -> int:
    return 128 + abs(return_code) if return_code < 0 else return_code


def _open_output(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o644)
    except OSError as error:
        raise WatchdogError(f"cannot open retained log {path}: {error}") from error
    return os.fdopen(descriptor, "wb", buffering=0)


def run(
    command: list[str],
    *,
    wall_seconds: float,
    idle_seconds: float,
    grace_seconds: float,
    output_path: Path,
) -> int:
    if not command:
        raise WatchdogError("command is empty")

    with _open_output(output_path) as output:
        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
        except OSError as error:
            raise WatchdogError(f"cannot start command: {error}") from error

        assert process.stdout is not None
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        started_at = time.monotonic()
        last_output_at = started_at
        pending_signal: int | None = None

        def request_shutdown(signum: int, _frame: object) -> None:
            nonlocal pending_signal
            if pending_signal is None:
                pending_signal = signum

        previous_handlers = {
            signum: signal.signal(signum, request_shutdown)
            for signum in (signal.SIGINT, signal.SIGTERM)
        }

        def write_diagnostic(message: str) -> None:
            encoded = f"\n[swiftvlc-watchdog] {message}\n".encode()
            output.write(encoded)
            print(f"Error: {message}", file=sys.stderr, flush=True)

        def drain_ready(timeout: float) -> bool:
            nonlocal last_output_at
            received = False
            for key, _ in selector.select(timeout):
                chunk = os.read(key.fileobj.fileno(), 64 * 1024)
                if chunk:
                    output.write(chunk)
                    last_output_at = time.monotonic()
                    received = True
                else:
                    selector.unregister(key.fileobj)
            return received

        def process_group_exists() -> bool:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                return False
            except PermissionError:
                # Darwin may report EPERM briefly for a reaped, empty session.
                # Our direct child remains an authoritative lower bound.
                return process.poll() is None
            return True

        def terminate_group() -> None:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError):
                return
            deadline = time.monotonic() + grace_seconds
            while process_group_exists() and time.monotonic() < deadline:
                process.poll()
                drain_ready(min(0.1, max(0.0, deadline - time.monotonic())))
            if process_group_exists():
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError):
                    pass
            try:
                process.wait(timeout=max(1.0, grace_seconds))
            except subprocess.TimeoutExpired:
                pass

        try:
            while True:
                drain_ready(0.1)
                now = time.monotonic()
                if pending_signal is not None:
                    write_diagnostic(
                        f"received signal {pending_signal}; terminating command group"
                    )
                    terminate_group()
                    return 128 + pending_signal
                if process.poll() is not None:
                    while selector.get_map() and drain_ready(0):
                        pass
                    return _command_exit_code(process.returncode)
                wall_elapsed = now - started_at
                idle_elapsed = now - last_output_at
                if wall_elapsed >= wall_seconds:
                    write_diagnostic(
                        "wall-clock timeout after "
                        f"{wall_elapsed:.1f}s (limit {wall_seconds:g}s); "
                        "terminating command group"
                    )
                    terminate_group()
                    return WALL_TIMEOUT_EXIT
                if idle_elapsed >= idle_seconds:
                    write_diagnostic(
                        "output-idle timeout after "
                        f"{idle_elapsed:.1f}s (limit {idle_seconds:g}s); "
                        "terminating command group"
                    )
                    terminate_group()
                    return IDLE_TIMEOUT_EXIT
        finally:
            terminate_group()
            selector.close()
            process.stdout.close()
            for signum, handler in previous_handlers.items():
                signal.signal(signum, handler)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wall-seconds", type=_positive_seconds, required=True)
    parser.add_argument("--idle-seconds", type=_positive_seconds, required=True)
    parser.add_argument("--grace-seconds", type=_positive_seconds, default=5.0)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    command = arguments.command
    if command[:1] == ["--"]:
        command = command[1:]
    try:
        return run(
            command,
            wall_seconds=arguments.wall_seconds,
            idle_seconds=arguments.idle_seconds,
            grace_seconds=arguments.grace_seconds,
            output_path=arguments.output,
        )
    except WatchdogError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
