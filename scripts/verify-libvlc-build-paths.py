#!/usr/bin/env python3
"""Reject host checkout paths embedded in a release XCFramework.

The native build supplies an anchored parent directory descriptor so replacing
an external-root pathname cannot redirect the audit. Artifact entries are then
enumerated, opened, and revalidated relative to retained directory descriptors.
"""

from __future__ import annotations

import argparse
import os
import stat
import sys
from pathlib import Path
from typing import Iterable

CHUNK_SIZE = 1024 * 1024


def fail(message: str) -> None:
    raise SystemExit(f"Error: {message}")


def required_flag(name: str) -> int:
    value = getattr(os, name, None)
    if value is None:
        fail(f"this platform does not provide required {name} support")
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


def validate_component(value: str, description: str) -> None:
    if not value or value in (".", "..") or "/" in value or "\0" in value:
        fail(f"{description} must be one non-special path component: {value!r}")


def stability_signature(metadata: os.stat_result) -> tuple[int, ...]:
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


def require_directory(metadata: os.stat_result, description: str) -> None:
    if not stat.S_ISDIR(metadata.st_mode):
        fail(f"{description} is not a directory")


def require_regular(metadata: os.stat_result, description: str) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        fail(f"{description} is not a regular file")


def stat_at(parent_fd: int, name: str, description: str) -> os.stat_result:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        fail(f"cannot inspect {description}: {error}")


def filesystem_identifier(directory_fd: int, description: str) -> int | None:
    fstatvfs = getattr(os, "fstatvfs", None)
    if fstatvfs is None:
        if sys.platform == "darwin":
            fail(f"cannot verify filesystem identity for {description}")
        return None
    try:
        metadata = fstatvfs(directory_fd)
    except OSError as error:
        fail(f"cannot inspect filesystem identity for {description}: {error}")
    identifier = getattr(metadata, "f_fsid", None)
    if identifier is None:
        if sys.platform == "darwin":
            fail(f"cannot verify filesystem identity for {description}")
        return None
    try:
        return int(identifier)
    except (TypeError, ValueError) as error:
        fail(f"filesystem identity for {description} is invalid: {error}")


def require_opened_directory_containment(
    parent_fd: int,
    parent_metadata: os.stat_result,
    directory_fd: int,
    directory_metadata: os.stat_result,
    description: str,
) -> None:
    if parent_metadata.st_dev != directory_metadata.st_dev:
        fail(f"artifact directory crosses a device boundary: {description}")
    parent_filesystem = filesystem_identifier(parent_fd, "artifact parent")
    child_filesystem = filesystem_identifier(directory_fd, description)
    if parent_filesystem is None and child_filesystem is None:
        return
    if parent_filesystem is None or child_filesystem is None:
        fail(f"cannot consistently verify filesystem identity for {description}")
    if parent_filesystem != child_filesystem:
        fail(f"artifact directory crosses a filesystem boundary: {description}")


def open_named_directory(
    parent_fd: int, name: str, description: str
) -> tuple[int, os.stat_result]:
    named_before = stat_at(parent_fd, name, description)
    require_directory(named_before, description)
    try:
        directory_fd = os.open(name, directory_open_flags(), dir_fd=parent_fd)
    except OSError as error:
        fail(
            f"cannot enumerate XCFramework {description}: "
            f"cannot open without following symlinks: {error}"
        )
    try:
        opened = os.fstat(directory_fd)
        require_directory(opened, description)
        if stability_signature(named_before) != stability_signature(opened):
            fail(f"{description} changed while it was being opened")
        try:
            parent_metadata = os.fstat(parent_fd)
        except OSError as error:
            fail(f"cannot inspect parent directory for {description}: {error}")
        require_directory(parent_metadata, f"parent directory for {description}")
        require_opened_directory_containment(
            parent_fd,
            parent_metadata,
            directory_fd,
            opened,
            description,
        )
        named_after = stat_at(parent_fd, name, description)
        if stability_signature(opened) != stability_signature(named_after):
            fail(f"{description} changed while it was being opened")
        return directory_fd, opened
    except BaseException:
        os.close(directory_fd)
        raise


def open_absolute_directory(
    path: Path, description: str
) -> tuple[int, os.stat_result]:
    try:
        named_before = os.stat(path, follow_symlinks=False)
    except OSError as error:
        fail(f"cannot inspect {description} {path}: {error}")
    require_directory(named_before, description)
    try:
        directory_fd = os.open(path, directory_open_flags())
    except OSError as error:
        fail(f"cannot open {description} without following symlinks {path}: {error}")
    try:
        opened = os.fstat(directory_fd)
        require_directory(opened, description)
        if stability_signature(named_before) != stability_signature(opened):
            fail(f"{description} changed while it was being opened: {path}")
        try:
            named_after = os.stat(path, follow_symlinks=False)
        except OSError as error:
            fail(f"cannot revalidate {description} {path}: {error}")
        if stability_signature(opened) != stability_signature(named_after):
            fail(f"{description} changed while it was being opened: {path}")
        return directory_fd, opened
    except BaseException:
        os.close(directory_fd)
        raise


def list_directory(directory_fd: int, description: str) -> list[str]:
    try:
        with os.scandir(directory_fd) as entries:
            # DirEntry metadata is intentionally ignored. Every decision uses
            # a fresh descriptor-relative, no-follow stat and open below.
            return sorted(entry.name for entry in entries)
    except OSError as error:
        fail(f"cannot enumerate XCFramework {description}: {error}")


def scan_regular(
    parent_fd: int,
    name: str,
    relative_path: str,
    named_before: os.stat_result,
    needles: list[bytes],
) -> list[int]:
    try:
        file_fd = os.open(name, regular_read_flags(), dir_fd=parent_fd)
    except OSError as error:
        fail(f"cannot open artifact file {relative_path} without following symlinks: {error}")
    try:
        opened_before = os.fstat(file_fd)
        require_regular(opened_before, f"artifact file {relative_path}")
        if stability_signature(named_before) != stability_signature(opened_before):
            fail(f"artifact file changed while opening: {relative_path}")

        found: set[int] = set()
        carry_size = max((len(needle) - 1 for needle in needles), default=0)
        overlap = b""
        try:
            while True:
                try:
                    chunk = os.read(file_fd, CHUNK_SIZE)
                except InterruptedError:
                    continue
                if not chunk:
                    break
                payload = overlap + chunk
                for index, needle in enumerate(needles):
                    if index not in found and needle in payload:
                        found.add(index)
                overlap = payload[-carry_size:] if carry_size else b""
        except OSError as error:
            fail(f"cannot scan artifact file {relative_path}: {error}")

        opened_after = os.fstat(file_fd)
        if stability_signature(opened_before) != stability_signature(opened_after):
            fail(f"artifact file changed while it was being scanned: {relative_path}")
        named_after = stat_at(parent_fd, name, f"artifact file {relative_path}")
        require_regular(named_after, f"artifact file {relative_path}")
        if stability_signature(opened_after) != stability_signature(named_after):
            fail(f"artifact file changed while it was being validated: {relative_path}")
        return sorted(found)
    finally:
        os.close(file_fd)


def scan_symlink(
    parent_fd: int,
    name: str,
    relative_path: str,
    named_before: os.stat_result,
    needles: list[bytes],
) -> list[int]:
    try:
        target = os.readlink(name, dir_fd=parent_fd)
    except OSError as error:
        fail(f"cannot read artifact symlink {relative_path}: {error}")
    named_after = stat_at(parent_fd, name, f"artifact symlink {relative_path}")
    if stability_signature(named_before) != stability_signature(named_after):
        fail(f"artifact symlink changed while it was being read: {relative_path}")
    encoded_target = os.fsencode(target)
    return [index for index, needle in enumerate(needles) if needle in encoded_target]


def scan_directory(
    directory_fd: int,
    relative_directory: str,
    needles: list[bytes],
    matches: list[list[str]],
) -> tuple[int, int]:
    description = relative_directory or "."
    try:
        directory_before = os.fstat(directory_fd)
    except OSError as error:
        fail(f"cannot inspect artifact directory {description}: {error}")
    require_directory(directory_before, f"artifact directory {description}")
    names_before = list_directory(directory_fd, description)
    file_count = 0
    symlink_count = 0

    for name in names_before:
        relative_path = f"{relative_directory}/{name}" if relative_directory else name
        named_before = stat_at(directory_fd, name, f"artifact entry {relative_path}")
        if stat.S_ISDIR(named_before.st_mode):
            child_fd, child_metadata = open_named_directory(
                directory_fd, name, f"artifact directory {relative_path}"
            )
            try:
                child_files, child_symlinks = scan_directory(
                    child_fd, relative_path, needles, matches
                )
            finally:
                os.close(child_fd)
            named_after = stat_at(
                directory_fd, name, f"artifact directory {relative_path}"
            )
            if stability_signature(child_metadata) != stability_signature(named_after):
                fail(f"artifact directory changed while it was scanned: {relative_path}")
            file_count += child_files
            symlink_count += child_symlinks
        elif stat.S_ISREG(named_before.st_mode):
            for index in scan_regular(
                directory_fd,
                name,
                relative_path,
                named_before,
                needles,
            ):
                matches[index].append(relative_path)
            file_count += 1
        elif stat.S_ISLNK(named_before.st_mode):
            for index in scan_symlink(
                directory_fd,
                name,
                relative_path,
                named_before,
                needles,
            ):
                matches[index].append(f"{relative_path} (symlink target)")
            symlink_count += 1
        else:
            fail(f"unsupported artifact entry type: {relative_path}")

    names_after = list_directory(directory_fd, description)
    if names_before != names_after:
        fail(f"artifact directory changed while it was scanned: {description}")
    try:
        directory_after = os.fstat(directory_fd)
    except OSError as error:
        fail(f"cannot revalidate artifact directory {description}: {error}")
    if stability_signature(directory_before) != stability_signature(directory_after):
        fail(f"artifact directory changed while it was scanned: {description}")
    return file_count, symlink_count


def canonical_directory(
    raw_path: str | Path, description: str, *, require_canonical: bool = False
) -> Path:
    raw_text = os.fspath(raw_path)
    if not os.path.isabs(raw_text):
        fail(f"{description} must be an absolute path: {raw_text}")
    saved_directory = -1
    try:
        saved_directory = os.open(".", os.O_RDONLY)
        os.chdir(raw_text)
        # getcwd asks the filesystem for the physical spelling. Unlike
        # Path.resolve(), this also canonicalizes case and Unicode aliases on
        # the default case-insensitive Apple filesystems.
        resolved = Path(os.getcwd())
    except NotADirectoryError:
        fail(f"{description} is not a directory: {raw_text}")
    except OSError as error:
        fail(f"cannot resolve {description} {raw_text}: {error}")
    finally:
        if saved_directory >= 0:
            try:
                os.fchdir(saved_directory)
            finally:
                os.close(saved_directory)
    if require_canonical and raw_text != str(resolved):
        fail(f"{description} must use its canonical physical path: {resolved}")
    return resolved


def canonical_forbidden_paths(
    forbidden_paths: Iterable[str | Path],
) -> list[tuple[Path, bytes]]:
    forbidden: list[tuple[Path, bytes]] = []
    seen: set[Path] = set()
    for raw_path in forbidden_paths:
        path = canonical_directory(
            raw_path, "forbidden build path", require_canonical=True
        )
        if path in seen:
            fail(f"duplicate forbidden build path: {path}")
        seen.add(path)
        forbidden.append((path, os.fsencode(path)))
    return forbidden


def verify_opened_artifact(
    artifact_fd: int,
    artifact_display: str,
    forbidden: list[tuple[Path, bytes]],
) -> None:
    matches: list[list[str]] = [[] for _ in forbidden]
    file_count, symlink_count = scan_directory(
        artifact_fd,
        "",
        [needle for _, needle in forbidden],
        matches,
    )
    if file_count == 0 and symlink_count == 0:
        fail(f"XCFramework contains no files or symlinks: {artifact_display}")

    leaks = [
        (forbidden_path, sorted(path_matches))
        for (forbidden_path, _), path_matches in zip(forbidden, matches)
        if path_matches
    ]

    if leaks:
        details = "; ".join(
            f"{path}: {', '.join(matches)}" for path, matches in leaks
        )
        fail(f"release artifact embeds forbidden build path(s): {details}")

    print(
        f"Verified {file_count} file(s) and {symlink_count} symlink(s): "
        "no forbidden build paths embedded."
    )


def verify(xcframework: str | Path, forbidden_paths: list[str | Path]) -> None:
    artifact = canonical_directory(xcframework, "XCFramework")
    artifact_fd, artifact_metadata = open_absolute_directory(artifact, "XCFramework")
    try:
        verify_opened_artifact(
            artifact_fd,
            str(artifact),
            canonical_forbidden_paths(forbidden_paths),
        )
        try:
            named_after = os.stat(artifact, follow_symlinks=False)
        except OSError as error:
            fail(f"cannot revalidate XCFramework {artifact}: {error}")
        if stability_signature(artifact_metadata) != stability_signature(named_after):
            fail(f"XCFramework changed while it was scanned: {artifact}")
    finally:
        os.close(artifact_fd)


def verify_from_parent_descriptor(
    parent_descriptor: int,
    xcframework_child: str,
    forbidden_paths: list[str | Path],
) -> None:
    if parent_descriptor < 0:
        fail("XCFramework parent descriptor must be non-negative")
    validate_component(xcframework_child, "XCFramework child")
    try:
        parent_fd = os.dup(parent_descriptor)
    except OSError as error:
        fail(f"cannot duplicate XCFramework parent descriptor: {error}")
    try:
        try:
            parent_before = os.fstat(parent_fd)
        except OSError as error:
            fail(f"cannot inspect XCFramework parent descriptor: {error}")
        require_directory(parent_before, "XCFramework parent descriptor")
        artifact_fd, artifact_metadata = open_named_directory(
            parent_fd,
            xcframework_child,
            f"XCFramework child {xcframework_child}",
        )
        try:
            verify_opened_artifact(
                artifact_fd,
                f"<parent-fd>/{xcframework_child}",
                canonical_forbidden_paths(forbidden_paths),
            )
        finally:
            os.close(artifact_fd)

        named_after = stat_at(
            parent_fd,
            xcframework_child,
            f"XCFramework child {xcframework_child}",
        )
        if stability_signature(artifact_metadata) != stability_signature(named_after):
            fail(f"XCFramework child changed while it was scanned: {xcframework_child}")
        try:
            parent_after = os.fstat(parent_fd)
        except OSError as error:
            fail(f"cannot revalidate XCFramework parent descriptor: {error}")
        if stability_signature(parent_before) != stability_signature(parent_after):
            fail("XCFramework parent directory changed while artifact was scanned")
    finally:
        os.close(parent_fd)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Reject absolute checkout/build paths in a release XCFramework."
    )
    parser.add_argument(
        "--xcframework",
        help="Absolute path to an XCFramework for a standalone audit.",
    )
    parser.add_argument(
        "--xcframework-parent-fd",
        type=int,
        help="Inherited descriptor for an anchored XCFramework parent directory.",
    )
    parser.add_argument(
        "--xcframework-child",
        help="One-component XCFramework child below --xcframework-parent-fd.",
    )
    parser.add_argument(
        "--forbidden-path",
        action="append",
        required=True,
        help="Absolute directory whose encoded path must not occur in artifact bytes.",
    )
    arguments = parser.parse_args()
    absolute_mode = arguments.xcframework is not None
    descriptor_mode = (
        arguments.xcframework_parent_fd is not None
        or arguments.xcframework_child is not None
    )
    if absolute_mode == descriptor_mode:
        fail(
            "provide either --xcframework or both --xcframework-parent-fd and "
            "--xcframework-child"
        )
    if absolute_mode:
        verify(arguments.xcframework, arguments.forbidden_path)
        return
    if (
        arguments.xcframework_parent_fd is None
        or arguments.xcframework_child is None
    ):
        fail(
            "--xcframework-parent-fd and --xcframework-child must be provided together"
        )
    verify_from_parent_descriptor(
        arguments.xcframework_parent_fd,
        arguments.xcframework_child,
        arguments.forbidden_path,
    )


if __name__ == "__main__":
    main()
