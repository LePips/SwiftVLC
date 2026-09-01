#!/usr/bin/env python3
"""Validate Mach-O metadata in every object shipped by a libVLC XCFramework.

The validator deliberately parses universal binaries, static archives, and
Mach-O load commands itself.  It does not depend on the wording or output
shape of ``otool``, ``lipo``, or ``ar``.  That makes it suitable both as a
release gate and as structured qualification evidence.
"""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
import json
import math
import mmap
from pathlib import Path
import plistlib
import struct
import sys
from typing import Any, Mapping, Sequence

AR_MAGIC = b"!<arch>\n"
THIN_AR_MAGIC = b"!<thin>\n"
AR_HEADER_SIZE = 60

FAT_MAGIC = 0xCAFEBABE
FAT_MAGIC_64 = 0xCAFEBABF
FAT_MAGICS: dict[bytes, tuple[str, bool]] = {
    struct.pack(">I", FAT_MAGIC): (">", False),
    struct.pack("<I", FAT_MAGIC): ("<", False),
    struct.pack(">I", FAT_MAGIC_64): (">", True),
    struct.pack("<I", FAT_MAGIC_64): ("<", True),
}

MH_MAGIC_64 = 0xFEEDFACF
MACH_MAGICS: dict[bytes, str] = {
    struct.pack("<I", MH_MAGIC_64): "<",
    struct.pack(">I", MH_MAGIC_64): ">",
}

CPU_TYPE_X86_64 = 0x01000007
CPU_TYPE_ARM64 = 0x0100000C
CPU_TYPES = {
    CPU_TYPE_X86_64: "x86_64",
    CPU_TYPE_ARM64: "arm64",
}
ARCHITECTURE_CPU_TYPES = {value: key for key, value in CPU_TYPES.items()}

MH_OBJECT = 0x1
LC_SEGMENT = 0x1
LC_SEGMENT_64 = 0x19
LC_BUILD_VERSION = 0x32
LEGACY_PLATFORM_COMMANDS = {
    0x24: "LC_VERSION_MIN_MACOSX",
    0x25: "LC_VERSION_MIN_IPHONEOS",
    0x2F: "LC_VERSION_MIN_TVOS",
    0x30: "LC_VERSION_MIN_WATCHOS",
}

ZERO_FILL_SECTION_TYPES = {
    0x1,  # S_ZEROFILL
    0xC,  # S_GB_ZEROFILL
    0x12,  # S_THREAD_LOCAL_ZEROFILL
}

PLATFORM_POLICIES: dict[tuple[str, str | None], tuple[str, int, str]] = {
    ("macos", None): ("macos", 1, "macOS"),
    ("ios", None): ("ios", 2, "iOS"),
    ("tvos", None): ("tvos", 3, "tvOS"),
    ("ios", "maccatalyst"): ("catalyst", 6, "Mac Catalyst"),
    ("ios", "simulator"): ("ios", 7, "iOS Simulator"),
    ("tvos", "simulator"): ("tvos", 8, "tvOS Simulator"),
    ("xros", None): ("xros", 11, "visionOS"),
    ("xros", "simulator"): ("xros", 12, "visionOS Simulator"),
}

DEFAULT_ALIGNMENT_CAPS = {
    "x86_64": 12,  # 4 KiB
    "arm64": 14,  # 16 KiB
}

SPECIAL_ARCHIVE_MEMBERS = {
    "/",
    "/SYM64/",
    "__.SYMDEF",
    "__.SYMDEF SORTED",
    "__.SYMDEF_64",
    "__.SYMDEF_64 SORTED",
}


class BinaryFormatError(ValueError):
    """A fail-closed structural error with a stable report code."""

    def __init__(self, code: str, message: str, offset: int | None = None):
        super().__init__(message)
        self.code = code
        self.message = message
        self.offset = offset


@dataclass(frozen=True)
class ContainerSlice:
    architecture: str | None
    cpu_type: int | None
    offset: int
    size: int
    alignment_exponent: int | None
    fat_index: int | None


@dataclass(frozen=True)
class ArchiveMember:
    name: str
    ordinal: int
    header_offset: int
    payload_offset: int
    payload_size: int
    is_special: bool


@dataclass(frozen=True)
class BuildVersion:
    platform: int
    minimum_os: int
    sdk: int
    tools: tuple[tuple[int, int], ...]


@dataclass(frozen=True)
class SectionMetadata:
    segment_name: str
    section_name: str
    alignment_exponent: int


@dataclass(frozen=True)
class MachObject:
    architecture: str
    cpu_type: int
    build_versions: tuple[BuildVersion, ...]
    legacy_platform_commands: tuple[str, ...]
    sections: tuple[SectionMetadata, ...]


@dataclass(frozen=True)
class Violation:
    code: str
    message: str
    slice_identifier: str | None = None
    architecture: str | None = None
    member: str | None = None
    member_ordinal: int | None = None
    file_offset: int | None = None
    details: Mapping[str, Any] | None = None

    def as_dict(self) -> dict[str, Any]:
        result: dict[str, Any] = {
            "code": self.code,
            "message": self.message,
        }
        optional = {
            "slice_identifier": self.slice_identifier,
            "architecture": self.architecture,
            "member": self.member,
            "member_ordinal": self.member_ordinal,
            "file_offset": self.file_offset,
        }
        result.update(
            {key: value for key, value in optional.items() if value is not None}
        )
        if self.details:
            result["details"] = dict(self.details)
        return result


def _checked_end(offset: int, size: int, limit: int, description: str) -> int:
    if offset < 0 or size < 0 or offset > limit or size > limit - offset:
        raise BinaryFormatError(
            "out_of_bounds",
            f"{description} range offset={offset} size={size} exceeds limit={limit}",
            offset,
        )
    return offset + size


def _checked_relative_end(
    object_offset: int,
    relative_offset: int,
    size: int,
    object_size: int,
    description: str,
) -> int:
    """Validate an object-relative range while reporting an absolute file offset."""
    if (
        relative_offset < 0
        or size < 0
        or relative_offset > object_size
        or size > object_size - relative_offset
    ):
        raise BinaryFormatError(
            "out_of_bounds",
            f"{description} object-relative range offset={relative_offset} "
            f"size={size} exceeds object size={object_size}",
            object_offset + relative_offset,
        )
    return relative_offset + size


def _unpack_from(
    format_string: str,
    buffer: bytes | mmap.mmap,
    offset: int,
    limit: int,
    description: str,
) -> tuple[Any, ...]:
    size = struct.calcsize(format_string)
    _checked_end(offset, size, limit, description)
    return struct.unpack_from(format_string, buffer, offset)


def parse_version(value: str) -> int:
    fields = value.split(".")
    if len(fields) not in (2, 3) or any(not field.isdigit() for field in fields):
        raise ValueError(
            f"invalid Apple version {value!r}; expected MAJOR.MINOR[.PATCH]"
        )
    numbers = [int(field) for field in fields]
    if len(numbers) == 2:
        numbers.append(0)
    major, minor, patch = numbers
    if major > 0xFFFF or minor > 0xFF or patch > 0xFF:
        raise ValueError(f"Apple version component out of range: {value!r}")
    return (major << 16) | (minor << 8) | patch


def format_version(value: int) -> str:
    major = value >> 16
    minor = (value >> 8) & 0xFF
    patch = value & 0xFF
    return f"{major}.{minor}" if patch == 0 else f"{major}.{minor}.{patch}"


def _decode_fixed_name(raw: bytes) -> str:
    return raw.split(b"\0", 1)[0].decode("utf-8", errors="replace")


def _json_safe_metadata_value(value: Any) -> Any:
    """Keep malformed plist metadata reportable without breaking JSON output."""
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        return value if math.isfinite(value) else repr(value)
    if isinstance(value, bytes):
        preview_limit = 64
        return {
            "type": "data",
            "length": len(value),
            "hex_preview": value[:preview_limit].hex(),
            "truncated": len(value) > preview_limit,
        }
    if isinstance(value, (list, tuple)):
        return [_json_safe_metadata_value(item) for item in value]
    if isinstance(value, dict):
        return {
            str(key): _json_safe_metadata_value(item) for key, item in value.items()
        }
    return repr(value)


def parse_container_slices(buffer: bytes | mmap.mmap) -> list[ContainerSlice]:
    length = len(buffer)
    if (
        length >= len(THIN_AR_MAGIC)
        and bytes(buffer[: len(THIN_AR_MAGIC)]) == THIN_AR_MAGIC
    ):
        raise BinaryFormatError(
            "gnu_thin_archive",
            "GNU thin archives are not self-contained release artifacts",
            0,
        )
    if length >= len(AR_MAGIC) and bytes(buffer[: len(AR_MAGIC)]) == AR_MAGIC:
        return [ContainerSlice(None, None, 0, length, None, None)]
    if length < 8:
        raise BinaryFormatError(
            "unknown_container",
            "library is too short to contain a universal binary or archive",
            0,
        )

    fat = FAT_MAGICS.get(bytes(buffer[:4]))
    if fat is None:
        raise BinaryFormatError(
            "unknown_container",
            f"unrecognized library magic {bytes(buffer[:8]).hex()}",
            0,
        )

    endian, is_64_bit = fat
    (architecture_count,) = _unpack_from(
        endian + "I", buffer, 4, length, "universal architecture count"
    )
    if architecture_count == 0:
        raise BinaryFormatError(
            "empty_universal_binary", "universal binary contains no slices", 4
        )

    record_format = endian + ("IIQQII" if is_64_bit else "IIIII")
    record_size = struct.calcsize(record_format)
    table_end = _checked_end(
        8,
        architecture_count * record_size,
        length,
        "universal architecture table",
    )
    slices: list[ContainerSlice] = []
    seen_architectures: set[str] = set()

    for index in range(architecture_count):
        record_offset = 8 + index * record_size
        values = _unpack_from(
            record_format,
            buffer,
            record_offset,
            table_end,
            f"universal architecture record {index}",
        )
        cpu_type, _cpu_subtype, slice_offset, slice_size, alignment = values[:5]
        if is_64_bit and values[5] != 0:
            raise BinaryFormatError(
                "nonzero_fat64_reserved",
                f"universal slice {index} has nonzero FAT64 reserved field "
                f"{values[5]}",
                record_offset + 28,
            )
        architecture = CPU_TYPES.get(cpu_type)
        if architecture is None:
            raise BinaryFormatError(
                "unsupported_cpu_type",
                f"universal slice {index} uses unsupported CPU type 0x{cpu_type:08x}",
                record_offset,
            )
        if architecture in seen_architectures:
            raise BinaryFormatError(
                "duplicate_universal_architecture",
                f"universal binary contains architecture {architecture!r} more than once",
                record_offset,
            )
        seen_architectures.add(architecture)
        if alignment > 62:
            raise BinaryFormatError(
                "invalid_universal_alignment",
                f"universal slice {index} has unreasonable alignment exponent {alignment}",
                record_offset,
            )
        if slice_size == 0:
            raise BinaryFormatError(
                "empty_universal_slice",
                f"universal slice {index} is empty",
                record_offset,
            )
        slice_end = _checked_end(
            slice_offset,
            slice_size,
            length,
            f"universal slice {index}",
        )
        if slice_offset < table_end:
            raise BinaryFormatError(
                "universal_slice_overlaps_header",
                f"universal slice {index} begins inside its architecture table",
                slice_offset,
            )
        required_alignment = 1 << alignment
        if slice_offset % required_alignment != 0:
            raise BinaryFormatError(
                "misaligned_universal_slice",
                f"universal slice {index} offset {slice_offset} is not aligned to "
                f"2^{alignment}",
                slice_offset,
            )
        slices.append(
            ContainerSlice(
                architecture,
                cpu_type,
                slice_offset,
                slice_end - slice_offset,
                alignment,
                index,
            )
        )

    ordered = sorted(slices, key=lambda item: item.offset)
    for previous, current in zip(ordered, ordered[1:]):
        previous_end = previous.offset + previous.size
        if current.offset < previous_end:
            raise BinaryFormatError(
                "overlapping_universal_slices",
                f"universal slices {previous.fat_index} and {current.fat_index} overlap",
                current.offset,
            )
    return slices


def _parse_decimal_field(raw: bytes, description: str, offset: int) -> int:
    try:
        text = raw.decode("ascii").strip()
    except UnicodeDecodeError as error:
        raise BinaryFormatError(
            "invalid_archive_header", f"{description} is not ASCII", offset
        ) from error
    if not text or not text.isdigit():
        raise BinaryFormatError(
            "invalid_archive_header",
            f"{description} is not an unsigned decimal integer: {text!r}",
            offset,
        )
    return int(text)


def _decode_gnu_name(table: bytes, offset: int, header_offset: int) -> str:
    if offset < 0 or offset >= len(table):
        raise BinaryFormatError(
            "invalid_gnu_name_reference",
            f"GNU archive-name offset {offset} is outside the string table",
            header_offset,
        )
    end = table.find(b"\n", offset)
    if end < 0:
        raise BinaryFormatError(
            "unterminated_gnu_name",
            f"GNU archive name at string-table offset {offset} is unterminated",
            header_offset,
        )
    raw = table[offset:end]
    if raw.endswith(b"/"):
        raw = raw[:-1]
    if not raw:
        raise BinaryFormatError(
            "empty_archive_member_name",
            f"GNU archive name at string-table offset {offset} is empty",
            header_offset,
        )
    return raw.decode("utf-8", errors="replace")


def parse_archive_members(
    buffer: bytes | mmap.mmap, archive_offset: int, archive_size: int
) -> list[ArchiveMember]:
    archive_end = _checked_end(
        archive_offset, archive_size, len(buffer), "archive slice"
    )
    _checked_end(archive_offset, len(AR_MAGIC), archive_end, "archive magic")
    magic = bytes(buffer[archive_offset : archive_offset + len(AR_MAGIC)])
    if magic == THIN_AR_MAGIC:
        raise BinaryFormatError(
            "gnu_thin_archive",
            "GNU thin archives are not self-contained release artifacts",
            archive_offset,
        )
    if magic != AR_MAGIC:
        if bytes(buffer[archive_offset : archive_offset + 4]) in FAT_MAGICS:
            raise BinaryFormatError(
                "nested_universal_archive",
                "a universal slice must contain an ordinary archive, not another "
                "universal binary",
                archive_offset,
            )
        raise BinaryFormatError(
            "invalid_archive_magic",
            f"universal slice does not start with {AR_MAGIC!r}",
            archive_offset,
        )

    position = archive_offset + len(AR_MAGIC)
    ordinal = 0
    members: list[ArchiveMember] = []
    gnu_name_table: bytes | None = None

    while position < archive_end:
        header_offset = position
        header_end = _checked_end(
            header_offset, AR_HEADER_SIZE, archive_end, "archive member header"
        )
        header = bytes(buffer[header_offset:header_end])
        if header[58:60] != b"`\n":
            raise BinaryFormatError(
                "invalid_archive_header_trailer",
                f"archive member {ordinal + 1} has an invalid header trailer",
                header_offset + 58,
            )
        try:
            raw_name = header[:16].decode("ascii").rstrip()
        except UnicodeDecodeError as error:
            raise BinaryFormatError(
                "invalid_archive_header",
                f"archive member {ordinal + 1} name field is not ASCII",
                header_offset,
            ) from error
        stored_size = _parse_decimal_field(
            header[48:58], f"archive member {ordinal + 1} size", header_offset + 48
        )
        data_offset = header_end
        data_end = _checked_end(
            data_offset,
            stored_size,
            archive_end,
            f"archive member {ordinal + 1} data",
        )
        payload_offset = data_offset
        payload_size = stored_size

        if raw_name.startswith("#1/"):
            extension = raw_name[3:]
            if not extension.isdigit():
                raise BinaryFormatError(
                    "invalid_bsd_extended_name",
                    f"archive member {ordinal + 1} has invalid BSD name length "
                    f"{extension!r}",
                    header_offset,
                )
            name_size = int(extension)
            if name_size == 0 or name_size > stored_size:
                raise BinaryFormatError(
                    "invalid_bsd_extended_name",
                    f"archive member {ordinal + 1} BSD name length {name_size} "
                    f"exceeds stored size {stored_size}",
                    header_offset,
                )
            name_storage = bytes(buffer[data_offset : data_offset + name_size])
            first_nul = name_storage.find(b"\0")
            if first_nul >= 0:
                if any(name_storage[first_nul:]):
                    raise BinaryFormatError(
                        "invalid_bsd_extended_name",
                        f"archive member {ordinal + 1} has non-NUL data after its "
                        "BSD name terminator",
                        data_offset + first_nul,
                    )
                name_storage = name_storage[:first_nul]
            if not name_storage:
                raise BinaryFormatError(
                    "empty_archive_member_name",
                    f"archive member {ordinal + 1} has an empty BSD name",
                    data_offset,
                )
            name = name_storage.decode("utf-8", errors="replace")
            payload_offset += name_size
            payload_size -= name_size
        elif raw_name == "//":
            name = raw_name
            gnu_name_table = bytes(buffer[data_offset:data_end])
        elif raw_name.startswith("/") and raw_name[1:].isdigit():
            if gnu_name_table is None:
                raise BinaryFormatError(
                    "missing_gnu_name_table",
                    f"archive member {ordinal + 1} references a GNU name table "
                    "before one is defined",
                    header_offset,
                )
            name = _decode_gnu_name(gnu_name_table, int(raw_name[1:]), header_offset)
        elif raw_name in {"/", "/SYM64/"}:
            name = raw_name
        else:
            name = raw_name[:-1] if raw_name.endswith("/") else raw_name
            if not name:
                raise BinaryFormatError(
                    "empty_archive_member_name",
                    f"archive member {ordinal + 1} has an empty name",
                    header_offset,
                )

        ordinal += 1
        members.append(
            ArchiveMember(
                name=name,
                ordinal=ordinal,
                header_offset=header_offset,
                payload_offset=payload_offset,
                payload_size=payload_size,
                is_special=name == "//" or name in SPECIAL_ARCHIVE_MEMBERS,
            )
        )

        position = data_end
        if stored_size & 1:
            position = _checked_end(
                position, 1, archive_end, f"archive member {ordinal} padding"
            )

    if position != archive_end:
        raise BinaryFormatError(
            "invalid_archive_boundary",
            "archive does not end on a member boundary",
            position,
        )
    if not members:
        raise BinaryFormatError(
            "empty_archive", "archive contains no members", archive_offset
        )
    return members


def _validate_section_ranges(
    buffer: bytes | mmap.mmap,
    object_offset: int,
    object_size: int,
    endian: str,
    section_offset: int,
) -> SectionMetadata:
    section_format = endian + "16s16sQQIIIIIIII"
    values = _unpack_from(
        section_format,
        buffer,
        section_offset,
        object_offset + object_size,
        "Mach-O section_64",
    )
    (
        raw_section_name,
        raw_segment_name,
        _address,
        size,
        file_offset,
        alignment,
        relocation_offset,
        relocation_count,
        flags,
        _reserved1,
        _reserved2,
        _reserved3,
    ) = values

    section_type = flags & 0xFF
    if size and section_type not in ZERO_FILL_SECTION_TYPES:
        _checked_relative_end(
            object_offset,
            file_offset,
            size,
            object_size,
            f"Mach-O section {_decode_fixed_name(raw_section_name)!r} data",
        )
    if relocation_count:
        _checked_relative_end(
            object_offset,
            relocation_offset,
            relocation_count * 8,
            object_size,
            f"Mach-O section {_decode_fixed_name(raw_section_name)!r} relocations",
        )
    return SectionMetadata(
        segment_name=_decode_fixed_name(raw_segment_name),
        section_name=_decode_fixed_name(raw_section_name),
        alignment_exponent=alignment,
    )


def parse_mach_object(
    buffer: bytes | mmap.mmap, object_offset: int, object_size: int
) -> MachObject:
    object_end = _checked_end(
        object_offset, object_size, len(buffer), "archive member payload"
    )
    _checked_end(object_offset, 4, object_end, "Mach-O magic")
    magic = bytes(buffer[object_offset : object_offset + 4])
    if magic in FAT_MAGICS:
        raise BinaryFormatError(
            "nested_fat_member",
            "archive member is a nested universal binary instead of a Mach-O object",
            object_offset,
        )
    if magic in {AR_MAGIC[:4], THIN_AR_MAGIC[:4]}:
        raise BinaryFormatError(
            "nested_archive_member",
            "archive member is another archive instead of a Mach-O object",
            object_offset,
        )
    endian = MACH_MAGICS.get(magic)
    if endian is None:
        raise BinaryFormatError(
            "non_mach_object_member",
            f"archive member payload has unsupported Mach-O magic {magic.hex()}",
            object_offset,
        )

    header_format = endian + "IIIIIIII"
    (
        _magic,
        cpu_type,
        _cpu_subtype,
        file_type,
        command_count,
        commands_size,
        _flags,
        _reserved,
    ) = _unpack_from(
        header_format,
        buffer,
        object_offset,
        object_end,
        "Mach-O 64-bit header",
    )
    architecture = CPU_TYPES.get(cpu_type)
    if architecture is None:
        raise BinaryFormatError(
            "unsupported_cpu_type",
            f"Mach-O object uses unsupported CPU type 0x{cpu_type:08x}",
            object_offset + 4,
        )
    if file_type != MH_OBJECT:
        raise BinaryFormatError(
            "non_object_mach_file",
            f"archive member Mach-O filetype is {file_type}, expected MH_OBJECT",
            object_offset + 12,
        )

    header_size = struct.calcsize(header_format)
    commands_offset = object_offset + header_size
    commands_end = _checked_end(
        commands_offset, commands_size, object_end, "Mach-O load-command table"
    )
    if command_count > commands_size // 8:
        raise BinaryFormatError(
            "invalid_load_command_count",
            f"Mach-O declares {command_count} load commands in only "
            f"{commands_size} bytes",
            object_offset + 16,
        )

    build_versions: list[BuildVersion] = []
    legacy_commands: list[str] = []
    sections: list[SectionMetadata] = []
    command_offset = commands_offset

    for command_index in range(command_count):
        command, command_size = _unpack_from(
            endian + "II",
            buffer,
            command_offset,
            commands_end,
            f"Mach-O load command {command_index}",
        )
        if command_size < 8 or command_size % 8 != 0:
            raise BinaryFormatError(
                "invalid_load_command_size",
                f"Mach-O load command {command_index} has invalid size {command_size}",
                command_offset + 4,
            )
        next_command = _checked_end(
            command_offset,
            command_size,
            commands_end,
            f"Mach-O load command {command_index}",
        )

        if command == LC_BUILD_VERSION:
            if command_size < 24:
                raise BinaryFormatError(
                    "invalid_build_version_command",
                    f"LC_BUILD_VERSION is only {command_size} bytes",
                    command_offset,
                )
            platform, minimum_os, sdk, tool_count = _unpack_from(
                endian + "IIII",
                buffer,
                command_offset + 8,
                next_command,
                "LC_BUILD_VERSION fields",
            )
            expected_size = 24 + tool_count * 8
            if expected_size != command_size:
                raise BinaryFormatError(
                    "invalid_build_version_command",
                    f"LC_BUILD_VERSION size {command_size} does not match "
                    f"ntools={tool_count} (expected {expected_size})",
                    command_offset,
                )
            tools: list[tuple[int, int]] = []
            tool_offset = command_offset + 24
            for tool_index in range(tool_count):
                tool, version = _unpack_from(
                    endian + "II",
                    buffer,
                    tool_offset + tool_index * 8,
                    next_command,
                    f"LC_BUILD_VERSION tool {tool_index}",
                )
                tools.append((tool, version))
            build_versions.append(BuildVersion(platform, minimum_os, sdk, tuple(tools)))
        elif command in LEGACY_PLATFORM_COMMANDS:
            if command_size != 16:
                raise BinaryFormatError(
                    "invalid_legacy_platform_command",
                    f"{LEGACY_PLATFORM_COMMANDS[command]} has size {command_size}, "
                    "expected 16",
                    command_offset,
                )
            legacy_commands.append(LEGACY_PLATFORM_COMMANDS[command])
        elif command == LC_SEGMENT:
            raise BinaryFormatError(
                "unexpected_32_bit_segment",
                "64-bit Mach-O object contains LC_SEGMENT instead of LC_SEGMENT_64",
                command_offset,
            )
        elif command == LC_SEGMENT_64:
            if command_size < 72:
                raise BinaryFormatError(
                    "invalid_segment_command",
                    f"LC_SEGMENT_64 is only {command_size} bytes",
                    command_offset,
                )
            (
                _cmd,
                _cmdsize,
                _segment_name,
                _vm_address,
                _vm_size,
                file_offset,
                file_size,
                _max_protection,
                _initial_protection,
                section_count,
                _segment_flags,
            ) = _unpack_from(
                endian + "II16sQQQQiiII",
                buffer,
                command_offset,
                next_command,
                "LC_SEGMENT_64",
            )
            expected_size = 72 + section_count * 80
            if expected_size != command_size:
                raise BinaryFormatError(
                    "invalid_segment_command",
                    f"LC_SEGMENT_64 size {command_size} does not match "
                    f"nsects={section_count} (expected {expected_size})",
                    command_offset,
                )
            if file_size:
                _checked_relative_end(
                    object_offset,
                    file_offset,
                    file_size,
                    object_size,
                    "Mach-O segment file range",
                )
            for section_index in range(section_count):
                sections.append(
                    _validate_section_ranges(
                        buffer,
                        object_offset,
                        object_size,
                        endian,
                        command_offset + 72 + section_index * 80,
                    )
                )

        command_offset = next_command

    if command_offset != commands_end:
        raise BinaryFormatError(
            "load_command_size_mismatch",
            f"Mach-O load commands consume {command_offset - commands_offset} bytes, "
            f"but header declares {commands_size}",
            command_offset,
        )
    return MachObject(
        architecture=architecture,
        cpu_type=cpu_type,
        build_versions=tuple(build_versions),
        legacy_platform_commands=tuple(legacy_commands),
        sections=tuple(sections),
    )


def _blank_report(
    xcframework: Path,
    deployment_targets: Mapping[str, int],
    alignment_caps: Mapping[str, int],
) -> dict[str, Any]:
    return {
        "schema_version": 1,
        "validator": "swiftvlc.libvlc-macho-metadata",
        "xcframework": str(xcframework),
        "status": "fail",
        "policy": {
            "deployment_targets": {
                key: format_version(value)
                for key, value in sorted(deployment_targets.items())
            },
            "section_alignment_caps": {
                key: value for key, value in sorted(alignment_caps.items())
            },
        },
        "summary": {
            "slice_count": 0,
            "architecture_count": 0,
            "archive_member_count": 0,
            "object_count": 0,
            "build_version_command_count": 0,
            "violation_count": 0,
            "violation_counts": {},
        },
        "slices": [],
        "violations": [],
    }


def _add_violation(
    violations: list[Violation],
    code: str,
    message: str,
    *,
    slice_identifier: str | None = None,
    architecture: str | None = None,
    member: ArchiveMember | None = None,
    file_offset: int | None = None,
    details: Mapping[str, Any] | None = None,
) -> None:
    violations.append(
        Violation(
            code=code,
            message=message,
            slice_identifier=slice_identifier,
            architecture=architecture,
            member=member.name if member else None,
            member_ordinal=member.ordinal if member else None,
            file_offset=file_offset,
            details=details,
        )
    )


def _safe_library_path(root: Path, identifier: str, library_path: str) -> Path:
    root_resolved = root.resolve()
    candidate = (root / identifier / library_path).resolve()
    try:
        candidate.relative_to(root_resolved)
    except ValueError as error:
        raise BinaryFormatError(
            "library_path_escape",
            f"XCFramework library path escapes its root: {library_path!r}",
        ) from error
    return candidate


def _validate_object_metadata(
    obj: MachObject,
    member: ArchiveMember,
    *,
    slice_identifier: str,
    container_architecture: str,
    expected_platform: int,
    expected_minimum_os: int,
    alignment_cap: int,
    violations: list[Violation],
) -> None:
    if obj.architecture != container_architecture:
        _add_violation(
            violations,
            "cpu_mismatch",
            f"object CPU {obj.architecture} does not match archive slice "
            f"{container_architecture}",
            slice_identifier=slice_identifier,
            architecture=container_architecture,
            member=member,
            file_offset=member.payload_offset + 4,
            details={
                "actual": obj.architecture,
                "expected": container_architecture,
            },
        )

    command_count = len(obj.build_versions)
    if command_count == 0:
        _add_violation(
            violations,
            "missing_build_version",
            "object has no LC_BUILD_VERSION command",
            slice_identifier=slice_identifier,
            architecture=container_architecture,
            member=member,
            file_offset=member.payload_offset,
            details={"actual_count": 0, "expected_count": 1},
        )
    elif command_count != 1:
        _add_violation(
            violations,
            "multiple_build_versions",
            f"object has {command_count} LC_BUILD_VERSION commands; expected exactly one",
            slice_identifier=slice_identifier,
            architecture=container_architecture,
            member=member,
            file_offset=member.payload_offset,
            details={"actual_count": command_count, "expected_count": 1},
        )
    else:
        build_version = obj.build_versions[0]
        if build_version.platform != expected_platform:
            _add_violation(
                violations,
                "wrong_platform",
                f"LC_BUILD_VERSION platform is {build_version.platform}; "
                f"expected {expected_platform}",
                slice_identifier=slice_identifier,
                architecture=container_architecture,
                member=member,
                file_offset=member.payload_offset,
                details={
                    "actual": build_version.platform,
                    "expected": expected_platform,
                },
            )
        if build_version.minimum_os != expected_minimum_os:
            _add_violation(
                violations,
                "wrong_minimum_os",
                f"LC_BUILD_VERSION minos is "
                f"{format_version(build_version.minimum_os)}; expected "
                f"{format_version(expected_minimum_os)}",
                slice_identifier=slice_identifier,
                architecture=container_architecture,
                member=member,
                file_offset=member.payload_offset,
                details={
                    "actual": format_version(build_version.minimum_os),
                    "expected": format_version(expected_minimum_os),
                },
            )

    for legacy_command in obj.legacy_platform_commands:
        _add_violation(
            violations,
            "legacy_platform_command",
            f"object contains forbidden legacy platform command {legacy_command}",
            slice_identifier=slice_identifier,
            architecture=container_architecture,
            member=member,
            file_offset=member.payload_offset,
            details={"command": legacy_command},
        )

    for section in obj.sections:
        if section.alignment_exponent > alignment_cap:
            _add_violation(
                violations,
                "section_alignment_exceeds_cap",
                f"section {section.segment_name},{section.section_name} requests "
                f"2^{section.alignment_exponent} alignment; {container_architecture} "
                f"cap is 2^{alignment_cap}",
                slice_identifier=slice_identifier,
                architecture=container_architecture,
                member=member,
                file_offset=member.payload_offset,
                details={
                    "segment": section.segment_name,
                    "section": section.section_name,
                    "actual_exponent": section.alignment_exponent,
                    "maximum_exponent": alignment_cap,
                },
            )


def _finalize_report(report: dict[str, Any], violations: list[Violation]) -> None:
    violation_dicts = [violation.as_dict() for violation in violations]
    counts = Counter(violation.code for violation in violations)
    report["violations"] = violation_dicts
    report["summary"]["violation_count"] = len(violations)
    report["summary"]["violation_counts"] = dict(sorted(counts.items()))
    report["status"] = "pass" if not violations else "fail"


def validate_xcframework(
    xcframework: Path,
    deployment_targets: Mapping[str, int | str],
    alignment_caps: Mapping[str, int] | None = None,
) -> dict[str, Any]:
    normalized_targets = {
        key: parse_version(value) if isinstance(value, str) else value
        for key, value in deployment_targets.items()
    }
    normalized_caps = dict(DEFAULT_ALIGNMENT_CAPS)
    if alignment_caps:
        normalized_caps.update(alignment_caps)
    report = _blank_report(xcframework, normalized_targets, normalized_caps)
    violations: list[Violation] = []
    info_path = xcframework / "Info.plist"

    try:
        with info_path.open("rb") as source:
            info = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        _add_violation(
            violations,
            "invalid_xcframework_info",
            f"cannot read {info_path}: {error}",
        )
        _finalize_report(report, violations)
        return report

    libraries = info.get("AvailableLibraries") if isinstance(info, dict) else None
    if not isinstance(libraries, list) or not libraries:
        _add_violation(
            violations,
            "invalid_xcframework_info",
            "Info.plist has no non-empty AvailableLibraries array",
        )
        _finalize_report(report, violations)
        return report

    sortable_libraries: list[tuple[str, int, Any]] = []
    for index, library in enumerate(libraries):
        identifier = (
            library.get("LibraryIdentifier") if isinstance(library, dict) else None
        )
        sort_identifier = identifier if isinstance(identifier, str) else f"~{index}"
        sortable_libraries.append((sort_identifier, index, library))

    seen_identifiers: set[str] = set()
    for _sort_identifier, entry_index, library in sorted(sortable_libraries):
        if not isinstance(library, dict):
            _add_violation(
                violations,
                "invalid_xcframework_entry",
                f"AvailableLibraries entry {entry_index} is not a dictionary",
            )
            continue
        identifier = library.get("LibraryIdentifier")
        library_path_value = library.get("LibraryPath")
        architectures_value = library.get("SupportedArchitectures")
        platform = library.get("SupportedPlatform")
        variant = library.get("SupportedPlatformVariant")

        if not isinstance(identifier, str) or not identifier:
            _add_violation(
                violations,
                "invalid_xcframework_entry",
                f"AvailableLibraries entry {entry_index} has no valid identifier",
            )
            continue
        if identifier in seen_identifiers:
            _add_violation(
                violations,
                "duplicate_library_identifier",
                f"LibraryIdentifier {identifier!r} occurs more than once",
                slice_identifier=identifier,
            )
            continue
        seen_identifiers.add(identifier)

        slice_violations_start = len(violations)
        slice_report: dict[str, Any] = {
            "identifier": identifier,
            "library": _json_safe_metadata_value(library_path_value),
            "supported_platform": _json_safe_metadata_value(platform),
            "supported_platform_variant": _json_safe_metadata_value(variant),
            "expected_architectures": _json_safe_metadata_value(architectures_value),
            "architectures": [],
            "violation_count": 0,
        }
        report["slices"].append(slice_report)

        if not isinstance(library_path_value, str) or not library_path_value:
            _add_violation(
                violations,
                "invalid_xcframework_entry",
                "slice has no valid LibraryPath",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue
        if (
            not isinstance(architectures_value, list)
            or not architectures_value
            or any(not isinstance(item, str) for item in architectures_value)
        ):
            _add_violation(
                violations,
                "invalid_xcframework_entry",
                "slice has no valid SupportedArchitectures array",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue
        expected_architectures = list(architectures_value)
        if len(set(expected_architectures)) != len(expected_architectures):
            _add_violation(
                violations,
                "duplicate_supported_architecture",
                "SupportedArchitectures contains duplicates",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue
        unsupported_architectures = sorted(
            set(expected_architectures) - set(ARCHITECTURE_CPU_TYPES)
        )
        if unsupported_architectures:
            _add_violation(
                violations,
                "unsupported_architecture",
                f"unsupported architectures in Info.plist: "
                f"{', '.join(unsupported_architectures)}",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue
        if not isinstance(platform, str) or (
            variant is not None and not isinstance(variant, str)
        ):
            _add_violation(
                violations,
                "invalid_xcframework_entry",
                "slice has invalid SupportedPlatform metadata",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue

        policy = PLATFORM_POLICIES.get((platform, variant))
        if policy is None:
            _add_violation(
                violations,
                "unsupported_platform",
                f"unsupported platform/variant combination {platform!r}/{variant!r}",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue
        deployment_key, expected_platform, platform_label = policy
        expected_minimum_os = normalized_targets.get(deployment_key)
        if expected_minimum_os is None:
            _add_violation(
                violations,
                "missing_deployment_target_policy",
                f"no deployment target was supplied for {deployment_key!r}",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue
        slice_report["expected_platform_id"] = expected_platform
        slice_report["expected_platform_name"] = platform_label
        slice_report["expected_minimum_os"] = format_version(expected_minimum_os)

        try:
            library_path = _safe_library_path(
                xcframework, identifier, library_path_value
            )
        except BinaryFormatError as error:
            _add_violation(
                violations,
                error.code,
                error.message,
                slice_identifier=identifier,
                file_offset=error.offset,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue
        if not library_path.is_file():
            _add_violation(
                violations,
                "missing_library",
                f"slice library does not exist: {library_path}",
                slice_identifier=identifier,
            )
            slice_report["violation_count"] = len(violations) - slice_violations_start
            continue

        try:
            with library_path.open("rb") as source:
                if source.seek(0, 2) == 0:
                    raise BinaryFormatError(
                        "empty_library", "slice library is empty", 0
                    )
                source.seek(0)
                with mmap.mmap(source.fileno(), 0, access=mmap.ACCESS_READ) as buffer:
                    container_slices = parse_container_slices(buffer)
                    if (
                        len(container_slices) == 1
                        and container_slices[0].architecture is None
                    ):
                        actual_container_architectures = (
                            expected_architectures
                            if len(expected_architectures) == 1
                            else []
                        )
                    else:
                        actual_container_architectures = [
                            item.architecture
                            for item in container_slices
                            if item.architecture is not None
                        ]
                    if set(actual_container_architectures) != set(
                        expected_architectures
                    ):
                        _add_violation(
                            violations,
                            "architecture_set_mismatch",
                            f"archive architectures {sorted(actual_container_architectures)} "
                            f"do not match Info.plist {sorted(expected_architectures)}",
                            slice_identifier=identifier,
                            details={
                                "actual": sorted(actual_container_architectures),
                                "expected": sorted(expected_architectures),
                            },
                        )

                    for container_slice in container_slices:
                        architecture = container_slice.architecture
                        if architecture is None:
                            if len(expected_architectures) != 1:
                                continue
                            architecture = expected_architectures[0]
                        architecture_violations_start = len(violations)
                        architecture_report: dict[str, Any] = {
                            "architecture": architecture,
                            "archive_member_count": 0,
                            "special_member_count": 0,
                            "object_count": 0,
                            "build_version_command_count": 0,
                            "observed_build_versions": {
                                "platform_ids": {},
                                "minimum_os_versions": {},
                                "sdk_versions": {},
                            },
                            "violation_count": 0,
                        }
                        slice_report["architectures"].append(architecture_report)
                        try:
                            members = parse_archive_members(
                                buffer, container_slice.offset, container_slice.size
                            )
                        except BinaryFormatError as error:
                            _add_violation(
                                violations,
                                error.code,
                                error.message,
                                slice_identifier=identifier,
                                architecture=architecture,
                                file_offset=error.offset,
                            )
                            architecture_report["violation_count"] = (
                                len(violations) - architecture_violations_start
                            )
                            continue
                        architecture_report["archive_member_count"] = len(members)
                        report["summary"]["archive_member_count"] += len(members)
                        object_architectures: set[str] = set()
                        platform_counts: Counter[str] = Counter()
                        minimum_os_counts: Counter[str] = Counter()
                        sdk_counts: Counter[str] = Counter()

                        for member in members:
                            if member.is_special:
                                architecture_report["special_member_count"] += 1
                                continue
                            try:
                                obj = parse_mach_object(
                                    buffer, member.payload_offset, member.payload_size
                                )
                            except BinaryFormatError as error:
                                _add_violation(
                                    violations,
                                    error.code,
                                    error.message,
                                    slice_identifier=identifier,
                                    architecture=architecture,
                                    member=member,
                                    file_offset=error.offset,
                                )
                                continue

                            object_architectures.add(obj.architecture)
                            architecture_report["object_count"] += 1
                            architecture_report["build_version_command_count"] += len(
                                obj.build_versions
                            )
                            report["summary"]["object_count"] += 1
                            report["summary"]["build_version_command_count"] += len(
                                obj.build_versions
                            )
                            for build_version in obj.build_versions:
                                platform_counts[str(build_version.platform)] += 1
                                minimum_os_counts[
                                    format_version(build_version.minimum_os)
                                ] += 1
                                sdk_counts[
                                    (
                                        "n/a"
                                        if build_version.sdk == 0
                                        else format_version(build_version.sdk)
                                    )
                                ] += 1
                            alignment_cap = normalized_caps.get(architecture)
                            if alignment_cap is None:
                                _add_violation(
                                    violations,
                                    "missing_alignment_policy",
                                    f"no section-alignment cap supplied for "
                                    f"{architecture!r}",
                                    slice_identifier=identifier,
                                    architecture=architecture,
                                    member=member,
                                )
                                continue
                            _validate_object_metadata(
                                obj,
                                member,
                                slice_identifier=identifier,
                                container_architecture=architecture,
                                expected_platform=expected_platform,
                                expected_minimum_os=expected_minimum_os,
                                alignment_cap=alignment_cap,
                                violations=violations,
                            )

                        if not object_architectures:
                            _add_violation(
                                violations,
                                "archive_has_no_mach_objects",
                                "archive slice contains no readable Mach-O objects",
                                slice_identifier=identifier,
                                architecture=architecture,
                                file_offset=container_slice.offset,
                            )
                        architecture_report["observed_build_versions"] = {
                            "platform_ids": dict(sorted(platform_counts.items())),
                            "minimum_os_versions": dict(
                                sorted(minimum_os_counts.items())
                            ),
                            "sdk_versions": dict(sorted(sdk_counts.items())),
                        }
                        architecture_report["violation_count"] = (
                            len(violations) - architecture_violations_start
                        )
        except (OSError, BinaryFormatError) as error:
            if isinstance(error, BinaryFormatError):
                code, message, offset = error.code, error.message, error.offset
            else:
                code, message, offset = "library_read_error", str(error), None
            _add_violation(
                violations,
                code,
                message,
                slice_identifier=identifier,
                file_offset=offset,
            )

        slice_report["architectures"].sort(key=lambda item: item["architecture"])
        slice_report["violation_count"] = len(violations) - slice_violations_start

    report["summary"]["slice_count"] = len(report["slices"])
    report["summary"]["architecture_count"] = sum(
        len(item["architectures"]) for item in report["slices"]
    )
    _finalize_report(report, violations)
    return report


def _parse_assignments(
    values: Sequence[str], *, known_keys: set[str], value_name: str
) -> dict[str, str]:
    result: dict[str, str] = {}
    for value in values:
        if "=" not in value:
            raise ValueError(f"{value_name} must use KEY=VALUE syntax: {value!r}")
        key, assigned = value.split("=", 1)
        if key not in known_keys:
            raise ValueError(
                f"unknown {value_name} key {key!r}; expected one of "
                f"{', '.join(sorted(known_keys))}"
            )
        if key in result:
            raise ValueError(f"duplicate {value_name} key {key!r}")
        if not assigned:
            raise ValueError(f"empty {value_name} value for {key!r}")
        result[key] = assigned
    return result


def _human_location(violation: Mapping[str, Any]) -> str:
    parts = []
    if violation.get("slice_identifier"):
        parts.append(str(violation["slice_identifier"]))
    if violation.get("architecture"):
        parts.append(str(violation["architecture"]))
    if violation.get("member"):
        member = str(violation["member"])
        if violation.get("member_ordinal") is not None:
            member += f"#{violation['member_ordinal']}"
        parts.append(member)
    return "/".join(parts) if parts else "xcframework"


def print_human_report(report: Mapping[str, Any], maximum_diagnostics: int) -> None:
    summary = report["summary"]
    status = str(report["status"]).upper()
    print(
        f"{status}: {summary['object_count']} Mach-O objects across "
        f"{summary['architecture_count']} architecture slices; "
        f"{summary['violation_count']} violation(s)"
    )
    counts = summary["violation_counts"]
    if counts:
        print(
            "Violation counts: "
            + ", ".join(f"{key}={value}" for key, value in sorted(counts.items()))
        )

    violations = report["violations"]
    if maximum_diagnostics == 0:
        shown = violations
    else:
        shown = violations[:maximum_diagnostics]
    for violation in shown:
        print(
            f"error[{violation['code']}]: {_human_location(violation)}: "
            f"{violation['message']}",
            file=sys.stderr,
        )
    omitted = len(violations) - len(shown)
    if omitted:
        print(
            f"error: {omitted} additional violation(s) omitted; use --json or "
            "--max-diagnostics 0 for the complete report",
            file=sys.stderr,
        )


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xcframework", required=True, type=Path)
    parser.add_argument(
        "--deployment-target",
        action="append",
        default=[],
        metavar="PLATFORM=VERSION",
        help="Expected minimum for ios, tvos, xros, macos, or catalyst",
    )
    parser.add_argument(
        "--alignment-cap",
        action="append",
        default=[],
        metavar="ARCH=EXPONENT",
        help="Override the maximum section-alignment exponent for an architecture",
    )
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument(
        "--json", action="store_true", help="Write the complete JSON report to stdout"
    )
    output_group.add_argument(
        "--json-output", type=Path, help="Write the complete JSON report to this file"
    )
    parser.add_argument(
        "--max-diagnostics",
        type=int,
        default=50,
        help="Maximum human-readable errors to print; 0 prints all (default: 50)",
    )
    arguments = parser.parse_args(argv)
    if arguments.max_diagnostics < 0:
        parser.error("--max-diagnostics cannot be negative")
    try:
        target_values = _parse_assignments(
            arguments.deployment_target,
            known_keys={"ios", "tvos", "xros", "macos", "catalyst"},
            value_name="deployment target",
        )
        arguments.deployment_targets = {
            key: parse_version(value) for key, value in target_values.items()
        }
        cap_values = _parse_assignments(
            arguments.alignment_cap,
            known_keys=set(ARCHITECTURE_CPU_TYPES),
            value_name="alignment cap",
        )
        arguments.alignment_caps = dict(DEFAULT_ALIGNMENT_CAPS)
        for key, value in cap_values.items():
            if not value.isdigit() or int(value) > 62:
                raise ValueError(
                    f"alignment cap for {key!r} must be an exponent from 0 through 62"
                )
            arguments.alignment_caps[key] = int(value)
    except ValueError as error:
        parser.error(str(error))
    return arguments


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parse_arguments(argv)
    report = validate_xcframework(
        arguments.xcframework,
        arguments.deployment_targets,
        arguments.alignment_caps,
    )
    payload = json.dumps(report, allow_nan=False, indent=2, sort_keys=True) + "\n"
    if arguments.json:
        sys.stdout.write(payload)
    else:
        print_human_report(report, arguments.max_diagnostics)
        if arguments.json_output:
            try:
                arguments.json_output.parent.mkdir(parents=True, exist_ok=True)
                arguments.json_output.write_text(payload, encoding="utf-8")
            except OSError as error:
                print(f"error: cannot write JSON report: {error}", file=sys.stderr)
                return 2
    return 0 if report["status"] == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
