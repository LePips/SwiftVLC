#!/usr/bin/env python3
"""Safely initialize, detach, and revalidate a managed build directory."""

from __future__ import annotations

import argparse
import ctypes
import errno
import hashlib
import json
import os
import secrets
import stat
import sys
import time
from dataclasses import dataclass
from typing import Any, Dict, List, Optional, Tuple

PAYLOAD_NAME = "payload"
IDENTITY_NAME = "identity.json"
IDENTITY_SCHEMA = "org.harflabs.swiftvlc.detached-managed-build-directory"
IDENTITY_VERSION = 1
MAX_IDENTITY_BYTES = 4096
REMOVE_ATTEMPTS = 5
REMOVE_RETRY_DELAY_SECONDS = 1
STAGING_PREFIX = ".swiftvlc-managed-build.initializing-"
LOCK_STAGING_PREFIX = ".swiftvlc-lock.initializing-"


class SafetyError(Exception):
    """A filesystem state failed a safety invariant."""


class ChildAbsentError(Exception):
    """The public managed child did not exist when detachment began."""


@dataclass
class DetachedContext:
    root: str
    child: str
    quarantine: str
    marker_name: str
    marker_bytes: bytes
    root_fd: int
    root_metadata: os.stat_result
    quarantine_fd: int
    quarantine_metadata: os.stat_result
    payload_fd: int
    payload_metadata: os.stat_result

    @property
    def recovery_path(self) -> str:
        return os.path.join(self.root, self.quarantine, PAYLOAD_NAME)

    def close(self) -> None:
        for descriptor_name in ("payload_fd", "quarantine_fd", "root_fd"):
            descriptor = getattr(self, descriptor_name)
            if descriptor >= 0:
                try:
                    os.close(descriptor)
                finally:
                    setattr(self, descriptor_name, -1)


def required_flag(name: str) -> int:
    value = getattr(os, name, None)
    if value is None:
        raise SafetyError(f"this platform does not provide required {name} support")
    return int(value)


def directory_open_flags() -> int:
    return (
        os.O_RDONLY
        | required_flag("O_DIRECTORY")
        | required_flag("O_NOFOLLOW")
        | getattr(os, "O_CLOEXEC", 0)
    )


def regular_read_flags() -> int:
    return (
        os.O_RDONLY
        | required_flag("O_NOFOLLOW")
        | required_flag("O_NONBLOCK")
        | getattr(os, "O_CLOEXEC", 0)
    )


def regular_create_flags() -> int:
    return (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | required_flag("O_NOFOLLOW")
        | getattr(os, "O_CLOEXEC", 0)
    )


def rename_noreplace(
    source_parent_fd: int,
    source_name: str,
    destination_parent_fd: int,
    destination_name: str,
) -> None:
    """Atomically rename a single component without replacing a destination."""

    source = os.fsencode(source_name)
    destination = os.fsencode(destination_name)
    library = ctypes.CDLL(None, use_errno=True)
    function: Any
    flags: int
    if sys.platform == "darwin":
        function = getattr(library, "renameatx_np", None)
        flags = 0x00000004  # RENAME_EXCL
    elif sys.platform.startswith("linux"):
        function = getattr(library, "renameat2", None)
        flags = 0x00000001  # RENAME_NOREPLACE
    else:
        function = None
        flags = 0
    if function is None:
        raise SafetyError(
            "this platform has no supported atomic no-replace rename primitive"
        )
    function.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    function.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = function(
        source_parent_fd,
        source,
        destination_parent_fd,
        destination,
        flags,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(
            error_number,
            os.strerror(error_number),
            f"{source_name} -> {destination_name}",
        )


def validate_component(value: str, description: str) -> None:
    if not value or value in (".", "..") or "/" in value or "\0" in value:
        raise SafetyError(
            f"{description} must be one non-special path component: {value!r}"
        )


def validate_root(root: str) -> None:
    if root == ".":
        return
    if not os.path.isabs(root):
        raise SafetyError(f"root must be an absolute path or exactly '.': {root}")
    if os.path.normpath(root) != root:
        raise SafetyError(f"root must be a normalized absolute path: {root}")


def expected_utf8_line(content: str, description: str) -> bytes:
    try:
        return content.encode("utf-8") + b"\n"
    except UnicodeEncodeError as error:
        raise SafetyError(f"{description} is not valid UTF-8 text: {error}")


def expected_marker_bytes(marker_content: str) -> bytes:
    return expected_utf8_line(marker_content, "marker content")


def binding_specification(
    binding_name: Optional[str],
    binding_content: Optional[str],
    marker_name: str,
) -> Optional[Tuple[str, bytes]]:
    if (binding_name is None) != (binding_content is None):
        raise SafetyError(
            "--binding-name and --binding-content must be provided together"
        )
    if binding_name is None or binding_content is None:
        return None
    validate_component(binding_name, "binding name")
    if binding_name == marker_name:
        raise SafetyError("binding and marker names must differ")
    return binding_name, expected_utf8_line(binding_content, "binding content")


def same_identity(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def describe_identity(metadata: os.stat_result) -> str:
    return f"device={metadata.st_dev}, inode={metadata.st_ino}"


def filesystem_identifier(directory_fd: int, description: str) -> Optional[int]:
    """Return an opened directory's filesystem ID when the platform exposes it."""

    fstatvfs = getattr(os, "fstatvfs", None)
    if fstatvfs is None:
        if sys.platform == "darwin":
            raise SafetyError(
                f"cannot verify filesystem identity for {description}: "
                "os.fstatvfs is unavailable"
            )
        return None
    try:
        filesystem_metadata = fstatvfs(directory_fd)
    except OSError as error:
        raise SafetyError(
            f"cannot inspect filesystem identity for {description}: {error}"
        )
    identifier = getattr(filesystem_metadata, "f_fsid", None)
    if identifier is None:
        if sys.platform == "darwin":
            raise SafetyError(
                f"cannot verify filesystem identity for {description}: "
                "f_fsid is unavailable"
            )
        return None
    try:
        return int(identifier)
    except (TypeError, ValueError) as error:
        raise SafetyError(f"filesystem identity for {description} is invalid: {error}")


def require_opened_directory_containment(
    parent_fd: int,
    parent_metadata: os.stat_result,
    directory_fd: int,
    directory_metadata: os.stat_result,
    description: str,
) -> None:
    """Reject a child opened across either a device or filesystem boundary."""

    if parent_metadata.st_dev != directory_metadata.st_dev:
        raise SafetyError(
            f"refusing {description} across a device/filesystem identity boundary "
            f"(parent device={parent_metadata.st_dev}; "
            f"child device={directory_metadata.st_dev})"
        )
    parent_filesystem = filesystem_identifier(parent_fd, "parent directory")
    child_filesystem = filesystem_identifier(directory_fd, description)
    if parent_filesystem is None and child_filesystem is None:
        return
    if parent_filesystem is None or child_filesystem is None:
        raise SafetyError(
            f"cannot consistently verify device/filesystem identity for {description}"
        )
    if parent_filesystem != child_filesystem:
        raise SafetyError(
            f"refusing {description} across a device/filesystem identity boundary "
            f"(parent filesystem={parent_filesystem}; "
            f"child filesystem={child_filesystem})"
        )


def require_directory(metadata: os.stat_result, description: str) -> None:
    if not stat.S_ISDIR(metadata.st_mode):
        raise SafetyError(f"{description} is not a directory")


def require_regular(metadata: os.stat_result, description: str) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        raise SafetyError(f"{description} is not a regular file")


def stat_at(parent_fd: int, name: str, description: str) -> os.stat_result:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise SafetyError(f"cannot inspect {description}: {error}")


def require_named_directory_identity(
    parent_fd: int,
    name: str,
    opened_metadata: os.stat_result,
    description: str,
) -> None:
    named_metadata = stat_at(parent_fd, name, description)
    require_directory(named_metadata, description)
    if not same_identity(named_metadata, opened_metadata):
        raise SafetyError(
            f"{description} identity changed (opened {describe_identity(opened_metadata)}; "
            f"named entry {describe_identity(named_metadata)})"
        )


def require_root_identity(root: str, opened_metadata: os.stat_result) -> None:
    try:
        named_metadata = os.stat(root, follow_symlinks=False)
    except OSError as error:
        raise SafetyError(f"cannot revalidate root {root}: {error}")
    require_directory(named_metadata, f"root {root}")
    if not same_identity(named_metadata, opened_metadata):
        raise SafetyError(
            f"root identity changed (opened {describe_identity(opened_metadata)}; "
            f"named path {describe_identity(named_metadata)})"
        )


def open_root(root: str) -> Tuple[int, os.stat_result]:
    validate_root(root)
    try:
        named_metadata = os.stat(root, follow_symlinks=False)
    except OSError as error:
        raise SafetyError(f"cannot inspect root {root}: {error}")
    require_directory(named_metadata, f"root {root}")
    try:
        root_fd = os.open(root, directory_open_flags())
    except OSError as error:
        raise SafetyError(
            f"cannot open root without following symlinks {root}: {error}"
        )
    try:
        opened_metadata = os.fstat(root_fd)
        require_directory(opened_metadata, f"root {root}")
        if not same_identity(named_metadata, opened_metadata):
            raise SafetyError(
                f"root identity changed while opening {root} "
                f"({describe_identity(named_metadata)} -> "
                f"{describe_identity(opened_metadata)})"
            )
        filesystem_identifier(root_fd, f"root {root}")
        require_root_identity(root, opened_metadata)
        return root_fd, opened_metadata
    except Exception:
        os.close(root_fd)
        raise


def open_inherited_directory(
    descriptor_number: int, description: str
) -> Tuple[int, os.stat_result]:
    """Duplicate a caller-retained directory FD for descriptor-relative work."""

    if descriptor_number < 0:
        raise SafetyError(f"{description} descriptor must be non-negative")
    try:
        directory_fd = os.dup(descriptor_number)
    except OSError as error:
        raise SafetyError(f"cannot duplicate {description} descriptor: {error}")
    try:
        metadata = os.fstat(directory_fd)
        require_directory(metadata, description)
        filesystem_identifier(directory_fd, description)
        require_open_directory_identity(directory_fd, metadata, description)
        return directory_fd, metadata
    except Exception:
        os.close(directory_fd)
        raise


def reject_preserved_lock_state(root_fd: int, child: str) -> None:
    preserved = [
        name
        for name in list_directory(root_fd, "lock parent")
        if name.startswith(LOCK_STAGING_PREFIX)
    ]
    if preserved:
        raise SafetyError(
            "preserved lock handoff state requires inspection before retrying: "
            + ", ".join(preserved)
        )


def acquire_generation_lock(
    root_descriptor: int,
    child: str,
    token_name: str,
    token_content: str,
) -> None:
    """Atomically publish a generation-bound lock below an anchored root FD."""

    validate_component(child, "lock name")
    validate_component(token_name, "lock token name")
    if token_name == child:
        raise SafetyError("lock token name must differ from lock name")
    token_bytes = expected_utf8_line(token_content, "lock token content")
    root_fd, root_metadata = open_inherited_directory(
        root_descriptor, "lock parent"
    )
    staging_fd = -1
    staging_name = ""
    try:
        reject_preserved_lock_state(root_fd, child)
        staging_name, staging_fd, staging_metadata = create_private_staging_directory(
            root_fd, LOCK_STAGING_PREFIX
        )
        create_regular_exclusive(
            staging_fd,
            token_name,
            token_bytes,
            0o600,
            f"private lock token {token_name}",
        )
        require_named_directory_identity(
            root_fd,
            staging_name,
            staging_metadata,
            f"private lock staging directory {staging_name}",
        )
        try:
            rename_noreplace(root_fd, staging_name, root_fd, child)
        except (OSError, SafetyError) as publish_error:
            try:
                cleanup_binding_staging_directory(
                    root_fd,
                    staging_name,
                    staging_fd,
                    staging_metadata,
                    token_name,
                    token_bytes,
                    0o600,
                )
            except SafetyError as cleanup_error:
                raise SafetyError(
                    f"cannot acquire generation lock {child}: {publish_error}; "
                    f"staging cleanup also failed: {cleanup_error}"
                )
            if isinstance(publish_error, OSError) and publish_error.errno == errno.EEXIST:
                raise SafetyError(f"lock already exists: {child}")
            raise SafetyError(
                f"cannot acquire generation lock {child}: {publish_error}"
            )

        require_absent(root_fd, staging_name, f"published lock staging {staging_name}")
        require_named_directory_identity(
            root_fd, child, staging_metadata, f"generation lock {child}"
        )
        actual_token = read_named_regular(
            staging_fd,
            token_name,
            f"generation lock token {token_name}",
            len(token_bytes),
        )
        if actual_token != token_bytes:
            raise SafetyError(f"generation lock token {token_name} changed")
        if list_directory(staging_fd, f"generation lock {child}") != [token_name]:
            raise SafetyError(f"generation lock {child} was unexpectedly populated")
        require_open_directory_identity(root_fd, root_metadata, "lock parent")
    finally:
        if staging_fd >= 0:
            os.close(staging_fd)
        os.close(root_fd)


def release_generation_lock(
    root_descriptor: int,
    child: str,
    token_name: str,
    token_content: str,
) -> None:
    """Retire only the caller's exact generation-bound lock."""

    validate_component(child, "lock name")
    validate_component(token_name, "lock token name")
    token_bytes = expected_utf8_line(token_content, "lock token content")
    root_fd, root_metadata = open_inherited_directory(
        root_descriptor, "lock parent"
    )
    lock_fd = -1
    token_removed = False
    lock_removed = False
    try:
        lock_fd, lock_metadata = open_named_directory(
            root_fd, child, f"generation lock {child}"
        )
        actual_token = read_named_regular(
            lock_fd,
            token_name,
            f"generation lock token {token_name}",
            len(token_bytes),
        )
        if actual_token != token_bytes:
            raise SafetyError(
                f"generation lock {child} belongs to a different invocation"
            )
        if list_directory(lock_fd, f"generation lock {child}") != [token_name]:
            raise SafetyError(f"generation lock {child} is unexpectedly populated")
        require_named_directory_identity(
            root_fd, child, lock_metadata, f"generation lock {child}"
        )
        require_open_directory_identity(root_fd, root_metadata, "lock parent")
        unlink_verified_regular(
            lock_fd,
            token_name,
            token_bytes,
            f"generation lock token {token_name}",
        )
        token_removed = True
        require_named_directory_identity(
            root_fd, child, lock_metadata, f"generation lock {child}"
        )
        if list_directory(lock_fd, f"generation lock {child}"):
            raise SafetyError(f"generation lock {child} was repopulated")
        try:
            os.rmdir(child, dir_fd=root_fd)
        except OSError as error:
            raise SafetyError(f"cannot retire generation lock {child}: {error}")
        lock_removed = True
        require_open_directory_identity(root_fd, root_metadata, "lock parent")
    except (OSError, SafetyError) as error:
        if token_removed and not lock_removed:
            try:
                ensure_exact_regular(
                    lock_fd,
                    token_name,
                    token_bytes,
                    0o600,
                    f"generation lock token {token_name}",
                )
            except SafetyError as restore_error:
                raise SafetyError(
                    f"{error}; lock token restoration also failed: {restore_error}"
                )
        raise
    finally:
        if lock_fd >= 0:
            os.close(lock_fd)
        os.close(root_fd)


def open_named_directory(
    parent_fd: int, name: str, description: str
) -> Tuple[int, os.stat_result]:
    named_metadata = stat_at(parent_fd, name, description)
    require_directory(named_metadata, description)
    try:
        directory_fd = os.open(name, directory_open_flags(), dir_fd=parent_fd)
    except OSError as error:
        raise SafetyError(
            f"cannot open {description} without following symlinks: {error}"
        )
    try:
        opened_metadata = os.fstat(directory_fd)
        require_directory(opened_metadata, description)
        if not same_identity(named_metadata, opened_metadata):
            raise SafetyError(
                f"{description} identity changed while opening "
                f"({describe_identity(named_metadata)} -> "
                f"{describe_identity(opened_metadata)})"
            )
        try:
            parent_metadata = os.fstat(parent_fd)
        except OSError as error:
            raise SafetyError(
                f"cannot inspect parent directory for {description}: {error}"
            )
        require_directory(parent_metadata, f"parent directory for {description}")
        require_opened_directory_containment(
            parent_fd,
            parent_metadata,
            directory_fd,
            opened_metadata,
            description,
        )
        require_named_directory_identity(parent_fd, name, opened_metadata, description)
        return directory_fd, opened_metadata
    except Exception:
        os.close(directory_fd)
        raise


def regular_stability_signature(metadata: os.stat_result) -> Tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def read_all_bounded(file_fd: int, maximum_bytes: int, description: str) -> bytes:
    chunks: List[bytes] = []
    total = 0
    while True:
        try:
            chunk = os.read(file_fd, min(65536, maximum_bytes + 1 - total))
        except InterruptedError:
            continue
        except OSError as error:
            raise SafetyError(f"cannot read {description}: {error}")
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        total += len(chunk)
        if total > maximum_bytes:
            raise SafetyError(
                f"{description} exceeds the {maximum_bytes}-byte safety limit"
            )


def read_named_regular(
    parent_fd: int,
    name: str,
    description: str,
    maximum_bytes: int,
) -> bytes:
    named_before = stat_at(parent_fd, name, description)
    require_regular(named_before, description)
    if named_before.st_size > maximum_bytes:
        raise SafetyError(
            f"{description} exceeds the {maximum_bytes}-byte safety limit"
        )
    try:
        file_fd = os.open(name, regular_read_flags(), dir_fd=parent_fd)
    except OSError as error:
        raise SafetyError(
            f"cannot open {description} without following symlinks: {error}"
        )
    try:
        opened_before = os.fstat(file_fd)
        require_regular(opened_before, description)
        if not same_identity(named_before, opened_before):
            raise SafetyError(f"{description} identity changed while opening")
        payload = read_all_bounded(file_fd, maximum_bytes, description)
        opened_after = os.fstat(file_fd)
        if regular_stability_signature(opened_before) != regular_stability_signature(
            opened_after
        ):
            raise SafetyError(f"{description} changed while it was being read")
        named_after = stat_at(parent_fd, name, description)
        require_regular(named_after, description)
        if not same_identity(opened_after, named_after):
            raise SafetyError(f"{description} identity changed while validating")
        return payload
    finally:
        os.close(file_fd)


def verify_marker(
    directory_fd: int, marker_name: str, marker_bytes: bytes, description: str
) -> None:
    actual = read_named_regular(
        directory_fd,
        marker_name,
        f"{description} marker {marker_name}",
        len(marker_bytes),
    )
    if actual != marker_bytes:
        raise SafetyError(f"{description} marker contents do not match exactly")


def write_all(file_fd: int, payload: bytes, description: str) -> None:
    offset = 0
    while offset < len(payload):
        try:
            written = os.write(file_fd, payload[offset:])
        except InterruptedError:
            continue
        except OSError as error:
            raise SafetyError(f"cannot write {description}: {error}")
        if written <= 0:
            raise SafetyError(f"short write while creating {description}")
        offset += written


def create_regular_exclusive(
    parent_fd: int, name: str, payload: bytes, mode: int, description: str
) -> None:
    try:
        file_fd = os.open(name, regular_create_flags(), mode, dir_fd=parent_fd)
    except OSError as error:
        raise SafetyError(f"cannot exclusively create {description}: {error}")
    try:
        write_all(file_fd, payload, description)
        metadata = os.fstat(file_fd)
        require_regular(metadata, description)
    finally:
        os.close(file_fd)
    actual = read_named_regular(parent_fd, name, description, len(payload))
    if actual != payload:
        raise SafetyError(f"{description} did not retain its exact contents")


def identity_document(
    child: str,
    marker_name: str,
    marker_bytes: bytes,
    payload_metadata: os.stat_result,
) -> Dict[str, Any]:
    return {
        "schema": IDENTITY_SCHEMA,
        "version": IDENTITY_VERSION,
        "device": payload_metadata.st_dev,
        "inode": payload_metadata.st_ino,
        "child": child,
        "payload": PAYLOAD_NAME,
        "markerName": marker_name,
        "markerSHA256": hashlib.sha256(marker_bytes).hexdigest(),
    }


def encode_identity(document: Dict[str, Any]) -> bytes:
    return (json.dumps(document, sort_keys=True, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )


def reject_duplicate_json_keys(pairs: List[Tuple[str, Any]]) -> Dict[str, Any]:
    result: Dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise SafetyError(f"identity metadata repeats key {key!r}")
        result[key] = value
    return result


def decode_identity(payload: bytes) -> Dict[str, Any]:
    try:
        text = payload.decode("utf-8")
        document = json.loads(text, object_pairs_hook=reject_duplicate_json_keys)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SafetyError(f"identity metadata is not valid UTF-8 JSON: {error}")
    if not isinstance(document, dict):
        raise SafetyError("identity metadata must be a JSON object")
    expected_keys = {
        "schema",
        "version",
        "device",
        "inode",
        "child",
        "payload",
        "markerName",
        "markerSHA256",
    }
    if set(document.keys()) != expected_keys:
        missing = sorted(expected_keys - set(document.keys()))
        extra = sorted(set(document.keys()) - expected_keys)
        raise SafetyError(
            f"identity metadata has unexpected fields (missing={missing}, extra={extra})"
        )
    for key in ("schema", "child", "payload", "markerName", "markerSHA256"):
        if type(document[key]) is not str:
            raise SafetyError(f"identity metadata field {key!r} must be a string")
    for key in ("version", "device", "inode"):
        if type(document[key]) is not int or document[key] < 0:
            raise SafetyError(
                f"identity metadata field {key!r} must be a nonnegative integer"
            )
    return document


def require_identity_matches(
    document: Dict[str, Any],
    child: str,
    marker_name: str,
    marker_bytes: bytes,
    payload_metadata: os.stat_result,
) -> None:
    expected = identity_document(child, marker_name, marker_bytes, payload_metadata)
    if document != expected:
        raise SafetyError(
            "identity metadata does not match the detached payload, marker, or names"
        )


def require_absent(parent_fd: int, name: str, description: str) -> None:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise SafetyError(f"cannot inspect {description}: {error}")
    raise SafetyError(f"{description} exists unexpectedly")


def list_directory(directory_fd: int, description: str) -> List[str]:
    try:
        with os.scandir(directory_fd) as entries:
            # DirEntry metadata is intentionally ignored. Every destructive
            # decision below obtains a fresh fd-relative, no-follow stat.
            return sorted(entry.name for entry in entries)
    except OSError as error:
        raise SafetyError(f"cannot enumerate {description}: {error}")


def unlink_verified_regular(
    parent_fd: int,
    name: str,
    expected_payload: bytes,
    description: str,
) -> None:
    actual = read_named_regular(parent_fd, name, description, len(expected_payload))
    if actual != expected_payload:
        raise SafetyError(f"{description} contents do not match exactly")
    before = stat_at(parent_fd, name, description)
    require_regular(before, description)
    current = stat_at(parent_fd, name, description)
    require_regular(current, description)
    if not same_identity(before, current):
        raise SafetyError(f"{description} identity changed before unlink")
    try:
        os.unlink(name, dir_fd=parent_fd)
    except OSError as error:
        raise SafetyError(f"cannot unlink {description}: {error}")


def ensure_exact_regular(
    parent_fd: int,
    name: str,
    payload: bytes,
    mode: int,
    description: str,
) -> None:
    try:
        os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        create_regular_exclusive(parent_fd, name, payload, mode, description)
        return
    except OSError as error:
        raise SafetyError(f"cannot inspect {description}: {error}")
    actual = read_named_regular(parent_fd, name, description, len(payload))
    if actual != payload:
        raise SafetyError(f"{description} exists but does not match exactly")


def cleanup_staging_directory(
    root_fd: int,
    staging_name: str,
    staging_fd: int,
    staging_metadata: os.stat_result,
    marker_name: str,
    marker_bytes: bytes,
    binding_name: Optional[str] = None,
    binding_bytes: Optional[bytes] = None,
) -> None:
    if (binding_name is None) != (binding_bytes is None):
        raise SafetyError("internal staging cleanup received an incomplete binding")
    description = f"private staging directory {staging_name}"
    require_named_directory_identity(
        root_fd, staging_name, staging_metadata, description
    )
    entries = list_directory(staging_fd, description)
    expected_entries = [marker_name]
    if binding_name is not None:
        expected_entries.append(binding_name)
    expected_entries.sort()
    if entries != expected_entries:
        raise SafetyError(
            f"{description} contains unexpected entries and was preserved: {entries}"
        )

    file_specs: List[Tuple[str, bytes, int, str]] = []
    if binding_name is not None and binding_bytes is not None:
        file_specs.append(
            (
                binding_name,
                binding_bytes,
                0o644,
                f"private staging binding {binding_name}",
            )
        )
    file_specs.append(
        (
            marker_name,
            marker_bytes,
            0o644,
            f"private staging marker {marker_name}",
        )
    )

    for name, payload, _, file_description in file_specs:
        actual = read_named_regular(staging_fd, name, file_description, len(payload))
        if actual != payload:
            raise SafetyError(
                f"{file_description} contents do not match exactly; "
                f"{description} was preserved"
            )

    removed_files: List[Tuple[str, bytes, int, str]] = []
    try:
        for name, payload, mode, file_description in file_specs:
            unlink_verified_regular(staging_fd, name, payload, file_description)
            removed_files.append((name, payload, mode, file_description))
    except SafetyError as deletion_error:
        restore_errors: List[str] = []
        for name, payload, mode, file_description in reversed(removed_files):
            try:
                ensure_exact_regular(staging_fd, name, payload, mode, file_description)
            except SafetyError as restore_error:
                restore_errors.append(str(restore_error))
        if restore_errors:
            raise SafetyError(
                f"could not retire staged files safely: {deletion_error}; "
                f"restoration also failed: {'; '.join(restore_errors)}"
            )
        raise SafetyError(
            f"could not retire staged files safely: {deletion_error}; removed "
            "files were restored"
        )
    require_named_directory_identity(
        root_fd, staging_name, staging_metadata, description
    )
    try:
        os.rmdir(staging_name, dir_fd=root_fd)
    except OSError as error:
        restore_errors: List[str] = []
        for name, payload, mode, file_description in reversed(removed_files):
            try:
                ensure_exact_regular(
                    staging_fd,
                    name,
                    payload,
                    mode,
                    file_description,
                )
            except SafetyError as restore_error:
                restore_errors.append(str(restore_error))
        if restore_errors:
            raise SafetyError(
                f"cannot remove {description}: {error}; staged files could not "
                f"all be restored: {'; '.join(restore_errors)}"
            )
        raise SafetyError(f"cannot remove {description}: {error}")


def create_private_staging_directory(
    root_fd: int,
    prefix: str = STAGING_PREFIX,
) -> Tuple[str, int, os.stat_result]:
    for _ in range(8):
        staging_name = prefix + secrets.token_hex(16)
        try:
            os.mkdir(staging_name, 0o700, dir_fd=root_fd)
        except FileExistsError:
            continue
        except OSError as error:
            raise SafetyError(f"cannot create private staging directory: {error}")
        staging_fd, staging_metadata = open_named_directory(
            root_fd,
            staging_name,
            f"private staging directory {staging_name}",
        )
        try:
            os.fchmod(staging_fd, 0o700)
        except OSError as error:
            os.close(staging_fd)
            raise SafetyError(f"cannot secure private staging directory: {error}")
        staging_metadata = os.fstat(staging_fd)
        require_named_directory_identity(
            root_fd,
            staging_name,
            staging_metadata,
            f"private staging directory {staging_name}",
        )
        if stat.S_IMODE(staging_metadata.st_mode) != 0o700:
            os.close(staging_fd)
            raise SafetyError("private staging directory does not have mode 0700")
        return staging_name, staging_fd, staging_metadata
    raise SafetyError("could not allocate a unique private staging directory")


def cleanup_binding_staging_directory(
    root_fd: int,
    staging_name: str,
    staging_fd: int,
    staging_metadata: os.stat_result,
    binding_name: str,
    binding_bytes: bytes,
    binding_mode: int = 0o644,
) -> None:
    description = f"private binding staging directory {staging_name}"
    require_named_directory_identity(
        root_fd, staging_name, staging_metadata, description
    )
    entries = list_directory(staging_fd, description)
    if entries != [binding_name]:
        raise SafetyError(
            f"{description} contains unexpected entries and was preserved: {entries}"
        )
    unlink_verified_regular(
        staging_fd,
        binding_name,
        binding_bytes,
        f"private staged binding {binding_name}",
    )
    require_named_directory_identity(
        root_fd, staging_name, staging_metadata, description
    )
    try:
        os.rmdir(staging_name, dir_fd=root_fd)
    except OSError as error:
        try:
            ensure_exact_regular(
                staging_fd,
                binding_name,
                binding_bytes,
                binding_mode,
                f"private staged binding {binding_name}",
            )
        except SafetyError as restore_error:
            raise SafetyError(
                f"cannot remove {description}: {error}; its binding could not "
                f"be restored: {restore_error}"
            )
        raise SafetyError(
            f"cannot remove {description}: {error}; its binding was restored"
        )


def initialize(
    root: str,
    child: str,
    marker_name: str,
    marker_content: str,
    require_new: bool = False,
    binding_name: Optional[str] = None,
    binding_content: Optional[str] = None,
) -> None:
    validate_component(child, "child")
    validate_component(marker_name, "marker name")
    marker_bytes = expected_marker_bytes(marker_content)
    binding = binding_specification(binding_name, binding_content, marker_name)
    binding_bytes = binding[1] if binding is not None else None
    root_fd, root_metadata = open_root(root)
    managed_fd = -1
    staging_fd = -1
    staging_name = ""
    published = False
    try:
        staging_name, staging_fd, staging_metadata = create_private_staging_directory(
            root_fd
        )
        try:
            create_regular_exclusive(
                staging_fd,
                marker_name,
                marker_bytes,
                0o644,
                f"private staging marker {marker_name}",
            )
            if binding is not None:
                create_regular_exclusive(
                    staging_fd,
                    binding[0],
                    binding[1],
                    0o644,
                    f"private staging binding {binding[0]}",
                )
            require_named_directory_identity(
                root_fd,
                staging_name,
                staging_metadata,
                f"private staging directory {staging_name}",
            )
            rename_noreplace(root_fd, staging_name, root_fd, child)
            published = True
        except OSError as error:
            if error.errno != errno.EEXIST:
                try:
                    cleanup_staging_directory(
                        root_fd,
                        staging_name,
                        staging_fd,
                        staging_metadata,
                        marker_name,
                        marker_bytes,
                        binding_name,
                        binding_bytes,
                    )
                except SafetyError as cleanup_error:
                    raise SafetyError(
                        f"cannot atomically publish managed child {child}: {error}; "
                        f"staging cleanup also failed: {cleanup_error}"
                    )
                raise SafetyError(
                    f"cannot atomically publish managed child {child}: {error}"
                )
            cleanup_staging_directory(
                root_fd,
                staging_name,
                staging_fd,
                staging_metadata,
                marker_name,
                marker_bytes,
                binding_name,
                binding_bytes,
            )
            if require_new:
                raise SafetyError(
                    f"managed child {child} already exists but a new directory "
                    "was required"
                )

        if published:
            require_absent(
                root_fd,
                staging_name,
                f"published staging name {staging_name}",
            )
            require_named_directory_identity(
                root_fd, child, staging_metadata, f"managed child {child}"
            )
            verify_marker(
                staging_fd, marker_name, marker_bytes, f"managed child {child}"
            )
            if binding is not None:
                actual_binding = read_named_regular(
                    staging_fd,
                    binding[0],
                    f"managed child binding {binding[0]}",
                    len(binding[1]),
                )
                if actual_binding != binding[1]:
                    raise SafetyError(
                        f"managed child binding {binding[0]} contents do not "
                        "match exactly"
                    )
            require_named_directory_identity(
                root_fd, child, staging_metadata, f"managed child {child}"
            )
        else:
            managed_fd, managed_metadata = open_named_directory(
                root_fd, child, f"managed child {child}"
            )
            verify_marker(
                managed_fd, marker_name, marker_bytes, f"managed child {child}"
            )
            require_named_directory_identity(
                root_fd, child, managed_metadata, f"managed child {child}"
            )
            if binding is not None:
                create_regular_exclusive(
                    managed_fd,
                    binding[0],
                    binding[1],
                    0o644,
                    f"managed child binding {binding[0]}",
                )
                require_named_directory_identity(
                    root_fd, child, managed_metadata, f"managed child {child}"
                )

        require_root_identity(root, root_metadata)
    except (OSError, SafetyError):
        if staging_fd >= 0 and staging_name and not published:
            try:
                os.stat(staging_name, dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                pass
            except OSError:
                pass
            else:
                # Most paths already cleaned staging explicitly. Preserve it
                # here rather than risk a second cleanup after interference.
                pass
        raise
    finally:
        if managed_fd >= 0:
            os.close(managed_fd)
        if staging_fd >= 0:
            os.close(staging_fd)
        os.close(root_fd)


def bind(
    root: str,
    child: str,
    binding_name: str,
    binding_content: str,
    create: bool = False,
) -> None:
    """Bind an opened directory, optionally publishing an absent binding-only child."""

    validate_component(child, "child")
    validate_component(binding_name, "binding name")
    binding_bytes = expected_utf8_line(binding_content, "binding content")
    root_fd, root_metadata = open_root(root)
    child_fd = -1
    staging_fd = -1
    try:
        try:
            child_fd, child_metadata = open_named_directory(
                root_fd, child, f"binding child {child}"
            )
        except SafetyError as child_error:
            try:
                os.stat(child, dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                if not create:
                    raise SafetyError(f"binding child {child} is absent")
            except OSError:
                raise child_error
            else:
                raise child_error

            staging_name, staging_fd, staging_metadata = (
                create_private_staging_directory(root_fd)
            )
            try:
                create_regular_exclusive(
                    staging_fd,
                    binding_name,
                    binding_bytes,
                    0o644,
                    f"private staged binding {binding_name}",
                )
                require_named_directory_identity(
                    root_fd,
                    staging_name,
                    staging_metadata,
                    f"private binding staging directory {staging_name}",
                )
                rename_noreplace(root_fd, staging_name, root_fd, child)
            except (OSError, SafetyError) as publish_error:
                try:
                    cleanup_binding_staging_directory(
                        root_fd,
                        staging_name,
                        staging_fd,
                        staging_metadata,
                        binding_name,
                        binding_bytes,
                    )
                except SafetyError as cleanup_error:
                    raise SafetyError(
                        f"cannot atomically publish binding child {child}: "
                        f"{publish_error}; staging cleanup also failed: "
                        f"{cleanup_error}"
                    )
                raise SafetyError(
                    f"cannot atomically publish binding child {child}: "
                    f"{publish_error}"
                )

            require_absent(
                root_fd,
                staging_name,
                f"published binding staging name {staging_name}",
            )
            require_named_directory_identity(
                root_fd, child, staging_metadata, f"binding child {child}"
            )
            actual_binding = read_named_regular(
                staging_fd,
                binding_name,
                f"child binding {binding_name}",
                len(binding_bytes),
            )
            if actual_binding != binding_bytes:
                raise SafetyError(
                    f"child binding {binding_name} contents do not match exactly"
                )
            require_named_directory_identity(
                root_fd, child, staging_metadata, f"binding child {child}"
            )
            require_root_identity(root, root_metadata)
            return

        require_named_directory_identity(
            root_fd, child, child_metadata, f"binding child {child}"
        )
        create_regular_exclusive(
            child_fd,
            binding_name,
            binding_bytes,
            0o644,
            f"child binding {binding_name}",
        )
        require_named_directory_identity(
            root_fd, child, child_metadata, f"binding child {child}"
        )
        require_root_identity(root, root_metadata)
    finally:
        if staging_fd >= 0:
            os.close(staging_fd)
        if child_fd >= 0:
            os.close(child_fd)
        os.close(root_fd)


def validate_publication_entries(
    child: str, binding_name: str, entries: List[str]
) -> None:
    if not entries:
        raise SafetyError("publish requires at least one --entry")
    seen = set()
    for entry in entries:
        validate_component(entry, "publication entry")
        if entry in seen:
            raise SafetyError(f"duplicate publication entry: {entry}")
        seen.add(entry)
        if entry == binding_name:
            raise SafetyError(
                f"publication entry must differ from binding name: {entry}"
            )
        if entry == child:
            raise SafetyError(
                f"publication entry must differ from containing child: {entry}"
            )


def require_publication_context(
    root: str,
    child: str,
    root_fd: int,
    root_metadata: os.stat_result,
    child_fd: int,
    child_metadata: os.stat_result,
) -> None:
    require_open_directory_identity(root_fd, root_metadata, f"root {root}")
    require_open_directory_identity(
        child_fd, child_metadata, f"publication child {child}"
    )
    require_opened_directory_containment(
        root_fd,
        root_metadata,
        child_fd,
        child_metadata,
        f"publication child {child}",
    )
    require_named_directory_identity(
        root_fd, child, child_metadata, f"publication child {child}"
    )
    require_root_identity(root, root_metadata)


def publish(
    root: str,
    child: str,
    binding_name: str,
    binding_content: str,
    entries: List[str],
) -> None:
    """Publish an ordered set of bound child entries without unsafe rollback."""

    validate_component(child, "child")
    validate_component(binding_name, "binding name")
    validate_publication_entries(child, binding_name, entries)
    binding_bytes = expected_utf8_line(binding_content, "binding content")
    root_fd, root_metadata = open_root(root)
    child_fd = -1
    published: List[Tuple[str, os.stat_result]] = []
    moved_names: List[str] = []
    try:
        child_fd, child_metadata = open_named_directory(
            root_fd, child, f"publication child {child}"
        )
        require_publication_context(
            root,
            child,
            root_fd,
            root_metadata,
            child_fd,
            child_metadata,
        )
        actual_binding = read_named_regular(
            child_fd,
            binding_name,
            f"publication binding {binding_name}",
            len(binding_bytes),
        )
        if actual_binding != binding_bytes:
            raise SafetyError(
                f"publication binding {binding_name} contents do not match exactly"
            )

        expected_child_entries = sorted([binding_name] + entries)
        actual_child_entries = list_directory(child_fd, f"publication child {child}")
        if actual_child_entries != expected_child_entries:
            raise SafetyError(
                f"publication child contains unexpected or missing entries; "
                f"expected {expected_child_entries}, found {actual_child_entries}"
            )
        for entry in entries:
            require_absent(root_fd, entry, f"publication destination {entry}")

        for entry in entries:
            require_publication_context(
                root,
                child,
                root_fd,
                root_metadata,
                child_fd,
                child_metadata,
            )
            require_absent(root_fd, entry, f"publication destination {entry}")
            source_metadata = stat_at(child_fd, entry, f"publication source {entry}")
            try:
                rename_noreplace(child_fd, entry, root_fd, entry)
            except OSError as error:
                raise SafetyError(f"cannot atomically publish entry {entry}: {error}")
            moved_names.append(entry)
            destination_metadata = stat_at(
                root_fd, entry, f"published destination {entry}"
            )
            if not same_identity(source_metadata, destination_metadata):
                raise SafetyError(
                    f"published destination {entry} is not the source entry "
                    f"({describe_identity(source_metadata)} -> "
                    f"{describe_identity(destination_metadata)})"
                )
            require_absent(child_fd, entry, f"moved publication source {entry}")
            published.append((entry, destination_metadata))
            require_publication_context(
                root,
                child,
                root_fd,
                root_metadata,
                child_fd,
                child_metadata,
            )

        for entry, expected_metadata in published:
            destination_metadata = stat_at(
                root_fd, entry, f"published destination {entry}"
            )
            if not same_identity(expected_metadata, destination_metadata):
                raise SafetyError(
                    f"published destination {entry} identity changed before "
                    "publication completed"
                )
        remaining = list_directory(child_fd, f"publication child {child}")
        if remaining != [binding_name]:
            raise SafetyError(
                f"publication child gained unexpected entries after handoff: "
                f"{remaining}"
            )

        unlink_verified_regular(
            child_fd,
            binding_name,
            binding_bytes,
            f"publication binding {binding_name}",
        )
        require_publication_context(
            root,
            child,
            root_fd,
            root_metadata,
            child_fd,
            child_metadata,
        )
        if list_directory(child_fd, f"publication child {child}"):
            ensure_exact_regular(
                child_fd,
                binding_name,
                binding_bytes,
                0o644,
                f"publication binding {binding_name}",
            )
            raise SafetyError(
                "publication child was repopulated; its exact binding was restored"
            )
        try:
            os.rmdir(child, dir_fd=root_fd)
        except OSError as error:
            try:
                ensure_exact_regular(
                    child_fd,
                    binding_name,
                    binding_bytes,
                    0o644,
                    f"publication binding {binding_name}",
                )
            except SafetyError as restore_error:
                raise SafetyError(
                    f"cannot retire publication child ({error}) and could not "
                    f"restore its binding: {restore_error}"
                )
            raise SafetyError(
                f"cannot retire publication child ({error}); its exact binding "
                "was restored"
            )
        require_absent(root_fd, child, f"retired publication child {child}")
        require_root_identity(root, root_metadata)
    except (OSError, SafetyError) as error:
        if moved_names:
            published_names = ", ".join(moved_names)
            raise SafetyError(
                f"{error}; publication stopped after moving: {published_names}. "
                "Published destinations were left in place and no rollback was "
                "attempted; no recursive cleanup targeted remaining child state"
            )
        raise
    finally:
        if child_fd >= 0:
            os.close(child_fd)
        os.close(root_fd)


def detach_open(
    root: str,
    child: str,
    quarantine: str,
    marker_name: str,
    marker_content: str,
) -> DetachedContext:
    validate_component(child, "child")
    validate_component(quarantine, "quarantine")
    validate_component(marker_name, "marker name")
    if quarantine == child:
        raise SafetyError("child and quarantine names must differ")
    marker_bytes = expected_marker_bytes(marker_content)
    recovery_path = os.path.join(root, quarantine, PAYLOAD_NAME)
    root_fd, root_metadata = open_root(root)
    child_fd = -1
    quarantine_fd = -1
    renamed = False
    succeeded = False
    try:
        try:
            child_fd, child_metadata = open_named_directory(
                root_fd, child, f"managed child {child}"
            )
        except SafetyError as error:
            try:
                os.stat(child, dir_fd=root_fd, follow_symlinks=False)
            except FileNotFoundError:
                raise ChildAbsentError(
                    f"managed child is absent: {os.path.join(root, child)}"
                )
            except OSError:
                pass
            raise error

        verify_marker(child_fd, marker_name, marker_bytes, f"managed child {child}")
        require_named_directory_identity(
            root_fd, child, child_metadata, f"managed child {child}"
        )

        try:
            os.mkdir(quarantine, 0o700, dir_fd=root_fd)
        except OSError as error:
            raise SafetyError(
                f"cannot exclusively create quarantine {quarantine}: {error}"
            )
        quarantine_fd, quarantine_metadata = open_named_directory(
            root_fd, quarantine, f"quarantine {quarantine}"
        )
        try:
            os.fchmod(quarantine_fd, 0o700)
        except OSError as error:
            raise SafetyError(f"cannot secure quarantine {quarantine}: {error}")
        quarantine_metadata = os.fstat(quarantine_fd)
        require_named_directory_identity(
            root_fd,
            quarantine,
            quarantine_metadata,
            f"quarantine {quarantine}",
        )
        if stat.S_IMODE(quarantine_metadata.st_mode) != 0o700:
            raise SafetyError(f"quarantine {quarantine} does not have mode 0700")
        require_absent(quarantine_fd, PAYLOAD_NAME, "quarantine payload")
        require_absent(quarantine_fd, IDENTITY_NAME, "quarantine identity metadata")

        # This is the authorization boundary: the final public-name identity
        # check and the rename are followed by proof that the detached entry is
        # the exact directory that was opened and verified above.
        require_named_directory_identity(
            root_fd, child, child_metadata, f"managed child {child}"
        )
        try:
            rename_noreplace(root_fd, child, quarantine_fd, PAYLOAD_NAME)
        except OSError as error:
            raise SafetyError(
                f"cannot atomically detach managed child {child}: {error}"
            )
        renamed = True

        require_named_directory_identity(
            root_fd,
            quarantine,
            quarantine_metadata,
            f"quarantine {quarantine}",
        )

        detached_fd, payload_metadata = open_named_directory(
            quarantine_fd, PAYLOAD_NAME, "detached payload"
        )
        try:
            if not same_identity(child_metadata, payload_metadata):
                raise SafetyError(
                    "detached payload is not the verified managed child "
                    f"(expected {describe_identity(child_metadata)}; found "
                    f"{describe_identity(payload_metadata)})"
                )
            verify_marker(detached_fd, marker_name, marker_bytes, "detached payload")
            require_named_directory_identity(
                quarantine_fd,
                PAYLOAD_NAME,
                payload_metadata,
                "detached payload",
            )
        finally:
            os.close(detached_fd)

        require_absent(root_fd, child, f"public managed child {child}")
        require_named_directory_identity(
            root_fd,
            quarantine,
            quarantine_metadata,
            f"quarantine {quarantine}",
        )
        require_root_identity(root, root_metadata)

        document = identity_document(child, marker_name, marker_bytes, payload_metadata)
        encoded_document = encode_identity(document)
        create_regular_exclusive(
            quarantine_fd,
            IDENTITY_NAME,
            encoded_document,
            0o600,
            "quarantine identity metadata",
        )
        decoded_document = decode_identity(
            read_named_regular(
                quarantine_fd,
                IDENTITY_NAME,
                "quarantine identity metadata",
                MAX_IDENTITY_BYTES,
            )
        )
        require_identity_matches(
            decoded_document, child, marker_name, marker_bytes, payload_metadata
        )

        require_named_directory_identity(
            quarantine_fd, PAYLOAD_NAME, payload_metadata, "detached payload"
        )
        require_absent(root_fd, child, f"public managed child {child}")
        require_named_directory_identity(
            root_fd,
            quarantine,
            quarantine_metadata,
            f"quarantine {quarantine}",
        )
        require_root_identity(root, root_metadata)
        succeeded = True
        return DetachedContext(
            root=root,
            child=child,
            quarantine=quarantine,
            marker_name=marker_name,
            marker_bytes=marker_bytes,
            root_fd=root_fd,
            root_metadata=root_metadata,
            quarantine_fd=quarantine_fd,
            quarantine_metadata=quarantine_metadata,
            payload_fd=child_fd,
            payload_metadata=child_metadata,
        )
    except ChildAbsentError:
        raise
    except (OSError, SafetyError) as error:
        if renamed:
            raise SafetyError(
                f"{error}; detached payload was not deleted and is preserved at "
                f"{recovery_path}"
            )
        raise
    finally:
        if not succeeded:
            if quarantine_fd >= 0:
                os.close(quarantine_fd)
            if child_fd >= 0:
                os.close(child_fd)
            os.close(root_fd)


def detach(
    root: str,
    child: str,
    quarantine: str,
    marker_name: str,
    marker_content: str,
) -> None:
    context = detach_open(root, child, quarantine, marker_name, marker_content)
    context.close()


def require_open_directory_identity(
    directory_fd: int,
    expected_metadata: os.stat_result,
    description: str,
) -> None:
    try:
        current = os.fstat(directory_fd)
    except OSError as error:
        raise SafetyError(f"cannot inspect opened {description}: {error}")
    require_directory(current, description)
    if not same_identity(current, expected_metadata):
        raise SafetyError(f"opened {description} identity changed unexpectedly")


def verify_detached_context(context: DetachedContext) -> None:
    require_open_directory_identity(
        context.root_fd, context.root_metadata, f"root {context.root}"
    )
    require_open_directory_identity(
        context.quarantine_fd,
        context.quarantine_metadata,
        f"quarantine {context.quarantine}",
    )
    require_open_directory_identity(
        context.payload_fd, context.payload_metadata, "detached payload"
    )
    require_opened_directory_containment(
        context.root_fd,
        context.root_metadata,
        context.quarantine_fd,
        context.quarantine_metadata,
        f"quarantine {context.quarantine}",
    )
    require_opened_directory_containment(
        context.quarantine_fd,
        context.quarantine_metadata,
        context.payload_fd,
        context.payload_metadata,
        "detached payload",
    )
    if stat.S_IMODE(os.fstat(context.quarantine_fd).st_mode) != 0o700:
        raise SafetyError(f"quarantine {context.quarantine} does not have mode 0700")
    require_named_directory_identity(
        context.root_fd,
        context.quarantine,
        context.quarantine_metadata,
        f"quarantine {context.quarantine}",
    )
    require_named_directory_identity(
        context.quarantine_fd,
        PAYLOAD_NAME,
        context.payload_metadata,
        "detached payload",
    )
    identity_payload = read_named_regular(
        context.quarantine_fd,
        IDENTITY_NAME,
        "quarantine identity metadata",
        MAX_IDENTITY_BYTES,
    )
    document = decode_identity(identity_payload)
    require_identity_matches(
        document,
        context.child,
        context.marker_name,
        context.marker_bytes,
        context.payload_metadata,
    )
    verify_marker(
        context.payload_fd,
        context.marker_name,
        context.marker_bytes,
        "detached payload",
    )
    require_absent(
        context.root_fd,
        context.child,
        f"public managed child {context.child}",
    )
    require_root_identity(context.root, context.root_metadata)


def open_detached_context(
    root: str,
    child: str,
    quarantine: str,
    marker_name: str,
    marker_content: str,
) -> DetachedContext:
    validate_component(child, "child")
    validate_component(quarantine, "quarantine")
    validate_component(marker_name, "marker name")
    if quarantine == child:
        raise SafetyError("child and quarantine names must differ")
    marker_bytes = expected_marker_bytes(marker_content)
    root_fd, root_metadata = open_root(root)
    quarantine_fd = -1
    payload_fd = -1
    succeeded = False
    try:
        quarantine_fd, quarantine_metadata = open_named_directory(
            root_fd, quarantine, f"quarantine {quarantine}"
        )
        if stat.S_IMODE(quarantine_metadata.st_mode) != 0o700:
            raise SafetyError(f"quarantine {quarantine} does not have mode 0700")
        payload_fd, payload_metadata = open_named_directory(
            quarantine_fd, PAYLOAD_NAME, "detached payload"
        )
        context = DetachedContext(
            root=root,
            child=child,
            quarantine=quarantine,
            marker_name=marker_name,
            marker_bytes=marker_bytes,
            root_fd=root_fd,
            root_metadata=root_metadata,
            quarantine_fd=quarantine_fd,
            quarantine_metadata=quarantine_metadata,
            payload_fd=payload_fd,
            payload_metadata=payload_metadata,
        )
        verify_detached_context(context)
        succeeded = True
        return context
    finally:
        if not succeeded:
            if payload_fd >= 0:
                os.close(payload_fd)
            if quarantine_fd >= 0:
                os.close(quarantine_fd)
            os.close(root_fd)


def verify(
    root: str,
    child: str,
    quarantine: str,
    marker_name: str,
    marker_content: str,
) -> None:
    context = open_detached_context(
        root, child, quarantine, marker_name, marker_content
    )
    context.close()


def remove_entry(
    parent_fd: int,
    name: str,
    expected_device: int,
    description: str,
) -> bool:
    """Remove one fd-relative entry; reject device/filesystem boundary crossings."""

    try:
        named_metadata = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except FileNotFoundError:
        return True
    except OSError as error:
        raise SafetyError(f"cannot inspect {description}: {error}")
    if named_metadata.st_dev != expected_device:
        raise SafetyError(
            f"refusing to cross a device/filesystem identity boundary at "
            f"{description}"
        )

    if stat.S_ISDIR(named_metadata.st_mode):
        directory_fd = -1
        try:
            directory_fd, opened_metadata = open_named_directory(
                parent_fd, name, description
            )
            if not same_identity(named_metadata, opened_metadata):
                raise SafetyError(
                    f"{description} identity changed before recursive descent"
                )
            if opened_metadata.st_dev != expected_device:
                raise SafetyError(
                    f"refusing to cross a device/filesystem identity boundary at "
                    f"{description}"
                )
            for child_name in list_directory(directory_fd, description):
                remove_entry(
                    directory_fd,
                    child_name,
                    expected_device,
                    f"{description}/{child_name}",
                )
            require_named_directory_identity(
                parent_fd, name, opened_metadata, description
            )
            if list_directory(directory_fd, description):
                return False
            try:
                os.rmdir(name, dir_fd=parent_fd)
            except OSError as error:
                if error.errno in (errno.ENOTEMPTY, errno.EEXIST):
                    return False
                raise SafetyError(f"cannot remove directory {description}: {error}")
            return True
        finally:
            if directory_fd >= 0:
                os.close(directory_fd)

    current = stat_at(parent_fd, name, description)
    if current.st_dev != expected_device or not same_identity(named_metadata, current):
        raise SafetyError(f"{description} identity changed before unlink")
    if stat.S_ISDIR(current.st_mode):
        raise SafetyError(f"{description} became a directory before unlink")
    try:
        os.unlink(name, dir_fd=parent_fd)
    except FileNotFoundError:
        return True
    except OSError as error:
        raise SafetyError(f"cannot unlink {description}: {error}")
    return True


def restore_marker_after_failed_payload_rmdir(
    context: DetachedContext, original_error: OSError
) -> None:
    try:
        ensure_exact_regular(
            context.payload_fd,
            context.marker_name,
            context.marker_bytes,
            0o644,
            f"detached payload marker {context.marker_name}",
        )
        require_named_directory_identity(
            context.quarantine_fd,
            PAYLOAD_NAME,
            context.payload_metadata,
            "detached payload",
        )
    except SafetyError as restore_error:
        raise SafetyError(
            f"payload removal failed ({original_error}) and its ownership marker "
            f"could not be safely restored: {restore_error}; preserved at "
            f"{context.recovery_path}"
        )


def remove_detached_context(context: DetachedContext) -> None:
    expected_device = context.payload_metadata.st_dev
    identity_bytes = encode_identity(
        identity_document(
            context.child,
            context.marker_name,
            context.marker_bytes,
            context.payload_metadata,
        )
    )

    payload_removed = False
    for attempt in range(1, REMOVE_ATTEMPTS + 1):
        verify_detached_context(context)
        settled = True
        for name in list_directory(context.payload_fd, "detached payload"):
            if name == context.marker_name:
                continue
            if not remove_entry(
                context.payload_fd,
                name,
                expected_device,
                f"detached payload/{name}",
            ):
                settled = False

        verify_detached_context(context)
        remaining = [
            name
            for name in list_directory(context.payload_fd, "detached payload")
            if name != context.marker_name
        ]
        if remaining or not settled:
            if attempt < REMOVE_ATTEMPTS:
                print(
                    "Notice: detached build directory was repopulated during "
                    f"cleanup (attempt {attempt}/{REMOVE_ATTEMPTS}); retrying",
                    file=sys.stderr,
                )
                time.sleep(REMOVE_RETRY_DELAY_SECONDS)
                continue
            break

        unlink_verified_regular(
            context.payload_fd,
            context.marker_name,
            context.marker_bytes,
            f"detached payload marker {context.marker_name}",
        )
        require_named_directory_identity(
            context.quarantine_fd,
            PAYLOAD_NAME,
            context.payload_metadata,
            "detached payload",
        )
        try:
            os.rmdir(PAYLOAD_NAME, dir_fd=context.quarantine_fd)
        except OSError as error:
            restore_marker_after_failed_payload_rmdir(context, error)
            if (
                error.errno in (errno.ENOTEMPTY, errno.EEXIST)
                and attempt < REMOVE_ATTEMPTS
            ):
                print(
                    "Notice: detached build directory was repopulated during "
                    f"final removal (attempt {attempt}/{REMOVE_ATTEMPTS}); retrying",
                    file=sys.stderr,
                )
                time.sleep(REMOVE_RETRY_DELAY_SECONDS)
                continue
            raise SafetyError(
                f"cannot remove detached payload after restoring its marker: {error}; "
                f"preserved at {context.recovery_path}"
            )
        payload_removed = True
        break

    if not payload_removed:
        verify_detached_context(context)
        raise SafetyError(
            f"detached payload did not settle after {REMOVE_ATTEMPTS} attempts; "
            f"preserved at {context.recovery_path}"
        )

    require_absent(context.quarantine_fd, PAYLOAD_NAME, "removed detached payload")
    require_named_directory_identity(
        context.root_fd,
        context.quarantine,
        context.quarantine_metadata,
        f"quarantine {context.quarantine}",
    )
    require_root_identity(context.root, context.root_metadata)
    require_absent(
        context.root_fd,
        context.child,
        f"public managed child {context.child}",
    )

    actual_identity = read_named_regular(
        context.quarantine_fd,
        IDENTITY_NAME,
        "quarantine identity metadata",
        MAX_IDENTITY_BYTES,
    )
    if actual_identity != identity_bytes:
        raise SafetyError(
            f"identity metadata changed after payload removal; preserving quarantine "
            f"{os.path.join(context.root, context.quarantine)}"
        )
    entries = list_directory(context.quarantine_fd, f"quarantine {context.quarantine}")
    if entries != [IDENTITY_NAME]:
        raise SafetyError(
            f"quarantine contains unexpected entries after payload removal and was "
            f"preserved: {entries}"
        )
    unlink_verified_regular(
        context.quarantine_fd,
        IDENTITY_NAME,
        identity_bytes,
        "quarantine identity metadata",
    )
    require_named_directory_identity(
        context.root_fd,
        context.quarantine,
        context.quarantine_metadata,
        f"quarantine {context.quarantine}",
    )
    try:
        os.rmdir(context.quarantine, dir_fd=context.root_fd)
    except OSError as error:
        try:
            ensure_exact_regular(
                context.quarantine_fd,
                IDENTITY_NAME,
                identity_bytes,
                0o600,
                "quarantine identity metadata",
            )
        except SafetyError as restore_error:
            raise SafetyError(
                f"cannot retire quarantine ({error}) and could not restore its "
                f"identity metadata: {restore_error}"
            )
        raise SafetyError(
            f"cannot retire quarantine after restoring its identity metadata: {error}"
        )
    require_absent(
        context.root_fd,
        context.quarantine,
        f"retired quarantine {context.quarantine}",
    )
    require_root_identity(context.root, context.root_metadata)


def remove(
    root: str,
    child: str,
    quarantine: str,
    marker_name: str,
    marker_content: str,
) -> None:
    context = open_detached_context(
        root, child, quarantine, marker_name, marker_content
    )
    try:
        remove_detached_context(context)
    finally:
        context.close()


def clean(
    root: str,
    child: str,
    quarantine: str,
    marker_name: str,
    marker_content: str,
) -> None:
    context = detach_open(root, child, quarantine, marker_name, marker_content)
    try:
        remove_detached_context(context)
    except (OSError, SafetyError) as error:
        raise SafetyError(f"{error}; clean stopped without pathname-recursive fallback")
    finally:
        context.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Initialize, bind, publish, or atomically quarantine a managed "
            "external directory without following entries through symlinks."
        )
    )
    subparsers = parser.add_subparsers(dest="operation", required=True)

    def add_common(subparser: argparse.ArgumentParser) -> None:
        subparser.add_argument("--root", required=True)
        subparser.add_argument("--child", required=True)
        subparser.add_argument("--marker-name", required=True)
        subparser.add_argument(
            "--marker-content",
            required=True,
            help="UTF-8 marker text; exactly one trailing LF is added",
        )

    initialize_parser = subparsers.add_parser(
        "initialize", help="exclusively create or verify the managed child"
    )
    add_common(initialize_parser)
    initialize_parser.add_argument(
        "--require-new",
        action="store_true",
        help="fail if the public managed child already exists",
    )
    initialize_parser.add_argument(
        "--binding-name",
        help="unique file to bind this initialization to its caller",
    )
    initialize_parser.add_argument(
        "--binding-content",
        help="UTF-8 binding text; exactly one trailing LF is added",
    )

    bind_parser = subparsers.add_parser(
        "bind", help="exclusively bind an existing opened child directory"
    )
    add_common(bind_parser)
    bind_parser.add_argument("--binding-name", required=True)
    bind_parser.add_argument("--binding-content", required=True)
    bind_parser.add_argument(
        "--create",
        action="store_true",
        help="atomically publish a binding-only child when it is absent",
    )

    publish_parser = subparsers.add_parser(
        "publish", help="atomically publish ordered entries from a bound child"
    )
    add_common(publish_parser)
    publish_parser.add_argument("--binding-name", required=True)
    publish_parser.add_argument("--binding-content", required=True)
    publish_parser.add_argument(
        "--entry",
        action="append",
        required=True,
        help="direct child component to publish; repeat in publication order",
    )

    for operation in ("lock-acquire", "lock-release"):
        lock_parser = subparsers.add_parser(
            operation,
            help="operate on a generation-bound lock below an inherited directory FD",
        )
        lock_parser.add_argument("--root-fd", type=int, required=True)
        lock_parser.add_argument("--child", required=True)
        lock_parser.add_argument("--token-name", required=True)
        lock_parser.add_argument("--token-content", required=True)

    for operation in ("detach", "verify", "remove", "clean"):
        operation_parser = subparsers.add_parser(operation)
        add_common(operation_parser)
        operation_parser.add_argument("--quarantine", required=True)

    return parser


def main() -> int:
    arguments = build_parser().parse_args()
    try:
        if arguments.operation == "initialize":
            initialize(
                arguments.root,
                arguments.child,
                arguments.marker_name,
                arguments.marker_content,
                arguments.require_new,
                arguments.binding_name,
                arguments.binding_content,
            )
        elif arguments.operation == "bind":
            bind(
                arguments.root,
                arguments.child,
                arguments.binding_name,
                arguments.binding_content,
                arguments.create,
            )
        elif arguments.operation == "publish":
            publish(
                arguments.root,
                arguments.child,
                arguments.binding_name,
                arguments.binding_content,
                arguments.entry,
            )
        elif arguments.operation == "lock-acquire":
            acquire_generation_lock(
                arguments.root_fd,
                arguments.child,
                arguments.token_name,
                arguments.token_content,
            )
        elif arguments.operation == "lock-release":
            release_generation_lock(
                arguments.root_fd,
                arguments.child,
                arguments.token_name,
                arguments.token_content,
            )
        elif arguments.operation == "detach":
            detach(
                arguments.root,
                arguments.child,
                arguments.quarantine,
                arguments.marker_name,
                arguments.marker_content,
            )
        elif arguments.operation == "verify":
            verify(
                arguments.root,
                arguments.child,
                arguments.quarantine,
                arguments.marker_name,
                arguments.marker_content,
            )
        elif arguments.operation == "remove":
            remove(
                arguments.root,
                arguments.child,
                arguments.quarantine,
                arguments.marker_name,
                arguments.marker_content,
            )
        else:
            clean(
                arguments.root,
                arguments.child,
                arguments.quarantine,
                arguments.marker_name,
                arguments.marker_content,
            )
    except ChildAbsentError as error:
        print(f"Notice: {error}", file=sys.stderr)
        return 3
    except (OSError, SafetyError) as error:
        print(f"Error: {error}", file=sys.stderr)
        return 1
    except RecursionError:
        print(
            "Error: managed build tree exceeds the safe traversal depth; "
            "cleanup stopped without a pathname-recursive fallback",
            file=sys.stderr,
        )
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
