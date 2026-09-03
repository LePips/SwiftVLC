#!/usr/bin/env python3
"""Hold one fail-closed, host-local qualification lock for a physical device."""

from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import signal
import stat
import sys
import tempfile
import time
from pathlib import Path


LOCK_AUTHORITY = "swiftvlc-physical-device-run-lock-v1"
DEVICE_IDENTIFIER = re.compile(r"[A-Za-z0-9][A-Za-z0-9._:-]{2,255}")
UTC_TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
STOP_REQUESTED = False


class DeviceRunLockError(ValueError):
    """Raised when a physical-device qualification lock cannot be held."""


def _utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )


def validate_device_identifier(value: str) -> str:
    if DEVICE_IDENTIFIER.fullmatch(value) is None:
        raise DeviceRunLockError(
            "device identifier must be 3-256 safe ASCII identifier characters"
        )
    return value


def default_lock_root() -> Path:
    # The runner deliberately redirects TMPDIR into its private run directory.
    # Device exclusion must instead use one stable host/user namespace so two
    # independent work/output roots still contend for the same iPhone.
    return Path("/tmp") / f"swiftvlc-qualification-device-locks-{os.getuid()}"


def device_identifier_digest(device_identifier: str) -> str:
    return hashlib.sha256(validate_device_identifier(device_identifier).encode()).hexdigest()


def device_lock_path(lock_root: Path, device_identifier: str) -> Path:
    return lock_root / f"{device_identifier_digest(device_identifier)}.lock"


def _prepare_lock_root(lock_root: Path) -> None:
    try:
        lock_root.mkdir(mode=0o700, parents=True, exist_ok=True)
        metadata = lock_root.lstat()
    except OSError as error:
        raise DeviceRunLockError(
            f"cannot prepare device-lock directory {lock_root}: {error}"
        ) from error
    if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISDIR(metadata.st_mode):
        raise DeviceRunLockError(
            f"device-lock root must be a real directory: {lock_root}"
        )
    if metadata.st_uid != os.getuid():
        raise DeviceRunLockError(
            f"device-lock root is not owned by the current user: {lock_root}"
        )
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise DeviceRunLockError(
            f"device-lock root must not be accessible by other users: {lock_root}"
        )


def _open_lock(path: Path) -> int:
    flags = os.O_RDWR | os.O_CREAT
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(path, flags, 0o600)
        metadata = os.fstat(descriptor)
    except OSError as error:
        raise DeviceRunLockError(f"cannot open device lock {path}: {error}") from error
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or stat.S_IMODE(metadata.st_mode) != 0o600
        or metadata.st_nlink != 1
    ):
        os.close(descriptor)
        raise DeviceRunLockError(
            "device lock must be a singly linked, current-user-owned 0600 "
            f"regular file: {path}"
        )
    return descriptor


def _read_owner(descriptor: int) -> dict | None:
    try:
        os.lseek(descriptor, 0, os.SEEK_SET)
        raw = os.read(descriptor, 16_384)
        value = json.loads(raw) if raw else None
    except (OSError, UnicodeError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _write_descriptor_json(descriptor: int, value: dict) -> None:
    encoded = (json.dumps(value, sort_keys=True) + "\n").encode()
    os.lseek(descriptor, 0, os.SEEK_SET)
    os.ftruncate(descriptor, 0)
    os.write(descriptor, encoded)
    os.fsync(descriptor)


def _write_ready_file(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{path.name}.", suffix=".tmp", dir=path.parent
    )
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as destination:
            json.dump(value, destination, indent=2, sort_keys=True)
            destination.write("\n")
            destination.flush()
            os.fsync(destination.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _parent_is_alive(parent_pid: int) -> bool:
    if parent_pid <= 1:
        return False
    try:
        os.kill(parent_pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _request_stop(_signum: int, _frame: object) -> None:
    global STOP_REQUESTED
    STOP_REQUESTED = True


def _validate_owner(
    owner: dict | None,
    *,
    device_identifier: str,
    expected_owner_pid: int,
    expected_parent_pid: int,
) -> None:
    expected_keys = {
        "formatVersion",
        "authority",
        "deviceIdentifierDigestAlgorithm",
        "deviceIdentifierDigest",
        "deviceIdentifierSuffix",
        "ownerPID",
        "parentPID",
        "acquiredAtUTC",
    }
    if not isinstance(owner, dict) or set(owner) != expected_keys:
        raise DeviceRunLockError("device reservation has malformed owner metadata")
    expected_values = (
        ("formatVersion", 1),
        ("authority", LOCK_AUTHORITY),
        ("deviceIdentifierDigestAlgorithm", "sha256"),
        ("deviceIdentifierDigest", device_identifier_digest(device_identifier)),
        ("deviceIdentifierSuffix", device_identifier[-6:]),
        ("ownerPID", expected_owner_pid),
        ("parentPID", expected_parent_pid),
    )
    for field, expected in expected_values:
        if owner.get(field) != expected:
            raise DeviceRunLockError(
                f"device reservation owner metadata {field} mismatch"
            )
    acquired_at = owner.get("acquiredAtUTC")
    if not isinstance(acquired_at, str) or UTC_TIMESTAMP.fullmatch(acquired_at) is None:
        raise DeviceRunLockError(
            "device reservation owner metadata acquiredAtUTC is malformed"
        )


def assert_lock_held(
    device_identifier: str,
    expected_owner_pid: int,
    parent_pid: int,
    lock_root: Path,
) -> None:
    """Prove the expected live helper still owns the selected device lock."""

    device_identifier = validate_device_identifier(device_identifier)
    if parent_pid != os.getppid() or not _parent_is_alive(parent_pid):
        raise DeviceRunLockError(
            "--parent-pid must name this assertion helper's live direct parent"
        )
    if expected_owner_pid <= 1:
        raise DeviceRunLockError("--owner-pid must name the reservation helper")
    _prepare_lock_root(lock_root)
    descriptor = _open_lock(device_lock_path(lock_root, device_identifier))
    acquired = False
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except BlockingIOError:
            _validate_owner(
                _read_owner(descriptor),
                device_identifier=device_identifier,
                expected_owner_pid=expected_owner_pid,
                expected_parent_pid=parent_pid,
            )
            return
        raise DeviceRunLockError(
            "selected physical device is no longer reserved by the runner"
        )
    finally:
        if acquired:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def hold_lock(
    device_identifier: str,
    parent_pid: int,
    ready_file: Path,
    lock_root: Path,
) -> None:
    device_identifier = validate_device_identifier(device_identifier)
    if parent_pid != os.getppid() or not _parent_is_alive(parent_pid):
        raise DeviceRunLockError(
            "--parent-pid must name this lock helper's live direct parent"
        )
    _prepare_lock_root(lock_root)
    lock_path = device_lock_path(lock_root, device_identifier)
    descriptor = _open_lock(lock_path)
    acquired = False
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except BlockingIOError as error:
            owner = _read_owner(descriptor) or {}
            owner_pid = owner.get("ownerPID", "unknown")
            acquired_at = owner.get("acquiredAtUTC", "unknown time")
            raise DeviceRunLockError(
                "physical device ending in "
                f"{device_identifier[-6:]} is already reserved by qualification "
                f"process {owner_pid} since {acquired_at}"
            ) from error

        owner = {
            "formatVersion": 1,
            "authority": LOCK_AUTHORITY,
            "deviceIdentifierDigestAlgorithm": "sha256",
            "deviceIdentifierDigest": device_identifier_digest(device_identifier),
            "deviceIdentifierSuffix": device_identifier[-6:],
            "ownerPID": os.getpid(),
            "parentPID": parent_pid,
            "acquiredAtUTC": _utc_now(),
        }
        _write_descriptor_json(descriptor, owner)
        _write_ready_file(ready_file, owner)

        signal.signal(signal.SIGINT, _request_stop)
        signal.signal(signal.SIGTERM, _request_stop)
        global STOP_REQUESTED
        STOP_REQUESTED = False
        while not STOP_REQUESTED and _parent_is_alive(parent_pid):
            time.sleep(0.25)
    finally:
        if acquired:
            try:
                _write_descriptor_json(descriptor, {})
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            except OSError:
                pass
        os.close(descriptor)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device-identifier", required=True)
    parser.add_argument("--parent-pid", type=int, required=True)
    parser.add_argument("--ready-file", type=Path)
    parser.add_argument(
        "--assert-held",
        action="store_true",
        help="verify that the expected helper still holds the device lock",
    )
    parser.add_argument("--owner-pid", type=int)
    parser.add_argument("--lock-root", type=Path, default=default_lock_root())
    args = parser.parse_args()
    try:
        if args.assert_held:
            if args.owner_pid is None:
                raise DeviceRunLockError("--assert-held requires --owner-pid")
            if args.ready_file is not None:
                raise DeviceRunLockError(
                    "--ready-file is not accepted with --assert-held"
                )
            assert_lock_held(
                args.device_identifier,
                args.owner_pid,
                args.parent_pid,
                args.lock_root,
            )
        else:
            if args.ready_file is None:
                raise DeviceRunLockError("holding a device lock requires --ready-file")
            if args.owner_pid is not None:
                raise DeviceRunLockError(
                    "--owner-pid is accepted only with --assert-held"
                )
            hold_lock(
                args.device_identifier,
                args.parent_pid,
                args.ready_file,
                args.lock_root,
            )
    except DeviceRunLockError as error:
        print(f"Error: {error}", file=sys.stderr)
        return 75
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
