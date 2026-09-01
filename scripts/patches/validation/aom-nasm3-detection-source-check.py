#!/usr/bin/env python3
"""Fail-closed source and behavior proof for VLC patch 0039."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Mapping

PATHS = {
    "checksums": "contrib/src/aom/SHA512SUMS",
    "rules": "contrib/src/aom/rules.mak",
}
PATCH_PATHS = tuple(PATHS.values())

AOM_VERSION = "3.13.2"
AOM_ARCHIVE = f"libaom-{AOM_VERSION}.tar.gz"
AOM_URL_ASSIGNMENT = (
    "AOM_URL := https://storage.googleapis.com/aom-releases/"
    "libaom-$(AOM_VERSION).tar.gz"
)
AOM_SHA512 = (
    "444f7abebcb568e13377d84b66e24cb61d3e81f6142b5763d8e65784a5da7682"
    "1a1753827024e2c6bfdc09f737a3fe1c1805bbaff5108a15ca1400298c434ee4"
)
EXPECTED_PATCH_SHA256 = (
    "f78050944caf0c291cac76e28cc4238b3e407d104446e2876c6e0213923d3581"
)
EXPECTED_PROBE_SHA256 = (
    "f3ed2ded2df243ca5d635c6b2a30d298e2ee39a04e4a64c4aabf7a11036ccc3b"
)


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def require_count(source: str, token: str, count: int, description: str) -> None:
    actual = source.count(token)
    if actual != count:
        raise AssertionError(
            f"{description} count is {actual}, expected exactly {count}"
        )


def validate_sources(sources: Mapping[str, str]) -> None:
    if set(sources) != set(PATHS):
        raise AssertionError("0039 source inventory is not exact")

    rules = sources["rules"]
    version_lines = re.findall(r"^AOM_VERSION\s*:=.*$", rules, re.MULTILINE)
    if version_lines != [f"AOM_VERSION := {AOM_VERSION}"]:
        raise AssertionError(
            f"VLC does not select exact libaom {AOM_VERSION}: {version_lines!r}"
        )
    url_lines = re.findall(r"^AOM_URL\s*:=.*$", rules, re.MULTILINE)
    if url_lines != [AOM_URL_ASSIGNMENT]:
        raise AssertionError(
            "VLC does not select the single audited libaom release URL: "
            f"{url_lines!r}"
        )

    checksum_lines = [
        line for line in sources["checksums"].splitlines() if line.strip()
    ]
    expected_checksum = f"{AOM_SHA512}  {AOM_ARCHIVE}"
    if checksum_lines != [expected_checksum]:
        raise AssertionError(
            "libaom checksum inventory is not the single audited 3.13.2 archive: "
            f"{checksum_lines!r}"
        )

    combined = "\n".join(sources.values())
    for obsolete in ("AOM_VERSION := 3.13.1", "libaom-3.13.1.tar.gz"):
        if obsolete in combined:
            raise AssertionError(f"obsolete libaom input remains active: {obsolete}")


def patch_sections(patch: str) -> dict[str, str]:
    matches = list(re.finditer(r"^diff --git a/(.+) b/(.+)$", patch, re.MULTILINE))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        old_path, new_path = match.groups()
        if old_path != new_path:
            raise AssertionError("0039 cannot rename a VLC path")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(patch)
        if old_path in sections:
            raise AssertionError(f"0039 repeats patch path {old_path}")
        sections[old_path] = patch[match.start() : end]
    return sections


def validate_patch(patch: str) -> None:
    sections = patch_sections(patch)
    if tuple(sections) != PATCH_PATHS:
        raise AssertionError(
            f"0039 patch path inventory changed: expected {PATCH_PATHS!r}, "
            f"got {tuple(sections)!r}"
        )
    if "GIT binary patch" in patch:
        raise AssertionError("0039 unexpectedly contains a binary patch")
    if "new file mode" in patch or "deleted file mode" in patch:
        raise AssertionError("0039 must only update the two upstream recipe files")
    actual_hash = sha256_bytes(patch.encode("utf-8"))
    if actual_hash != EXPECTED_PATCH_SHA256:
        raise AssertionError(
            f"0039 patch changed: expected {EXPECTED_PATCH_SHA256}, got {actual_hash}"
        )


def validate_probe(probe: str) -> None:
    actual_hash = sha256_bytes(probe.encode("utf-8"))
    if actual_hash != EXPECTED_PROBE_SHA256:
        raise AssertionError(
            "libaom NASM 3 behavior probe changed: "
            f"expected {EXPECTED_PROBE_SHA256}, got {actual_hash}"
        )
    require_count(
        probe,
        "execute_process(COMMAND ${CMAKE_ASM_NASM_COMPILER} -hO",
        1,
        "separate NASM optimization help probe",
    )
    require_count(
        probe,
        "execute_process(COMMAND ${CMAKE_ASM_NASM_COMPILER} -hf",
        1,
        "separate NASM object-format help probe",
    )


def replace_once(source: str, old: str, new: str, description: str) -> str:
    if source.count(old) != 1:
        raise AssertionError(f"checker mutation fixture is ambiguous: {description}")
    return source.replace(old, new, 1)


def expect_sources_rejected(
    sources: Mapping[str, str], key: str, old: str, new: str
) -> None:
    mutated = dict(sources)
    mutated[key] = replace_once(mutated[key], old, new, f"{key}: {old!r}")
    try:
        validate_sources(mutated)
    except AssertionError:
        return
    raise AssertionError(f"source mutation survived validation: {key}: {old!r}")


def validate_mutations(sources: Mapping[str, str], patch: str, probe: str) -> int:
    source_mutations = (
        ("rules", "AOM_VERSION := 3.13.2", "AOM_VERSION := 3.13.1"),
        (
            "rules",
            "https://storage.googleapis.com/aom-releases/",
            "https://example.invalid/aom-releases/",
        ),
        (
            "rules",
            AOM_URL_ASSIGNMENT,
            AOM_URL_ASSIGNMENT
            + "\nAOM_URL := https://example.invalid/libaom-$(AOM_VERSION).tar.gz",
        ),
        ("checksums", AOM_SHA512, "0" + AOM_SHA512[1:]),
        ("checksums", AOM_ARCHIVE, "libaom-3.13.1.tar.gz"),
    )
    for key, old, new in source_mutations:
        expect_sources_rejected(sources, key, old, new)

    patch_mutations = (
        replace_once(
            patch,
            "+AOM_VERSION := 3.13.2",
            "+AOM_VERSION := 3.13.3",
            "0039 AOM version",
        ),
        patch + "\ndiff --git a/README b/README\n",
    )
    for mutated_patch in patch_mutations:
        try:
            validate_patch(mutated_patch)
        except AssertionError:
            continue
        raise AssertionError("0039 patch mutation survived validation")

    mutated_probe = replace_once(
        probe,
        "${CMAKE_ASM_NASM_COMPILER} -hO",
        "${CMAKE_ASM_NASM_COMPILER} -hf",
        "NASM optimization topic",
    )
    try:
        validate_probe(mutated_probe)
    except AssertionError:
        pass
    else:
        raise AssertionError("NASM probe mutation survived validation")

    return len(source_mutations) + len(patch_mutations) + 1


def write_fake_nasm(path: Path) -> None:
    path.write_text(
        f"#!{sys.executable}\n"
        "import json\n"
        "import os\n"
        "from pathlib import Path\n"
        "import sys\n"
        "record = Path(os.environ['SWIFTVLC_FAKE_NASM_RECORD'])\n"
        "with record.open('a', encoding='utf-8') as stream:\n"
        "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n"
        "mode = os.environ.get('SWIFTVLC_FAKE_NASM_MODE', 'working')\n"
        "if sys.argv[1:] == ['-hO']:\n"
        "    if mode == 'missing-optimization':\n"
        "        print('    -O0       no optimization')\n"
        "    else:\n"
        "        print('    -Ox       multipass optimization')\n"
        "elif sys.argv[1:] == ['-hf']:\n"
        "    if mode == 'missing-format':\n"
        "        print('       elf64')\n"
        "    else:\n"
        "        print('       macho64')\n"
        "else:\n"
        "    raise SystemExit(89)\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def validate_behavior(probe_path: Path, work_root: Path | None) -> int:
    cmake = shutil.which("cmake")
    if cmake is None:
        raise AssertionError("cmake is required for the libaom NASM 3 behavior proof")

    with tempfile.TemporaryDirectory(
        prefix="swiftvlc-aom-nasm3-", dir=work_root
    ) as temporary:
        temporary_path = Path(temporary)
        fake_nasm = temporary_path / "nasm"
        record = temporary_path / "nasm-arguments.jsonl"
        legacy_probe = temporary_path / "legacy-aom-3.13.1.cmake"
        write_fake_nasm(fake_nasm)
        legacy_probe.write_text(
            replace_once(
                probe_path.read_text(encoding="utf-8"),
                "${CMAKE_ASM_NASM_COMPILER} -hO",
                "${CMAKE_ASM_NASM_COMPILER} -hf",
                "legacy one-topic AOM probe",
            ),
            encoding="utf-8",
        )

        cases = (
            (
                "working-nasm3",
                probe_path,
                "working",
                True,
                "",
                [["-hO"], ["-hf"]],
            ),
            (
                "missing-optimization",
                probe_path,
                "missing-optimization",
                False,
                "multipass optimization not supported",
                [["-hO"]],
            ),
            (
                "missing-format",
                probe_path,
                "missing-format",
                False,
                "macho64 object format not supported",
                [["-hO"], ["-hf"]],
            ),
            (
                "legacy-aom-3.13.1",
                legacy_probe,
                "working",
                False,
                "multipass optimization not supported",
                [["-hf"]],
            ),
        )

        for (
            name,
            selected_probe,
            mode,
            expected_success,
            expected_message,
            expected_arguments,
        ) in cases:
            record.unlink(missing_ok=True)
            environment = os.environ.copy()
            environment.update(
                {
                    "SWIFTVLC_FAKE_NASM_MODE": mode,
                    "SWIFTVLC_FAKE_NASM_RECORD": str(record),
                }
            )
            result = subprocess.run(
                [
                    cmake,
                    f"-DCMAKE_ASM_NASM_COMPILER={fake_nasm}",
                    "-DAOM_TARGET_CPU=x86_64",
                    "-DAOM_TARGET_SYSTEM=Darwin",
                    "-P",
                    str(selected_probe),
                ],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
                timeout=15,
            )
            succeeded = result.returncode == 0
            if succeeded != bool(expected_success):
                raise AssertionError(
                    f"behavior case {name!r} exited {result.returncode}: "
                    f"stdout={result.stdout!r}; stderr={result.stderr!r}"
                )
            output = result.stdout + result.stderr
            if expected_message and expected_message not in output:
                raise AssertionError(
                    f"behavior case {name!r} lacked {expected_message!r}: {output!r}"
                )
            if not record.is_file():
                raise AssertionError(f"behavior case {name!r} did not invoke NASM")
            arguments = [
                json.loads(line)
                for line in record.read_text(encoding="utf-8").splitlines()
            ]
            if arguments != expected_arguments:
                raise AssertionError(
                    f"behavior case {name!r} used {arguments!r}, "
                    f"expected {expected_arguments!r}"
                )

    return len(cases)


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("patch", type=Path)
    parser.add_argument("probe", type=Path)
    parser.add_argument("--work-root", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    source_root = arguments.source_root.resolve()
    patch_path = arguments.patch.resolve()
    probe_path = arguments.probe.resolve()
    if not source_root.is_dir():
        raise SystemExit(f"missing patched VLC source root: {source_root}")
    if not patch_path.is_file():
        raise SystemExit(f"missing 0039 patch: {patch_path}")
    if not probe_path.is_file():
        raise SystemExit(f"missing libaom NASM 3 probe: {probe_path}")
    if arguments.work_root is not None and not arguments.work_root.is_dir():
        raise SystemExit(f"work root is not a directory: {arguments.work_root}")

    source_paths = {key: source_root / value for key, value in PATHS.items()}
    missing = [str(path) for path in source_paths.values() if not path.is_file()]
    if missing:
        raise SystemExit("missing 0039 validation inputs: " + ", ".join(missing))

    sources = {
        key: path.read_text(encoding="utf-8") for key, path in source_paths.items()
    }
    patch = patch_path.read_text(encoding="utf-8")
    probe = probe_path.read_text(encoding="utf-8")
    validate_sources(sources)
    validate_patch(patch)
    validate_probe(probe)
    mutation_count = validate_mutations(sources, patch, probe)
    behavior_cases = validate_behavior(probe_path, arguments.work_root)

    print(
        "PASS libaom NASM 3 detection source proof: "
        f"paths={len(PATHS)} mutations={mutation_count} "
        f"behavior_cases={behavior_cases} patch_sha={EXPECTED_PATCH_SHA256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
