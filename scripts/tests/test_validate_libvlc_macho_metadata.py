#!/usr/bin/env python3

from __future__ import annotations

from contextlib import redirect_stderr, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import struct
import sys
import tempfile
import unittest

REPO_ROOT = Path(__file__).resolve().parents[2]
VALIDATOR_PATH = REPO_ROOT / "scripts" / "validate-libvlc-macho-metadata.py"
SPEC = importlib.util.spec_from_file_location("libvlc_macho_metadata", VALIDATOR_PATH)
assert SPEC is not None and SPEC.loader is not None
VALIDATOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = VALIDATOR
SPEC.loader.exec_module(VALIDATOR)


CPU = {
    "x86_64": VALIDATOR.CPU_TYPE_X86_64,
    "arm64": VALIDATOR.CPU_TYPE_ARM64,
}


def build_version_command(
    platform: int,
    minimum_os: str = "18.0",
    sdk: str | int = 0,
    *,
    endian: str = "<",
    tools: tuple[tuple[int, int], ...] = (),
) -> bytes:
    sdk_value = VALIDATOR.parse_version(sdk) if isinstance(sdk, str) else sdk
    size = 24 + len(tools) * 8
    command = struct.pack(
        endian + "IIIIII",
        VALIDATOR.LC_BUILD_VERSION,
        size,
        platform,
        VALIDATOR.parse_version(minimum_os),
        sdk_value,
        len(tools),
    )
    return command + b"".join(
        struct.pack(endian + "II", tool, version) for tool, version in tools
    )


def legacy_platform_command(command: int = 0x25, *, endian: str = "<") -> bytes:
    return struct.pack(
        endian + "IIII",
        command,
        16,
        VALIDATOR.parse_version("18.0"),
        0,
    )


def segment_command(
    alignment: int,
    *,
    endian: str = "<",
    segment_file_offset: int = 0,
    segment_file_size: int = 0,
    section_size: int = 0,
    section_offset: int = 0,
    section_flags: int = 0,
    relocation_offset: int = 0,
    relocation_count: int = 0,
) -> bytes:
    section = struct.pack(
        endian + "16s16sQQIIIIIIII",
        b"__text",
        b"__TEXT",
        0,
        section_size,
        section_offset,
        alignment,
        relocation_offset,
        relocation_count,
        section_flags,
        0,
        0,
        0,
    )
    command_size = 72 + len(section)
    segment = struct.pack(
        endian + "II16sQQQQiiII",
        VALIDATOR.LC_SEGMENT_64,
        command_size,
        b"",
        0,
        0,
        segment_file_offset,
        segment_file_size,
        7,
        7,
        1,
        0,
    )
    return segment + section


def macho_object(
    architecture: str,
    commands: tuple[bytes, ...],
    *,
    endian: str = "<",
    command_count: int | None = None,
    commands_size: int | None = None,
    trailing: bytes = b"",
) -> bytes:
    command_blob = b"".join(commands)
    header = struct.pack(
        endian + "IIIIIIII",
        VALIDATOR.MH_MAGIC_64,
        CPU[architecture],
        0,
        VALIDATOR.MH_OBJECT,
        len(commands) if command_count is None else command_count,
        len(command_blob) if commands_size is None else commands_size,
        0,
        0,
    )
    return header + command_blob + trailing


def archive_header(name: str, size: int) -> bytes:
    def field(value: str, width: int) -> bytes:
        encoded = value.encode("ascii")
        if len(encoded) > width:
            raise ValueError(f"archive field {value!r} exceeds {width} bytes")
        return encoded.ljust(width, b" ")

    header = b"".join(
        (
            field(name, 16),
            field("0", 12),
            field("0", 6),
            field("0", 6),
            field("100644", 8),
            field(str(size), 10),
            b"`\n",
        )
    )
    assert len(header) == VALIDATOR.AR_HEADER_SIZE
    return header


def raw_archive_member(name_field: str, payload: bytes) -> bytes:
    result = archive_header(name_field, len(payload)) + payload
    return result + (b"\n" if len(payload) & 1 else b"")


def short_archive_member(name: str, payload: bytes) -> bytes:
    return raw_archive_member(name + "/", payload)


def bsd_archive_member(name: str, payload: bytes) -> bytes:
    raw_name = name.encode("utf-8")
    storage_size = (len(raw_name) + 3) & ~3
    name_storage = raw_name + b"\0" * (storage_size - len(raw_name))
    return raw_archive_member(f"#1/{storage_size}", name_storage + payload)


def archive(*members: bytes) -> bytes:
    return VALIDATOR.AR_MAGIC + b"".join(members)


def align_up(value: int, alignment: int) -> int:
    return (value + alignment - 1) & ~(alignment - 1)


def universal_binary(
    slices: tuple[tuple[str, bytes], ...],
    *,
    is_64_bit: bool = False,
    endian: str = ">",
    alignment_exponent: int = 3,
) -> bytes:
    record_format = endian + ("IIQQII" if is_64_bit else "IIIII")
    record_size = struct.calcsize(record_format)
    header_size = 8 + len(slices) * record_size
    offset = header_size
    records: list[tuple[int, ...]] = []
    placements: list[tuple[int, bytes]] = []

    for architecture, payload in slices:
        offset = align_up(offset, 1 << alignment_exponent)
        if is_64_bit:
            records.append(
                (
                    CPU[architecture],
                    0,
                    offset,
                    len(payload),
                    alignment_exponent,
                    0,
                )
            )
        else:
            records.append(
                (
                    CPU[architecture],
                    0,
                    offset,
                    len(payload),
                    alignment_exponent,
                )
            )
        placements.append((offset, payload))
        offset += len(payload)

    magic = VALIDATOR.FAT_MAGIC_64 if is_64_bit else VALIDATOR.FAT_MAGIC
    result = bytearray(offset)
    struct.pack_into(endian + "II", result, 0, magic, len(slices))
    for index, record in enumerate(records):
        struct.pack_into(record_format, result, 8 + index * record_size, *record)
    for payload_offset, payload in placements:
        result[payload_offset : payload_offset + len(payload)] = payload
    return bytes(result)


def valid_object(
    architecture: str,
    platform: int,
    *,
    minimum_os: str = "18.0",
    sdk: str | int = 0,
    alignment: int | None = None,
    endian: str = "<",
) -> bytes:
    if alignment is None:
        alignment = 12 if architecture == "x86_64" else 14
    return macho_object(
        architecture,
        (
            segment_command(alignment, endian=endian),
            build_version_command(
                platform, minimum_os, sdk, endian=endian, tools=((3, 0x010000),)
            ),
        ),
        endian=endian,
    )


class FixtureXCFramework:
    def __init__(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name) / "libvlc.xcframework"
        self.root.mkdir()
        self.entries: list[dict[str, object]] = []

    def close(self) -> None:
        self.temporary.cleanup()

    def add_slice(
        self,
        identifier: str,
        payload: bytes,
        architectures: list[str],
        *,
        platform: str = "ios",
        variant: str | None = None,
        library_path: str = "libvlc.a",
    ) -> None:
        directory = self.root / identifier
        directory.mkdir(parents=True, exist_ok=True)
        (directory / library_path).write_bytes(payload)
        entry: dict[str, object] = {
            "LibraryIdentifier": identifier,
            "LibraryPath": library_path,
            "SupportedArchitectures": architectures,
            "SupportedPlatform": platform,
        }
        if variant is not None:
            entry["SupportedPlatformVariant"] = variant
        self.entries.append(entry)

    def finish(self) -> Path:
        (self.root / "Info.plist").write_bytes(
            plistlib.dumps({"AvailableLibraries": self.entries}, sort_keys=True)
        )
        return self.root


class LibVLCMachOMetadataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.fixture = FixtureXCFramework()

    def tearDown(self) -> None:
        self.fixture.close()

    def validate(
        self,
        *,
        targets: dict[str, str] | None = None,
        caps: dict[str, int] | None = None,
    ) -> dict[str, object]:
        return VALIDATOR.validate_xcframework(
            self.fixture.finish(), targets or {"ios": "18.0"}, caps
        )

    @staticmethod
    def violation_codes(report: dict[str, object]) -> list[str]:
        return [item["code"] for item in report["violations"]]

    def assert_format_error(self, code: str, operation) -> None:
        with self.assertRaises(VALIDATOR.BinaryFormatError) as raised:
            operation()
        self.assertEqual(raised.exception.code, code)

    def test_valid_thin_bsd_archive_accepts_zero_and_older_sdk(self) -> None:
        payload = archive(
            bsd_archive_member("__.SYMDEF", b"index"),
            bsd_archive_member("zero-sdk.o", valid_object("arm64", 2, sdk=0)),
            bsd_archive_member("old-sdk.o", valid_object("arm64", 2, sdk="13.0")),
        )
        self.fixture.add_slice("ios-arm64", payload, ["arm64"])

        report = self.validate()

        self.assertEqual(report["status"], "pass")
        self.assertEqual(report["summary"]["object_count"], 2)
        architecture = report["slices"][0]["architectures"][0]
        self.assertEqual(architecture["archive_member_count"], 3)
        self.assertEqual(architecture["special_member_count"], 1)
        self.assertEqual(
            architecture["observed_build_versions"],
            {
                "platform_ids": {"2": 2},
                "minimum_os_versions": {"18.0": 2},
                "sdk_versions": {"13.0": 1, "n/a": 1},
            },
        )

    def test_big_endian_mach_object_is_parsed_directly(self) -> None:
        payload = archive(
            short_archive_member("big-endian.o", valid_object("arm64", 2, endian=">"))
        )
        self.fixture.add_slice("ios-arm64", payload, ["arm64"])

        report = self.validate()

        self.assertEqual(report["status"], "pass", report)

    def test_fat32_and_fat64_support_native_and_swapped_endianness(self) -> None:
        for is_64_bit in (False, True):
            for endian in (">", "<"):
                with self.subTest(is_64_bit=is_64_bit, endian=endian):
                    fixture = FixtureXCFramework()
                    try:
                        x86_archive = archive(
                            short_archive_member("same.o", valid_object("x86_64", 7))
                        )
                        arm_archive = archive(
                            short_archive_member("same.o", valid_object("arm64", 7))
                        )
                        payload = universal_binary(
                            (("x86_64", x86_archive), ("arm64", arm_archive)),
                            is_64_bit=is_64_bit,
                            endian=endian,
                        )
                        fixture.add_slice(
                            "ios-arm64_x86_64-simulator",
                            payload,
                            ["arm64", "x86_64"],
                            variant="simulator",
                        )

                        report = VALIDATOR.validate_xcframework(
                            fixture.finish(), {"ios": "18.0"}
                        )
                    finally:
                        fixture.close()

                    self.assertEqual(report["status"], "pass", report)
                    self.assertEqual(report["summary"]["architecture_count"], 2)
                    self.assertEqual(report["summary"]["object_count"], 2)

    def test_gnu_long_archive_names_are_resolved(self) -> None:
        name_table = b"this-is-a-long-object-name.o/\n"
        payload = archive(
            raw_archive_member("//", name_table),
            raw_archive_member("/0", valid_object("arm64", 2)),
        )
        self.fixture.add_slice("ios-arm64", payload, ["arm64"])

        report = self.validate()

        self.assertEqual(report["status"], "pass", report)
        self.assertEqual(report["summary"]["object_count"], 1)

    def test_duplicate_member_names_retain_distinct_archive_ordinals(self) -> None:
        missing = macho_object("arm64", (segment_command(4),))
        payload = archive(
            bsd_archive_member("__.SYMDEF", b"index"),
            bsd_archive_member("duplicate.o", missing),
            bsd_archive_member("duplicate.o", missing),
        )
        self.fixture.add_slice("ios-arm64", payload, ["arm64"])

        report = self.validate()
        missing_violations = [
            item
            for item in report["violations"]
            if item["code"] == "missing_build_version"
        ]

        self.assertEqual(len(missing_violations), 2)
        self.assertEqual(
            {item["member"] for item in missing_violations}, {"duplicate.o"}
        )
        self.assertEqual(
            [item["member_ordinal"] for item in missing_violations], [2, 3]
        )

    def test_build_version_count_platform_minimum_and_legacy_are_exact(self) -> None:
        objects = (
            ("missing.o", macho_object("arm64", (segment_command(4),))),
            (
                "duplicate.o",
                macho_object(
                    "arm64",
                    (
                        build_version_command(2),
                        build_version_command(2),
                    ),
                ),
            ),
            (
                "legacy-only.o",
                macho_object("arm64", (legacy_platform_command(),)),
            ),
            ("wrong-platform.o", valid_object("arm64", 7)),
            (
                "lower-minimum.o",
                valid_object("arm64", 2, minimum_os="17.0"),
            ),
            (
                "higher-minimum.o",
                valid_object("arm64", 2, minimum_os="19.0"),
            ),
        )
        payload = archive(*(bsd_archive_member(name, obj) for name, obj in objects))
        self.fixture.add_slice("ios-arm64", payload, ["arm64"])

        report = self.validate()
        counts = report["summary"]["violation_counts"]

        self.assertEqual(counts["missing_build_version"], 2)
        self.assertEqual(counts["multiple_build_versions"], 1)
        self.assertEqual(counts["legacy_platform_command"], 1)
        self.assertEqual(counts["wrong_platform"], 1)
        self.assertEqual(counts["wrong_minimum_os"], 2)

    def test_section_alignment_caps_are_architecture_specific(self) -> None:
        x86_archive = archive(
            short_archive_member("at-cap.o", valid_object("x86_64", 7, alignment=12)),
            short_archive_member("over-cap.o", valid_object("x86_64", 7, alignment=13)),
        )
        arm_archive = archive(
            short_archive_member("at-cap.o", valid_object("arm64", 7, alignment=14)),
            short_archive_member("over-cap.o", valid_object("arm64", 7, alignment=15)),
        )
        payload = universal_binary((("x86_64", x86_archive), ("arm64", arm_archive)))
        self.fixture.add_slice(
            "ios-arm64_x86_64-simulator",
            payload,
            ["arm64", "x86_64"],
            variant="simulator",
        )

        report = self.validate()
        alignment_violations = [
            item
            for item in report["violations"]
            if item["code"] == "section_alignment_exceeds_cap"
        ]

        self.assertEqual(len(alignment_violations), 2)
        self.assertEqual(
            {item["architecture"] for item in alignment_violations},
            {"arm64", "x86_64"},
        )

    def test_object_cpu_must_match_fat_slice_cpu(self) -> None:
        wrong_archive = archive(
            short_archive_member("wrong.o", valid_object("arm64", 7))
        )
        payload = universal_binary((("x86_64", wrong_archive),))
        self.fixture.add_slice(
            "ios-x86_64-simulator",
            payload,
            ["x86_64"],
            variant="simulator",
        )

        report = self.validate()

        self.assertIn("cpu_mismatch", self.violation_codes(report))

    def test_info_architectures_must_match_universal_slices(self) -> None:
        x86_archive = archive(
            short_archive_member("valid.o", valid_object("x86_64", 7))
        )
        payload = universal_binary((("x86_64", x86_archive),))
        self.fixture.add_slice(
            "ios-arm64-simulator",
            payload,
            ["arm64"],
            variant="simulator",
        )

        report = self.validate()

        self.assertIn("architecture_set_mismatch", self.violation_codes(report))

    def test_universal_container_rejects_overlap_bounds_alignment_and_unknown_cpu(
        self,
    ) -> None:
        first = archive(short_archive_member("a.o", valid_object("x86_64", 7)))
        second = archive(short_archive_member("b.o", valid_object("arm64", 7)))
        valid = bytearray(universal_binary((("x86_64", first), ("arm64", second))))
        record_size = struct.calcsize(">IIIII")
        first_offset = struct.unpack_from(">I", valid, 8 + 8)[0]

        overlapping = bytearray(valid)
        struct.pack_into(">I", overlapping, 8 + record_size + 8, first_offset)
        self.assert_format_error(
            "overlapping_universal_slices",
            lambda: VALIDATOR.parse_container_slices(bytes(overlapping)),
        )

        out_of_bounds = bytearray(valid)
        struct.pack_into(">I", out_of_bounds, 8 + 12, len(valid) + 1)
        self.assert_format_error(
            "out_of_bounds",
            lambda: VALIDATOR.parse_container_slices(bytes(out_of_bounds)),
        )

        misaligned = bytearray(valid)
        struct.pack_into(">I", misaligned, 8 + 8, first_offset + 1)
        self.assert_format_error(
            "misaligned_universal_slice",
            lambda: VALIDATOR.parse_container_slices(bytes(misaligned)),
        )

        unknown_cpu = bytearray(valid)
        struct.pack_into(">I", unknown_cpu, 8, 0x01000012)
        self.assert_format_error(
            "unsupported_cpu_type",
            lambda: VALIDATOR.parse_container_slices(bytes(unknown_cpu)),
        )

        overlaps_table = bytearray(valid)
        struct.pack_into(">I", overlaps_table, 8 + 8, 8)
        self.assert_format_error(
            "universal_slice_overlaps_header",
            lambda: VALIDATOR.parse_container_slices(bytes(overlaps_table)),
        )

        huge_count = struct.pack(">II", VALIDATOR.FAT_MAGIC, 0xFFFFFFFF)
        self.assert_format_error(
            "out_of_bounds",
            lambda: VALIDATOR.parse_container_slices(huge_count),
        )

        fat64 = bytearray(
            universal_binary((("x86_64", first),), is_64_bit=True, endian=">")
        )
        struct.pack_into(">I", fat64, 8 + 28, 1)
        self.assert_format_error(
            "nonzero_fat64_reserved",
            lambda: VALIDATOR.parse_container_slices(bytes(fat64)),
        )

    def test_archive_parser_rejects_thin_and_malformed_archives(self) -> None:
        self.assert_format_error(
            "gnu_thin_archive",
            lambda: VALIDATOR.parse_container_slices(VALIDATOR.THIN_AR_MAGIC),
        )

        valid = bytearray(archive(short_archive_member("a.o", b"abcd")))
        bad_trailer = bytearray(valid)
        bad_trailer[8 + 58 : 8 + 60] = b"xx"
        self.assert_format_error(
            "invalid_archive_header_trailer",
            lambda: VALIDATOR.parse_archive_members(
                bytes(bad_trailer), 0, len(bad_trailer)
            ),
        )

        bad_size = bytearray(valid)
        bad_size[8 + 48 : 8 + 58] = b"9999999999"
        self.assert_format_error(
            "out_of_bounds",
            lambda: VALIDATOR.parse_archive_members(bytes(bad_size), 0, len(bad_size)),
        )

        bad_bsd = archive(raw_archive_member("#1/99", b"short"))
        self.assert_format_error(
            "invalid_bsd_extended_name",
            lambda: VALIDATOR.parse_archive_members(bad_bsd, 0, len(bad_bsd)),
        )

        missing_gnu_table = archive(raw_archive_member("/0", b"payload"))
        self.assert_format_error(
            "missing_gnu_name_table",
            lambda: VALIDATOR.parse_archive_members(
                missing_gnu_table, 0, len(missing_gnu_table)
            ),
        )

    def test_nested_fat_nested_archive_and_non_mach_members_are_rejected(self) -> None:
        payloads = {
            "nested-fat.o": universal_binary(
                (("arm64", archive(short_archive_member("a.o", b"x"))),)
            ),
            "nested-archive.o": archive(short_archive_member("a.o", b"x")),
            "text.o": b"not a Mach-O object",
        }
        payload = archive(
            *(bsd_archive_member(name, value) for name, value in payloads.items())
        )
        self.fixture.add_slice("ios-arm64", payload, ["arm64"])

        report = self.validate()
        codes = self.violation_codes(report)

        self.assertIn("nested_fat_member", codes)
        self.assertIn("nested_archive_member", codes)
        self.assertIn("non_mach_object_member", codes)
        self.assertIn("archive_has_no_mach_objects", codes)

    def test_mach_parser_rejects_malformed_load_commands_and_ranges(self) -> None:
        invalid_command_size = macho_object(
            "arm64", (struct.pack("<II", VALIDATOR.LC_BUILD_VERSION, 4),)
        )
        self.assert_format_error(
            "invalid_load_command_size",
            lambda: VALIDATOR.parse_mach_object(
                invalid_command_size, 0, len(invalid_command_size)
            ),
        )

        mismatched_table = macho_object(
            "arm64",
            (build_version_command(2),),
            commands_size=len(build_version_command(2)) + 8,
            trailing=b"\0" * 8,
        )
        self.assert_format_error(
            "load_command_size_mismatch",
            lambda: VALIDATOR.parse_mach_object(
                mismatched_table, 0, len(mismatched_table)
            ),
        )

        invalid_build = bytearray(build_version_command(2))
        struct.pack_into("<I", invalid_build, 20, 1)
        invalid_build_object = macho_object("arm64", (bytes(invalid_build),))
        self.assert_format_error(
            "invalid_build_version_command",
            lambda: VALIDATOR.parse_mach_object(
                invalid_build_object, 0, len(invalid_build_object)
            ),
        )

        bad_section_range = macho_object(
            "arm64",
            (
                segment_command(4, section_size=16, section_offset=10_000),
                build_version_command(2),
            ),
        )
        self.assert_format_error(
            "out_of_bounds",
            lambda: VALIDATOR.parse_mach_object(
                bad_section_range, 0, len(bad_section_range)
            ),
        )

        bad_relocation_range = macho_object(
            "arm64",
            (
                segment_command(4, relocation_offset=10_000, relocation_count=1),
                build_version_command(2),
            ),
        )
        self.assert_format_error(
            "out_of_bounds",
            lambda: VALIDATOR.parse_mach_object(
                bad_relocation_range, 0, len(bad_relocation_range)
            ),
        )

        bad_segment_range = macho_object(
            "arm64",
            (
                segment_command(4, segment_file_offset=10_000, segment_file_size=1),
                build_version_command(2),
            ),
        )
        self.assert_format_error(
            "out_of_bounds",
            lambda: VALIDATOR.parse_mach_object(
                bad_segment_range, 0, len(bad_segment_range)
            ),
        )

        prefixed = b"prefix" + bad_section_range
        with self.assertRaises(VALIDATOR.BinaryFormatError) as raised:
            VALIDATOR.parse_mach_object(
                prefixed, len(b"prefix"), len(bad_section_range)
            )
        self.assertEqual(raised.exception.code, "out_of_bounds")
        self.assertEqual(raised.exception.offset, len(b"prefix") + 10_000)

    def test_archive_parse_errors_remain_scoped_to_the_fat_architecture(self) -> None:
        malformed_archive = VALIDATOR.AR_MAGIC + b"truncated"
        payload = universal_binary((("x86_64", malformed_archive),))
        self.fixture.add_slice(
            "ios-x86_64-simulator",
            payload,
            ["x86_64"],
            variant="simulator",
        )

        report = self.validate()
        violation = report["violations"][0]
        architecture = report["slices"][0]["architectures"][0]

        self.assertEqual(violation["code"], "out_of_bounds")
        self.assertEqual(violation["architecture"], "x86_64")
        self.assertEqual(architecture["violation_count"], 1)

    def test_malformed_plist_metadata_still_produces_serializable_json(self) -> None:
        self.fixture.entries.append(
            {
                "LibraryIdentifier": "invalid-metadata",
                "LibraryPath": b"not-a-string",
                "SupportedArchitectures": ["arm64"],
                "SupportedPlatform": "ios",
                "SupportedPlatformVariant": float("nan"),
            }
        )

        report = self.validate()
        encoded = json.dumps(report)
        decoded = json.loads(encoded)

        self.assertEqual(decoded["status"], "fail")
        self.assertEqual(decoded["slices"][0]["library"]["type"], "data")
        self.assertEqual(decoded["slices"][0]["supported_platform_variant"], "nan")
        self.assertIn("invalid_xcframework_entry", self.violation_codes(decoded))

    def test_json_stdout_and_json_file_reports_are_qualification_ready(self) -> None:
        payload = archive(short_archive_member("missing.o", macho_object("arm64", ())))
        self.fixture.add_slice("ios-arm64", payload, ["arm64"])
        root = self.fixture.finish()

        stdout = io.StringIO()
        stderr = io.StringIO()
        with redirect_stdout(stdout), redirect_stderr(stderr):
            result = VALIDATOR.main(
                [
                    "--xcframework",
                    str(root),
                    "--deployment-target",
                    "ios=18.0",
                    "--json",
                ]
            )
        report = json.loads(stdout.getvalue())

        self.assertEqual(result, 1)
        self.assertEqual(stderr.getvalue(), "")
        self.assertEqual(report["schema_version"], 1)
        self.assertEqual(report["status"], "fail")
        self.assertEqual(
            report["summary"]["violation_counts"]["missing_build_version"], 1
        )
        self.assertIn("slices", report)
        self.assertIn("violations", report)

        json_path = Path(self.fixture.temporary.name) / "report.json"
        with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            result = VALIDATOR.main(
                [
                    "--xcframework",
                    str(root),
                    "--deployment-target",
                    "ios=18.0",
                    "--json-output",
                    str(json_path),
                    "--max-diagnostics",
                    "1",
                ]
            )
        self.assertEqual(result, 1)
        self.assertEqual(json.loads(json_path.read_text())["status"], "fail")


if __name__ == "__main__":
    unittest.main()
