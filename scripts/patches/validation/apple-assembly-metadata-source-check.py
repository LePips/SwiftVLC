#!/usr/bin/env python3
"""Fail-closed source and executable proof for VLC patch 0038."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
from typing import Mapping

PATHS = {
    "gcrypt_patch": "contrib/src/gcrypt/rijndael-aesni-apple-alignment.patch",
    "gcrypt_rules": "contrib/src/gcrypt/rules.mak",
    "contrib_main": "contrib/src/main.mak",
    "apple_build": "extras/package/apple/build.sh",
    "nasm_wrapper": "extras/package/apple/nasm-wrapper.sh",
    "tool_sums": "extras/tools/SHA512SUMS",
    "tool_bootstrap": "extras/tools/bootstrap",
    "tool_packages": "extras/tools/packages.mak",
}

PATCH_PATHS = (
    PATHS["gcrypt_patch"],
    PATHS["gcrypt_rules"],
    PATHS["contrib_main"],
    PATHS["apple_build"],
    PATHS["nasm_wrapper"],
    PATHS["tool_sums"],
    PATHS["tool_bootstrap"],
    PATHS["tool_packages"],
)

EXPECTED_PATCH_SHA256 = (
    "5f1a58d162c798b2d6f5c2a2fdac9f728279f195ef192405b80272bc2f164c59"
)
EXPECTED_WRAPPER_SHA256 = (
    "531c0d99e01e0c6e04af9d28c6a04121264d240242ae9d5905f014243eb33282"
)
EXPECTED_GCRYPT_PATCH_SHA256 = (
    "8a080d7dc5cc9cc6dc5d05c327bd7521a7b3f0bdf901574b2f7162734761a216"
)
EXPECTED_METADATA_FUNCTION_SHA256 = (
    "28432fc6e27bdd6cee4e5ae1ba584caf656f8628d19eda635fc81b2d64adb621"
)
EXPECTED_INSTALL_FUNCTION_SHA256 = (
    "cebba7072fcc9748e2ec8c437c9e1dfe842ecab4192bf22013503ce663cbf74c"
)
EXPECTED_NASM_SHA512 = (
    "2971e17bad24127149c53fec5b7f28b32811d19c3f4b3fe9fff7f44df9e6c78f"
    "0a7dc3b30cb2257317ce8faa96c6063dad785250104c670ed7bb14651c1c8437"
)

MESON_ENVIRONMENT_ASSIGNMENT = (
    'MESON = env -i PATH="$(PATH)" \\\n'
    '\tVLC_APPLE_NASM_REAL="$(VLC_APPLE_NASM_REAL)" \\\n'
    '\tVLC_APPLE_NASM_PLATFORM="$(VLC_APPLE_NASM_PLATFORM)" \\\n'
    '\tVLC_APPLE_NASM_MIN_OS_VERSION="$(VLC_APPLE_NASM_MIN_OS_VERSION)" \\\n'
    '\tVLC_APPLE_NASM_SDK_VERSION="$(VLC_APPLE_NASM_SDK_VERSION)" \\\n'
    '\tmeson setup -Dpkg_config_path="$(PKG_CONFIG_PATH)" \\\n'
    '\t$(MESONFLAGS)'
)

MESON_BUILD_ASSIGNMENT = (
    "MESONBUILD = meson compile -C $(BUILD_DIR) $(MESON_BUILD) "
    "$(MESONCOMPILEFLAGS) && meson install -C $(BUILD_DIR)"
)

MESON_FORWARDED_NASM_VARIABLES = (
    "VLC_APPLE_NASM_REAL",
    "VLC_APPLE_NASM_PLATFORM",
    "VLC_APPLE_NASM_MIN_OS_VERSION",
    "VLC_APPLE_NASM_SDK_VERSION",
)

PLATFORMS = {
    "macos": 1,
    "ios": 2,
    "tvos": 3,
    "macCatalyst": 6,
    "iossimulator": 7,
    "tvossimulator": 8,
    "xros": 11,
    "xrsimulator": 12,
}


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def require_count(source: str, token: str, count: int, description: str) -> None:
    actual = source.count(token)
    if actual != count:
        raise AssertionError(
            f"{description} count is {actual}, expected exactly {count}"
        )


def ordered(source: str, *tokens: str) -> None:
    position = -1
    for token in tokens:
        next_position = source.find(token, position + 1)
        if next_position < 0:
            raise AssertionError(f"missing ordered source token {token!r}")
        position = next_position


def shell_function(source: str, name: str) -> str:
    opening = re.search(rf"^{re.escape(name)}\(\)\n\{{\n", source, re.MULTILINE)
    if opening is None:
        raise AssertionError(f"missing shell function {name}")
    if re.search(
        rf"^{re.escape(name)}\(\)\n\{{\n",
        source[opening.end() :],
        re.MULTILINE,
    ):
        raise AssertionError(f"shell function {name} is ambiguous")
    closing = source.find("\n}\n", opening.end())
    if closing < 0:
        raise AssertionError(f"shell function {name} is unterminated")
    return source[opening.start() : closing + 3]


def normalized_shell_hash(source: str, name: str) -> str:
    body = shell_function(source, name)
    uncommented = "\n".join(
        line for line in body.splitlines() if not line.lstrip().startswith("#")
    )
    normalized = re.sub(r"\s+", "", uncommented)
    return sha256_bytes(normalized.encode("utf-8"))


def validate_tools(sources: Mapping[str, str]) -> None:
    packages = sources["tool_packages"]
    version_lines = re.findall(r"^NASM_VERSION=.*$", packages, re.MULTILINE)
    if version_lines != ["NASM_VERSION=3.02"]:
        raise AssertionError(
            f"bundled NASM version is not exactly 3.02: {version_lines}"
        )
    require_count(
        packages,
        "NASM_URL=https://www.nasm.us/pub/nasm/releasebuilds/$(NASM_VERSION)/nasm-$(NASM_VERSION).tar.gz",
        1,
        "official NASM source URL",
    )

    checksum_line = f"{EXPECTED_NASM_SHA512}  nasm-3.02.tar.gz"
    sums = sources["tool_sums"]
    require_count(sums, checksum_line, 1, "audited NASM 3.02 SHA-512")
    if "nasm-2.14.tar.gz" in sums:
        raise AssertionError("obsolete NASM 2.14 checksum remains active")

    bootstrap = sources["tool_bootstrap"]
    minimum_lines = re.findall(r"^MIN_NASM=.*$", bootstrap, re.MULTILINE)
    if minimum_lines != ["MIN_NASM=3.02"]:
        raise AssertionError(
            f"NASM bootstrap minimum is not exactly 3.02: {minimum_lines}"
        )
    require_count(bootstrap, "check_nasm $MIN_NASM", 1, "NASM minimum probe")


def validate_contrib_meson_environment(source: str) -> None:
    require_count(
        source,
        MESON_ENVIRONMENT_ASSIGNMENT,
        1,
        "cross-Meson fail-closed Apple NASM environment forwarding",
    )
    for variable in MESON_FORWARDED_NASM_VARIABLES:
        require_count(
            MESON_ENVIRONMENT_ASSIGNMENT,
            f'{variable}="$({variable})"',
            1,
            f"cross-Meson forwarding for {variable}",
        )
    require_count(
        source,
        "# command, except PATH and the fail-closed Apple NASM wrapper inputs.",
        1,
        "cross-Meson environment policy",
    )
    require_count(
        source,
        MESON_BUILD_ASSIGNMENT,
        1,
        "cross-Meson compile/install environment inheritance",
    )


def validate_apple_build(source: str) -> None:
    metadata_hash = normalized_shell_hash(source, "configure_apple_nasm_metadata")
    if metadata_hash != EXPECTED_METADATA_FUNCTION_SHA256:
        raise AssertionError(
            "Apple platform-to-NASM metadata mapping changed: "
            f"expected {EXPECTED_METADATA_FUNCTION_SHA256}, got {metadata_hash}"
        )
    install_hash = normalized_shell_hash(source, "install_apple_nasm_wrapper")
    if install_hash != EXPECTED_INSTALL_FUNCTION_SHA256:
        raise AssertionError(
            "Apple NASM wrapper installation/precedence logic changed: "
            f"expected {EXPECTED_INSTALL_FUNCTION_SHA256}, got {install_hash}"
        )
    install_function = shell_function(source, "install_apple_nasm_wrapper")
    require_count(
        install_function,
        "real_nasm=$saved_tools_nasm",
        1,
        "pinned bundled NASM selection",
    )
    require_count(
        install_function,
        '"NASM version 3.02"|"NASM version 3.02 "*',
        1,
        "exact NASM 3.02 version gate",
    )
    require_count(
        install_function,
        "command -v nasm",
        1,
        "installed wrapper PATH precedence probe",
    )
    if re.search(r"real_nasm=.*command -v nasm", install_function):
        raise AssertionError("Apple wrapper installation falls back to host NASM")

    metadata_calls = list(
        re.finditer(r"^configure_apple_nasm_metadata$", source, re.MULTILINE)
    )
    install_calls = list(
        re.finditer(r"^install_apple_nasm_wrapper$", source, re.MULTILINE)
    )
    if len(metadata_calls) != 1 or len(install_calls) != 1:
        raise AssertionError(
            "Apple NASM setup functions must each be called exactly once"
        )

    readonly_install = source.find("readonly VLC_INSTALL_DIR=")
    build_configuration = source.find('echo "Build configuration"')
    if not (readonly_install < metadata_calls[0].start() < build_configuration):
        raise AssertionError(
            "metadata must be exported after final platform overrides and before build output"
        )
    catalyst_override = source.find('VLC_HOST_PLATFORM="macCatalyst"')
    if catalyst_override >= 0 and catalyst_override > metadata_calls[0].start():
        raise AssertionError("Mac Catalyst override occurs after NASM metadata mapping")

    tools_path = source.find('export PATH="$VLC_SRC_DIR/extras/tools/build/bin:$PATH"')
    tools_make = source.find('$MAKE || abort_err "Building tools failed"')
    pinned_nasm_make = source.find(
        '$MAKE .buildnasm || abort_err "Building pinned NASM 3.02 failed"'
    )
    require_count(
        source,
        '$MAKE .buildnasm || abort_err "Building pinned NASM 3.02 failed"',
        1,
        "forced pinned NASM tools target",
    )
    contrib_heading = source.find("#                     Contribs build")
    if not (
        0
        <= tools_path
        < tools_make
        < pinned_nasm_make
        < install_calls[0].start()
        < contrib_heading
    ):
        raise AssertionError(
            "pinned NASM is not forced and wrapped after tools PATH/build mutation "
            "and before contrib configuration"
        )


def validate_gcrypt(sources: Mapping[str, str]) -> None:
    patch = sources["gcrypt_patch"]
    actual_hash = sha256_bytes(patch.encode("utf-8"))
    if actual_hash != EXPECTED_GCRYPT_PATCH_SHA256:
        raise AssertionError(
            "nested libgcrypt alignment patch changed: "
            f"expected {EXPECTED_GCRYPT_PATCH_SHA256}, got {actual_hash}"
        )
    require_count(patch, "#ifdef __APPLE__", 1, "Apple alignment guard")
    require_count(patch, '".p2align 4\\n\\t"', 1, "Apple 16-byte alignment")
    require_count(patch, "#else", 1, "non-Apple alignment branch")
    require_count(patch, '".align 16\\n\\t"', 1, "non-Apple alignment")
    require_count(
        patch,
        "a/cipher/rijndael-aesni.c",
        1,
        "libgcrypt AESNI patch input",
    )
    require_count(
        patch,
        "b/cipher/rijndael-aesni.c",
        1,
        "libgcrypt AESNI patch output",
    )

    rules = sources["gcrypt_rules"]
    application = "$(APPLY) $(SRC)/gcrypt/rijndael-aesni-apple-alignment.patch"
    require_count(rules, application, 1, "libgcrypt alignment patch application")
    ordered(
        rules,
        "$(APPLY) $(SRC)/gcrypt/0008-random-only-use-wincrypt-in-UWP-builds-if-WINSTORECO.patch",
        application,
        "$(MOVE)",
    )


def validate_wrapper_source(source: str, wrapper_path: Path) -> None:
    actual_hash = sha256_bytes(source.encode("utf-8"))
    if actual_hash != EXPECTED_WRAPPER_SHA256:
        raise AssertionError(
            f"Apple NASM wrapper changed: expected {EXPECTED_WRAPPER_SHA256}, "
            f"got {actual_hash}"
        )
    if not os.access(wrapper_path, os.X_OK):
        raise AssertionError("Apple NASM wrapper is not executable")


def validate_sources(sources: Mapping[str, str], root: Path | None = None) -> None:
    if set(sources) != set(PATHS):
        raise AssertionError("0038 source inventory is not exact")
    validate_tools(sources)
    validate_contrib_meson_environment(sources["contrib_main"])
    validate_apple_build(sources["apple_build"])
    validate_gcrypt(sources)
    if root is not None:
        validate_wrapper_source(sources["nasm_wrapper"], root / PATHS["nasm_wrapper"])
    elif (
        sha256_bytes(sources["nasm_wrapper"].encode("utf-8")) != EXPECTED_WRAPPER_SHA256
    ):
        raise AssertionError("Apple NASM wrapper source changed")


def patch_sections(patch: str) -> dict[str, str]:
    matches = list(re.finditer(r"^diff --git a/(.+) b/(.+)$", patch, re.MULTILINE))
    sections: dict[str, str] = {}
    for index, match in enumerate(matches):
        old_path, new_path = match.groups()
        if old_path != new_path:
            raise AssertionError("0038 cannot rename a VLC path")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(patch)
        if old_path in sections:
            raise AssertionError(f"0038 repeats patch path {old_path}")
        sections[old_path] = patch[match.start() : end]
    return sections


def validate_patch(patch: str) -> None:
    sections = patch_sections(patch)
    if tuple(sections) != PATCH_PATHS:
        raise AssertionError(
            f"0038 patch path inventory changed: expected {PATCH_PATHS!r}, "
            f"got {tuple(sections)!r}"
        )
    if "new file mode 100755" not in sections[PATHS["nasm_wrapper"]]:
        raise AssertionError("0038 does not preserve executable wrapper mode")
    if "new file mode 100644" not in sections[PATHS["gcrypt_patch"]]:
        raise AssertionError("0038 nested libgcrypt patch mode changed")
    if "GIT binary patch" in patch:
        raise AssertionError("0038 unexpectedly contains a binary patch")
    actual_hash = sha256_bytes(patch.encode("utf-8"))
    if actual_hash != EXPECTED_PATCH_SHA256:
        raise AssertionError(
            f"0038 patch hash changed: expected {EXPECTED_PATCH_SHA256}, "
            f"got {actual_hash}"
        )


def replace_once(source: str, old: str, new: str, description: str) -> str:
    if source.count(old) != 1:
        raise AssertionError(f"checker mutation fixture is ambiguous: {description}")
    return source.replace(old, new, 1)


def expect_source_rejected(
    sources: Mapping[str, str], key: str, old: str, new: str
) -> None:
    mutated = dict(sources)
    mutated[key] = replace_once(mutated[key], old, new, f"{key}: {old!r}")
    try:
        validate_sources(mutated)
    except AssertionError:
        return
    raise AssertionError(f"source mutation survived validation: {key}: {old!r}")


def validate_mutations(sources: Mapping[str, str], patch: str) -> int:
    mutations = (
        ("tool_packages", "NASM_VERSION=3.02", "NASM_VERSION=3.01"),
        ("tool_sums", EXPECTED_NASM_SHA512, "0" + EXPECTED_NASM_SHA512[1:]),
        ("tool_bootstrap", "MIN_NASM=3.02", "MIN_NASM=2.14"),
    ) + tuple(
        (
            "contrib_main",
            f'\t{variable}="$({variable})" \\\n',
            "",
        )
        for variable in MESON_FORWARDED_NASM_VARIABLES
    ) + (
        (
            "contrib_main",
            'MESON = env -i PATH="$(PATH)"',
            'MESON = env PATH="$(PATH)"',
        ),
        (
            "contrib_main",
            "MESONBUILD = meson compile",
            'MESONBUILD = env -i PATH="$(PATH)" meson compile',
        ),
        (
            "apple_build",
            "macCatalyst) VLC_APPLE_NASM_PLATFORM=macCatalyst ;;",
            "macCatalyst) VLC_APPLE_NASM_PLATFORM=macos ;;",
        ),
        (
            "apple_build",
            'install_apple_nasm_wrapper\necho ""',
            'echo ""',
        ),
        (
            "apple_build",
            '$MAKE .buildnasm || abort_err "Building pinned NASM 3.02 failed"',
            '$MAKE .buildcmake || abort_err "Building pinned NASM 3.02 failed"',
        ),
        (
            "apple_build",
            '"NASM version 3.02"|"NASM version 3.02 "*',
            '"NASM version 3.03"|"NASM version 3.03 "*',
        ),
        (
            "apple_build",
            "real_nasm=$saved_tools_nasm",
            "real_nasm=$(command -v nasm)",
        ),
        (
            "gcrypt_rules",
            "\t$(APPLY) $(SRC)/gcrypt/rijndael-aesni-apple-alignment.patch\n",
            "",
        ),
        ("gcrypt_patch", '".p2align 4\\n\\t"', '".p2align 16\\n\\t"'),
        (
            "nasm_wrapper",
            "output_format=\nformat_argument_pending=0",
            "output_format=macho64\nformat_argument_pending=0",
        ),
    )
    for key, old, new in mutations:
        expect_source_rejected(sources, key, old, new)

    patch_mutations = (
        patch.replace("new file mode 100755", "new file mode 100644", 1),
        patch + "\ndiff --git a/README b/README\n",
    )
    for mutated_patch in patch_mutations:
        try:
            validate_patch(mutated_patch)
        except AssertionError:
            continue
        raise AssertionError("0038 patch mutation survived validation")
    return len(mutations) + len(patch_mutations)


def write_fake_nasm(path: Path) -> None:
    path.write_text(
        f"#!{sys.executable}\n"
        "import json\n"
        "import os\n"
        "from pathlib import Path\n"
        "import sys\n"
        "Path(os.environ['SWIFTVLC_FAKE_NASM_RECORD']).write_text(\n"
        "    json.dumps(sys.argv[1:]), encoding='utf-8'\n"
        ")\n",
        encoding="utf-8",
    )
    path.chmod(0o755)


def write_versioned_fake_nasm(path: Path, version_output: str, executable: bool) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        "#!/bin/sh\n"
        "[ \"${1-}\" = -v ] || exit 89\n"
        f"printf '%s\\n' {shlex.quote(version_output)}\n",
        encoding="utf-8",
    )
    path.chmod(0o755 if executable else 0o644)


def validate_install_runtime(
    apple_build_source: str,
    wrapper_source_path: Path,
    work_root: Path | None,
) -> int:
    install_function = shell_function(
        apple_build_source, "install_apple_nasm_wrapper"
    )
    cases = (
        (
            "exact-tools-with-suffix",
            "tools",
            "NASM version 3.02 compiled on Sep 1 2026",
            True,
            None,
            0,
            "",
        ),
        ("exact-tools-bare", "tools", "NASM version 3.02", True, None, 0, ""),
        (
            "exact-preserved",
            "preserved",
            "NASM version 3.02 compiled on Sep 1 2026",
            True,
            None,
            0,
            "",
        ),
        (
            "stale-tools",
            "tools",
            "NASM version 2.14 compiled on Jan 1 2018",
            True,
            None,
            91,
            "must report exactly version 3.02",
        ),
        (
            "newer-tools",
            "tools",
            "NASM version 3.03 compiled on Jan 1 2027",
            True,
            None,
            91,
            "must report exactly version 3.02",
        ),
        (
            "lookalike-version",
            "tools",
            "NASM version 3.020",
            True,
            None,
            91,
            "must report exactly version 3.02",
        ),
        (
            "missing-with-host",
            "missing",
            None,
            True,
            "NASM version 3.02",
            91,
            "Pinned bundled NASM is missing after .buildnasm",
        ),
        (
            "non-executable-tools",
            "tools",
            "NASM version 3.02",
            False,
            "NASM version 3.02",
            91,
            "Bundled NASM is not executable",
        ),
    )

    with tempfile.TemporaryDirectory(
        prefix="swiftvlc-apple-nasm-install-", dir=work_root
    ) as temporary:
        temporary_path = Path(temporary)
        for (
            name,
            bundled_location,
            bundled_version,
            bundled_executable,
            host_version,
            expected_exit,
            expected_error,
        ) in cases:
            case_root = temporary_path / name
            script_dir = case_root / "scripts"
            build_dir = case_root / "build"
            source_dir = case_root / "source"
            tools_dir = source_dir / "extras" / "tools" / "build" / "bin"
            host_dir = case_root / "host-bin"
            for directory in (script_dir, build_dir, tools_dir, host_dir):
                directory.mkdir(parents=True, exist_ok=True)

            wrapper_source = script_dir / "nasm-wrapper.sh"
            wrapper_source.write_bytes(wrapper_source_path.read_bytes())
            wrapper_source.chmod(0o755)

            tools_nasm = tools_dir / "nasm"
            saved_nasm = tools_dir / "nasm.swiftvlc-real"
            if bundled_location != "missing":
                target = tools_nasm if bundled_location == "tools" else saved_nasm
                assert bundled_version is not None
                write_versioned_fake_nasm(
                    target, bundled_version, bundled_executable
                )
            if host_version is not None:
                write_versioned_fake_nasm(host_dir / "nasm", host_version, True)

            environment = os.environ.copy()
            environment.update(
                {
                    "VLC_SCRIPT_DIR": str(script_dir),
                    "VLC_BUILD_DIR": str(build_dir),
                    "VLC_SRC_DIR": str(source_dir),
                    "PATH": f"{host_dir}:/usr/bin:/bin",
                }
            )
            harness = (
                "set -eu\n"
                "abort_err() { echo \"abort_err: $*\" >&2; exit 91; }\n"
                f"{install_function}\n"
                "install_apple_nasm_wrapper\n"
                "printf 'REAL=%s\\n' \"$VLC_APPLE_NASM_REAL\"\n"
            )
            result = subprocess.run(
                ["/bin/bash", "-c", harness],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )
            if result.returncode != expected_exit:
                raise AssertionError(
                    f"NASM install case {name!r} exited {result.returncode}, "
                    f"expected {expected_exit}; stderr={result.stderr!r}"
                )

            installed_wrapper = build_dir / "apple-nasm-wrapper" / "nasm"
            if expected_exit == 0:
                expected_real = f"REAL={saved_nasm}"
                if result.stdout.strip() != expected_real:
                    raise AssertionError(
                        f"NASM install case {name!r} selected the wrong binary: "
                        f"{result.stdout!r}"
                    )
                if not installed_wrapper.is_file() or not os.access(
                    installed_wrapper, os.X_OK
                ):
                    raise AssertionError(
                        f"NASM install case {name!r} did not install the wrapper"
                    )
                if installed_wrapper.read_bytes() != wrapper_source.read_bytes():
                    raise AssertionError(
                        f"NASM install case {name!r} changed the wrapper payload"
                    )
            else:
                if expected_error not in result.stderr:
                    raise AssertionError(
                        f"NASM install case {name!r} did not report "
                        f"{expected_error!r}: {result.stderr!r}"
                    )
                if installed_wrapper.exists():
                    raise AssertionError(
                        f"NASM install case {name!r} wrapped a rejected binary"
                    )

    return len(cases)


def validate_cross_meson_environment_runtime(
    contrib_main_source: str,
    work_root: Path | None,
) -> int:
    validate_contrib_meson_environment(contrib_main_source)
    with tempfile.TemporaryDirectory(
        prefix="swiftvlc-apple-meson-env-", dir=work_root
    ) as temporary:
        temporary_path = Path(temporary)
        fake_bin = temporary_path / "fake-bin"
        fake_bin.mkdir()
        record = temporary_path / "meson-environment.json"
        fake_meson = fake_bin / "meson"
        fake_meson.write_text(
            f"#!{sys.executable}\n"
            "import json\n"
            "import os\n"
            "from pathlib import Path\n"
            "import sys\n"
            f"with Path({str(record)!r}).open(\"a\", encoding=\"utf-8\") "
            "as stream:\n"
            "    stream.write(json.dumps({\"arguments\": sys.argv[1:], "
            "\"environment\": dict(os.environ)}) + \"\\n\")\n",
            encoding="utf-8",
        )
        fake_meson.chmod(0o755)

        expected_values = {
            "VLC_APPLE_NASM_REAL": str(temporary_path / "pinned-nasm"),
            "VLC_APPLE_NASM_PLATFORM": "iossimulator",
            "VLC_APPLE_NASM_MIN_OS_VERSION": "18.0",
            "VLC_APPLE_NASM_SDK_VERSION": "26.5",
        }
        makefile = temporary_path / "Makefile"
        makefile.write_text(
            f"PATH := {fake_bin}:/usr/bin:/bin\n"
            "PKG_CONFIG_PATH := /explicit/pkg-config\n"
            "MESONFLAGS := -Dswiftvlc_probe=true\n"
            "BUILD_DIR := probe-build\n"
            "MESON_BUILD :=\n"
            "MESONCOMPILEFLAGS :=\n"
            f"{MESON_ENVIRONMENT_ASSIGNMENT}\n"
            f"{MESON_BUILD_ASSIGNMENT}\n"
            ".PHONY: all\n"
            "all:\n"
            "\t@$(MESON)\n"
            "\t@$(MESONBUILD)\n",
            encoding="utf-8",
        )

        environment = os.environ.copy()
        environment.update(expected_values)
        scrubbed_values = {
            "HOME": "/poison/home",
            "CC": "/poison/cc",
            "CFLAGS": "-DPOISON",
            "NASMENV": "-f macho64",
        }
        environment.update(scrubbed_values)
        result = subprocess.run(
            ["make", "-f", str(makefile)],
            cwd=temporary_path,
            env=environment,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        if result.returncode != 0:
            raise AssertionError(
                "cross-Meson environment harness failed: "
                f"stdout={result.stdout!r}; stderr={result.stderr!r}"
            )
        if not record.is_file():
            raise AssertionError("cross-Meson environment did not invoke meson")
        payloads = [
            json.loads(line)
            for line in record.read_text(encoding="utf-8").splitlines()
        ]
        expected_arguments = [
            [
                "setup",
                "-Dpkg_config_path=/explicit/pkg-config",
                "-Dswiftvlc_probe=true",
            ],
            ["compile", "-C", "probe-build"],
            ["install", "-C", "probe-build"],
        ]
        if [payload["arguments"] for payload in payloads] != expected_arguments:
            raise AssertionError(
                "cross-Meson arguments changed: "
                f"{[payload['arguments'] for payload in payloads]!r}"
            )
        for phase, payload in zip(("setup", "compile", "install"), payloads):
            observed_environment = payload["environment"]
            for key, value in expected_values.items():
                if observed_environment.get(key) != value:
                    raise AssertionError(
                        f"cross-Meson {phase} lost {key}: "
                        f"{observed_environment.get(key)!r}"
                    )
        setup_environment = payloads[0]["environment"]
        for forbidden in scrubbed_values:
            if forbidden in setup_environment:
                raise AssertionError(
                    "cross-Meson setup retained scrubbed environment key "
                    f"{forbidden}"
                )
        for phase, payload in zip(("compile", "install"), payloads[1:]):
            observed_environment = payload["environment"]
            for key, value in scrubbed_values.items():
                if observed_environment.get(key) != value:
                    raise AssertionError(
                        f"cross-Meson {phase} did not inherit {key}: "
                        f"{observed_environment.get(key)!r}"
                    )
    return 3


def validate_wrapper_runtime(wrapper: Path, work_root: Path | None) -> int:
    with tempfile.TemporaryDirectory(
        prefix="swiftvlc-apple-nasm-", dir=work_root
    ) as temporary:
        temporary_path = Path(temporary)
        fake_nasm = temporary_path / "real-nasm"
        record = temporary_path / "arguments.json"
        write_fake_nasm(fake_nasm)

        base_environment = os.environ.copy()
        for name in (
            "NASMENV",
            "VLC_APPLE_NASM_PLATFORM",
            "VLC_APPLE_NASM_MIN_OS_VERSION",
            "VLC_APPLE_NASM_SDK_VERSION",
        ):
            base_environment.pop(name, None)
        base_environment["VLC_APPLE_NASM_REAL"] = str(fake_nasm)
        base_environment["SWIFTVLC_FAKE_NASM_RECORD"] = str(record)

        case_count = 0

        def invoke(
            arguments: list[str],
            metadata: Mapping[str, str] | None = None,
            *,
            expected_exit: int = 0,
            extra_environment: Mapping[str, str] | None = None,
        ) -> list[str] | None:
            nonlocal case_count
            case_count += 1
            record.unlink(missing_ok=True)
            environment = base_environment.copy()
            if metadata:
                environment.update(
                    {
                        "VLC_APPLE_NASM_PLATFORM": metadata["platform"],
                        "VLC_APPLE_NASM_MIN_OS_VERSION": metadata["minimum_os"],
                        "VLC_APPLE_NASM_SDK_VERSION": metadata["sdk"],
                    }
                )
            if extra_environment:
                environment.update(extra_environment)
            result = subprocess.run(
                [str(wrapper), *arguments],
                env=environment,
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )
            if result.returncode != expected_exit:
                raise AssertionError(
                    f"wrapper exit {result.returncode}, expected {expected_exit}; "
                    f"args={arguments!r}; stderr={result.stderr!r}"
                )
            if expected_exit != 0:
                if record.exists():
                    raise AssertionError("invalid wrapper input reached real NASM")
                return None
            if not record.is_file():
                raise AssertionError("successful wrapper invocation did not reach NASM")
            return json.loads(record.read_text(encoding="utf-8"))

        common = {"platform": "iossimulator", "minimum_os": "18.0", "sdk": "26.0"}
        format_cases = (
            ["-f", "macho64", "input.asm"],
            ["-fmacho64", "input.asm"],
            ["-f=macho64", "input.asm"],
            ["--format", "macho64", "input.asm"],
            ["--format=macho64", "input.asm"],
        )
        expected_pragma = "macho build_version iossimulator,18,0,0 sdk_version 26,0,0"
        for arguments in format_cases:
            recorded = invoke(arguments, common)
            if recorded != ["--pragma", expected_pragma, *arguments]:
                raise AssertionError(f"wrong injected NASM arguments: {recorded!r}")
            if recorded.count(expected_pragma) != 1:
                raise AssertionError(
                    "wrapper did not inject exactly one build_version pragma"
                )

        for platform in PLATFORMS:
            metadata = {"platform": platform, "minimum_os": "018.00", "sdk": "26.0.0"}
            arguments = ["-f", "macho64", "input.asm"]
            recorded = invoke(arguments, metadata)
            expected = f"macho build_version {platform},18,0,0 sdk_version 26,0,0"
            if recorded != ["--pragma", expected, *arguments]:
                raise AssertionError(f"wrong {platform} pragma: {recorded!r}")

        passthrough_cases = (
            ["-f", "elf64", "input.asm"],
            ["--", "-fmacho64"],
            ["-f", "macho64", "-f", "elf64", "input.asm"],
        )
        for arguments in passthrough_cases:
            recorded = invoke(
                arguments,
                None,
                extra_environment={
                    "VLC_APPLE_NASM_PLATFORM": "invalid",
                },
            )
            if recorded != arguments:
                raise AssertionError(
                    f"non-macho64 invocation was modified: {recorded!r}"
                )

        invalid_metadata = (
            {},
            {"platform": "invalid", "minimum_os": "18.0", "sdk": "26.0"},
            {"platform": "ios", "minimum_os": "18", "sdk": "26.0"},
            {"platform": "ios", "minimum_os": "18.256", "sdk": "26.0"},
            {"platform": "ios", "minimum_os": "65536.0", "sdk": "26.0"},
            {"platform": "ios", "minimum_os": "18.0.256", "sdk": "26.0"},
            {"platform": "ios", "minimum_os": "18.0", "sdk": "26"},
            {"platform": "ios", "minimum_os": "18.0", "sdk": "26..0"},
        )
        for metadata in invalid_metadata:
            if metadata:
                invoke(["-f", "macho64", "input.asm"], metadata, expected_exit=2)
            else:
                invoke(["-f", "macho64", "input.asm"], None, expected_exit=2)

        invoke(
            ["-f", "macho64", "input.asm"],
            common,
            expected_exit=2,
            extra_environment={"NASMENV": "-w+all"},
        )
        invoke(
            ["-f", "elf64", "input.asm"],
            None,
            expected_exit=2,
            extra_environment={"NASMENV": "-f macho64"},
        )
        invoke(
            ["-@", "hidden-options.rsp", "input.asm"],
            None,
            expected_exit=2,
        )
        invoke(
            ["-@hidden-options.rsp", "input.asm"],
            None,
            expected_exit=2,
        )
        invoke(
            ["--pragma", "macho build_version macos,1,0", "-f", "macho64"],
            common,
            expected_exit=2,
        )

        recursion_environment = base_environment.copy()
        recursion_environment["VLC_APPLE_NASM_REAL"] = str(wrapper)
        result = subprocess.run(
            [str(wrapper), "-f", "elf64", "input.asm"],
            env=recursion_environment,
            text=True,
            capture_output=True,
            check=False,
            timeout=10,
        )
        case_count += 1
        if result.returncode != 2:
            raise AssertionError("wrapper did not reject recursive real-NASM path")

        return case_count


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("patch", type=Path)
    parser.add_argument("--work-root", type=Path)
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    source_root = arguments.source_root.resolve()
    patch_path = arguments.patch.resolve()
    if not source_root.is_dir():
        raise SystemExit(f"missing patched VLC source root: {source_root}")
    if not patch_path.is_file():
        raise SystemExit(f"missing 0038 patch: {patch_path}")
    if arguments.work_root is not None and not arguments.work_root.is_dir():
        raise SystemExit(f"work root is not a directory: {arguments.work_root}")

    source_paths = {key: source_root / value for key, value in PATHS.items()}
    missing = [str(path) for path in source_paths.values() if not path.is_file()]
    if missing:
        raise SystemExit("missing 0038 validation inputs: " + ", ".join(missing))
    sources = {
        key: path.read_text(encoding="utf-8") for key, path in source_paths.items()
    }
    patch = patch_path.read_text(encoding="utf-8")

    validate_sources(sources, source_root)
    validate_patch(patch)
    mutation_count = validate_mutations(sources, patch)
    wrapper_cases = validate_wrapper_runtime(
        source_paths["nasm_wrapper"], arguments.work_root
    )
    install_cases = validate_install_runtime(
        sources["apple_build"],
        source_paths["nasm_wrapper"],
        arguments.work_root,
    )
    meson_environment_cases = validate_cross_meson_environment_runtime(
        sources["contrib_main"], arguments.work_root
    )

    print(
        "PASS Apple assembly metadata source proof: "
        f"paths={len(PATHS)} mutations={mutation_count} "
        f"wrapper_cases={wrapper_cases} install_cases={install_cases} "
        f"meson_environment_cases={meson_environment_cases} "
        f"patch_sha={EXPECTED_PATCH_SHA256}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
