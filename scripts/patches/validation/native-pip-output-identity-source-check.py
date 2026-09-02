#!/usr/bin/env python3
"""Adversarial source proof for version-9 native PiP output identity."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import re


HEADER = "include/vlc/libvlc_media_player.h"
MEDIA_PLAYER = "lib/media_player.c"
MEDIA_PLAYER_INTERNAL = "lib/media_player_internal.h"
SYMBOLS = "lib/libvlc.sym"
DRAWABLE = "modules/video_output/apple/VLCDrawable.h"
CONTROLLER = "modules/video_output/apple/VLCPictureInPictureController.m"
DISPLAY = "modules/video_output/apple/VLCSampleBufferDisplay.m"
PIP_HEADER = "modules/video_output/apple/vlc_pip_controller.h"
PATCH_PATHS = (
    HEADER,
    SYMBOLS,
    MEDIA_PLAYER,
    MEDIA_PLAYER_INTERNAL,
    DRAWABLE,
    CONTROLLER,
    DISPLAY,
    PIP_HEADER,
)
EXPECTED_PATCH_SHA256 = (
    "3587daa9ccd017cf109e3c809315b09e8f378d63b8d17600bd6c0366dbd750c8"
)


def require(condition: bool, description: str) -> None:
    if not condition:
        raise AssertionError(description)


def require_count(source: str, token: str, expected: int, description: str) -> None:
    actual = source.count(token)
    require(actual == expected, f"{description}: found {actual}, expected {expected}")


def source_slice(source: str, start: str, end: str) -> str:
    try:
        first = source.index(start)
        last = source.index(end, first + len(start))
    except ValueError as error:
        raise AssertionError(f"cannot isolate {start!r} through {end!r}") from error
    return source[first:last]


def require_order(source: str, tokens: tuple[str, ...], description: str) -> None:
    cursor = 0
    for token in tokens:
        index = source.find(token, cursor)
        require(index >= 0, f"{description}: missing ordered token {token!r}")
        cursor = index + len(token)


def patch_paths(patch: str) -> tuple[str, ...]:
    paths: list[str] = []
    for match in re.finditer(r"^diff --git a/(.+) b/(.+)$", patch, re.MULTILINE):
        old, new = match.groups()
        require(old == new, "0041 must not rename VLC source paths")
        paths.append(old)
    return tuple(paths)


def validate_patch(patch_path: Path) -> None:
    payload = patch_path.read_bytes()
    require(
        hashlib.sha256(payload).hexdigest() == EXPECTED_PATCH_SHA256,
        "0041 patch digest differs from reviewed native PiP source",
    )
    text = payload.decode("utf-8")
    require(patch_paths(text) == PATCH_PATHS, "0041 path inventory/order changed")
    require("modules/demux/" not in text, "0041 overlaps 0042 demux ownership")


def validate_setter(files: dict[str, str]) -> None:
    header = files[HEADER]
    media = files[MEDIA_PLAYER]
    internal = files[MEDIA_PLAYER_INTERNAL]
    symbols = files[SYMBOLS]
    setter = source_slice(
        media,
        "swiftvlc_libvlc_media_player_set_pip_playback_identity(",
        "swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(",
    )
    require_count(header, "swiftvlc_pip_playback_identity_t", 2, "public identity ABI")
    require_count(
        symbols,
        "swiftvlc_libvlc_media_player_set_pip_playback_identity",
        1,
        "identity symbol export",
    )
    require_count(internal, "pip_native_handle_identity", 1, "write-once handle field")
    require_count(internal, "pip_playback_identities", 1, "retained identity list")
    require_order(
        setter,
        (
            "native_handle_identity == 0 || playback_generation == 0",
            "vlc_player_Lock(p_mi->player);",
            "p_mi->pip_native_handle_identity != native_handle_identity",
            "current->identity.playback_generation == playback_generation",
            "return true;",
            "playback_generation < current->identity.playback_generation",
            "malloc(sizeof(*node))",
            "node->identity = (swiftvlc_pip_playback_identity_t)",
            "node->next = current;",
            "p_mi->pip_playback_identities = node;",
            'var_SetAddress(p_mi, "swiftvlc-pip-playback-identity", &node->identity);',
        ),
        "transactional identity publication",
    )
    require_count(setter, "free(node)", 0, "pre-publication phantom cleanup")
    destroy = source_slice(
        media,
        "static void libvlc_media_player_destroy(",
        "/**************************************************************************\n * Release a Media Instance object.",
    )
    require_order(
        destroy,
        ("vlc_player_Delete(p_mi->player);", "p_mi->pip_playback_identities", "free(identity);"),
        "identity retention through output join",
    )


def validate_allocator_and_snapshot(files: dict[str, str]) -> None:
    display = files[DISPLAY]
    allocator = source_slice(
        display,
        "static atomic_uint_fast64_t pipOutputIdentitySource",
        "#if __is_target_os(ios)",
    )
    require_count(allocator, "ATOMIC_VAR_INIT(0)", 1, "zero-based output source")
    require_count(allocator, "atomic_fetch_add", 0, "wrapping output allocator")
    require_order(
        allocator,
        (
            "if (current >= UINT64_MAX - 1)",
            "atomic_compare_exchange_strong_explicit(",
            "&pipOutputIdentitySource, &current, UINT64_MAX",
            "return 0;",
            "uint_fast64_t next = current + 1;",
            "atomic_compare_exchange_weak_explicit(",
            "return next;",
        ),
        "saturating nonzero output allocator",
    )
    creation = source_slice(
        display,
        "static pip_controller_t * CreatePipController( vout_display_t *vd, void *cbs_opaque )\n{",
        "static void DeletePipController( pip_controller_t * pip_controller )\n{",
    )
    require_order(
        creation,
        (
            'var_InheritAddress(vd, "drawable-nsobject")',
            "(__bridge_retained void *)drawable",
            'var_InheritAddress(vd, "swiftvlc-pip-playback-identity")',
            "memcpy(&snapshot, identity, sizeof(snapshot));",
            "snapshot.native_handle_identity",
            "snapshot.playback_generation",
            "NextPipOutputIdentity();",
            'vlc_module_match("pictureinpicture"',
            "vlc_module_map(",
        ),
        "immutable snapshot before PiP module mapping",
    )
    require_count(
        creation,
        "CFBridgingRelease(pip_controller->drawable);",
        2,
        "retained drawable failure cleanup",
    )
    require_count(creation, "pip_controller->output_identity == 0", 1, "allocator exhaustion gate")
    pip_header = files[PIP_HEADER]
    require_order(
        pip_header,
        (
            "void               *drawable;",
            "uint64_t            native_handle_identity;",
            "uint64_t            playback_generation;",
            "uint64_t            output_identity;",
        ),
        "immutable module identity layout",
    )


def validate_presentation_context(files: dict[str, str]) -> None:
    controller = files[CONTROLLER]
    display = files[DISPLAY]
    require_count(controller, "@interface VLCPictureInPicturePresentationContext", 1, "context type")
    require_count(controller, "@property (nonatomic, readonly) uint64_t outputIdentity;", 2, "binding/context output identity")
    context = source_slice(
        controller,
        "@implementation VLCPictureInPicturePresentationContext",
        "#define VLC_PIP_HANDOFF_TOKEN_CLAIMED",
    )
    require_order(
        context,
        ("_controller = controller;", "_nativeHandleIdentity = nativeHandle;", "_playbackGeneration = playbackGeneration;", "_outputIdentity = outputIdentity;"),
        "immutable presentation context capture",
    )
    callbacks = source_slice(controller, "static void *HoldPresentationContext", "static bool ShouldCompositeSubpictures")
    require_order(
        callbacks,
        ("presentationContextForPipController", "context.nativeHandleIdentity", "context.playbackGeneration", "context.outputIdentity", "__bridge_transfer id"),
        "context-only delayed preparation",
    )
    preparation = source_slice(display, "- (void)prepareDisplay", "- (void)placeVideo:")
    require_order(
        preparation,
        ("hold_presentation_context(_pipcontroller)", "dispatch_async(dispatch_get_main_queue()", "preparePresentationContext(", "} @finally {", "releasePresentationContext(presentationContext);"),
        "retained context across main-queue delay",
    )


def validate_controller_state_machine(files: dict[str, str]) -> None:
    controller = files[CONTROLLER]
    drawable = files[DRAWABLE]
    require_count(controller, "atomic_uint_fast64_t _pendingPreparationOutputIdentity;", 1, "prepare CAS token")
    require_count(controller, "atomic_uint_fast64_t _pendingHandoffOutputIdentity;", 1, "handoff CAS token")
    require_count(controller, "atomic_init(&_pendingPreparationOutputIdentity, 0);", 1, "prepare token initialization")
    require_count(controller, "atomic_init(&_pendingHandoffOutputIdentity, 0);", 1, "handoff token initialization")
    require_count(controller, "#define VLC_PIP_HANDOFF_TOKEN_CLAIMED UINT64_MAX", 1, "reserved controller sentinel")
    require_count(controller, "pictureInPictureReady", 0, "legacy ready callback in v9 module")
    require_count(controller, "mediaPlaybackGeneration", 0, "dynamic generation lookup in v9 module")
    require_count(controller, "consumePictureInPictureVideoOutputRebuildPermit", 0, "Boolean seek permit in v9 module")

    prepare = source_slice(
        controller,
        "- (BOOL)prepare:(AVSampleBufferDisplayLayer *)layer\n    nativeHandle:",
        "- (void)closeForVideoOutput:(pip_controller_t *)pipcontroller {",
    )
    require_order(
        prepare,
        (
            "bindingSnapshotForNativeHandle:nativeHandle",
            "![NSThread isMainThread]",
            "_preparingOutputIdentity = outputIdentity;",
            "initWithSampleBufferDisplayLayer:layer",
            "_avPipController = avPipController;",
            "didBecomeReadyForNativeHandle:nativeHandle",
            "_preparingOutputIdentity = 0;",
            "if (!accepted || !isCurrent)",
            "[self closeForBinding:binding];",
            "if (closeWasRequested)",
        ),
        "prepare/ready/close serialization",
    )
    close = source_slice(
        controller,
        "- (void)closeForBinding:(VLCPictureInPictureBinding *)binding {",
        "- (void)performCloseCleanup {",
    )
    require_order(
        close,
        (
            "_preparingOutputIdentity == outputIdentity",
            "_closeRequestedOutputIdentity = outputIdentity;",
            "_pendingPreparationOutputIdentity",
            "_pendingHandoffOutputIdentity",
            "preservePictureInPictureWindowController:self",
            "sameMediaGenerationRebuild:NO",
            "timeOutHandoffForDrawable:binding.drawable",
        ),
        "pre-prepare close chaining",
    )
    handoff_timeout = source_slice(
        controller,
        "- (void)timeOutHandoffForDrawable:(id<VLCPictureInPictureDrawable>)drawable\n"
        "    nativeHandle:(uint64_t)nativeHandle\n"
        "    playbackGeneration:(uint64_t)playbackGeneration\n"
        "    outputIdentity:(uint64_t)outputIdentity {",
        "- (void)timeOutPreparationForBinding:\n    (VLCPictureInPictureBinding *)binding {",
    )
    for token in (
        "binding.nativeHandleIdentity == nativeHandle",
        "binding.playbackGeneration == playbackGeneration",
        "binding.outputIdentity == outputIdentity",
        "&_pendingHandoffOutputIdentity",
    ):
        require_count(handoff_timeout, token, 1, f"exact handoff-timeout check {token}")
    preparation_timeout = source_slice(
        controller,
        "- (void)timeOutPreparationForBinding:\n    (VLCPictureInPictureBinding *)binding {",
        "- (void)closeForNativeHandle:(uint64_t)nativeHandle\n"
        "    playbackGeneration:(uint64_t)playbackGeneration\n"
        "    outputIdentity:(uint64_t)outputIdentity {",
    )
    require_count(preparation_timeout, "_binding == binding", 1, "exact preparation-timeout binding")
    require_count(preparation_timeout, "&_pendingPreparationOutputIdentity", 1, "preparation-timeout CAS")

    delegate = source_slice(
        controller,
        "#pragma mark - AVPictureInPictureSampleBufferPlaybackDelegate",
        "#pragma mark - AVPictureInPictureControllerDelegate",
    )
    require_count(delegate, "[self activeBindingSnapshot]", 4, "lock-protected delegate binding snapshots")
    require_count(delegate, "_mediaController", 0, "racy mutable media-controller reader")
    require_count(controller, "VLCPictureInPictureBinding *oldBinding = _binding;", 1, "old binding retained for unlocked release")
    require_count(drawable, "same-media seek rebuild", 0, "obsolete seek-continuity claim")


def validate_open_transaction(files: dict[str, str]) -> None:
    controller = files[CONTROLLER]
    open_source = source_slice(controller, "static int OpenController(", "/*\n * Module descriptor")
    require_count(open_source, "BOOL missingExactLifecycle =", 1, "exact-selector preflight")
    for selector in (
        "takePreservedPictureInPictureWindowControllerForNativeHandle:",
        "pictureInPictureWindowController:didClaimNativeHandle:",
        "pictureInPictureControllerCreationFailedForNativeHandle:",
        "cancelHandoffForNativeHandle:",
        "didBecomeReadyForNativeHandle:",
        "preservePictureInPictureWindowController:fromNativeHandle:",
        "handoffDidTimeOutForNativeHandle:",
    ):
        require(selector in open_source, f"missing v9 selector preflight/call: {selector}")
    require_count(
        open_source,
        "didClaimNativeHandle:pipcontroller->native_handle_identity",
        2,
        "preserved and fresh exact claims",
    )
    require_count(
        open_source,
        "pictureInPictureControllerCreationFailedForNativeHandle:",
        3,
        "rollback preflight plus two fresh rollback calls",
    )
    preserved = source_slice(open_source, "if (preserved != nil) {", "        } else {")
    require_order(
        preserved,
        (
            "didClaimNativeHandle:pipcontroller->native_handle_identity",
            "if (!didClaim)",
            "return VLC_EGENERIC;",
            "rebindToPipController:pipcontroller",
            "return VLC_EGENERIC;",
        ),
        "claim-before-rebind preserved transaction",
    )
    fresh = source_slice(open_source, "        } else {", "\n        if (![sys startPreparationTimeoutForNativeHandle:")
    require_order(
        fresh,
        (
            "initWithPipController:pipcontroller",
            "if (sys == nil)",
            "pictureInPictureControllerCreationFailedForNativeHandle:",
            "return VLC_EGENERIC;",
            "didClaimNativeHandle:pipcontroller->native_handle_identity",
            "if (!didClaim)",
            "pictureInPictureControllerCreationFailedForNativeHandle:",
            "closeForNativeHandle:",
            "return VLC_EGENERIC;",
        ),
        "fresh init/claim/rollback transaction",
    )
    require_order(
        open_source,
        (
            "startPreparationTimeoutForNativeHandle:",
            "cancelHandoffForNativeHandle:",
            "return VLC_EGENERIC;",
            "pipcontroller->p_sys = (__bridge_retained void*)sys;",
        ),
        "timeout ownership before p_sys publication",
    )
    require_count(open_source, "return VLC_EGENERIC;", 9, "fail-closed Open exits")
    require_count(open_source, "pictureInPictureReady", 0, "legacy Open ready path")


def validate_all(files: dict[str, str]) -> None:
    validate_setter(files)
    validate_allocator_and_snapshot(files)
    validate_presentation_context(files)
    validate_controller_state_machine(files)
    validate_open_transaction(files)


MUTATIONS = (
    (DISPLAY, "if (current >= UINT64_MAX - 1)", "if (current == UINT64_MAX - 1)", "allocator wrap guard"),
    (DISPLAY, "&pipOutputIdentitySource, &current, UINT64_MAX", "&pipOutputIdentitySource, &current, 0", "allocator saturation"),
    (DISPLAY, "atomic_compare_exchange_weak_explicit(", "atomic_fetch_add_explicit(", "allocator CAS"),
    (DISPLAY, "pip_controller->output_identity = NextPipOutputIdentity();", "pip_controller->output_identity = 1;", "unique output allocation"),
    (DISPLAY, "(__bridge_retained void *)drawable", "(__bridge void *)drawable", "drawable retention"),
    (DISPLAY, "memcpy(&snapshot, identity, sizeof(snapshot));", "snapshot = *(const swiftvlc_pip_inherited_identity_t *)identity;", "byte snapshot"),
    (DISPLAY, "releasePresentationContext(presentationContext);", "(void)presentationContext;", "delayed context release"),
    (CONTROLLER, "![NSThread isMainThread]", "false", "release main-thread guard"),
    (CONTROLLER, "atomic_uint_fast64_t _pendingPreparationOutputIdentity;", "atomic_uint_fast64_t _pendingHandoffOutputIdentity;", "separate preparation token"),
    (CONTROLLER, "_preparingOutputIdentity = outputIdentity;", "_preparingOutputIdentity = 0;", "ready-vs-close arming"),
    (CONTROLLER, "_closeRequestedOutputIdentity = outputIdentity;", "_closeRequestedOutputIdentity = 0;", "close-during-prepare request"),
    (CONTROLLER, "if (!accepted || !isCurrent)", "if (!isCurrent)", "synchronous ready rejection"),
    (CONTROLLER, "binding.nativeHandleIdentity == nativeHandle", "binding.nativeHandleIdentity != nativeHandle", "timeout handle provenance"),
    (CONTROLLER, "binding.playbackGeneration == playbackGeneration", "binding.playbackGeneration != playbackGeneration", "timeout generation provenance"),
    (CONTROLLER, "didClaimNativeHandle:pipcontroller->native_handle_identity", "didClaimNativeHandle:0", "exact controller claim"),
    (CONTROLLER, "pictureInPictureControllerCreationFailedForNativeHandle:", "pictureInPictureControllerCreationIgnoredForNativeHandle:", "unclaimed rollback"),
    (CONTROLLER, "startPreparationTimeoutForNativeHandle:", "skipPreparationTimeoutForNativeHandle:", "pre-prepare liveness timer"),
    (CONTROLLER, "pipcontroller->p_sys = (__bridge_retained void*)sys;", "pipcontroller->p_sys = NULL;", "p_sys retained publication"),
    (CONTROLLER, "[self activeBindingSnapshot].mediaController", "[self bindingSnapshot].mediaController", "delegate binding snapshot"),
    (CONTROLLER, "sameMediaGenerationRebuild:NO", "sameMediaGenerationRebuild:YES", "same-generation fail-close"),
    (MEDIA_PLAYER, "playback_generation < current->identity.playback_generation", "playback_generation > current->identity.playback_generation", "generation regression"),
    (MEDIA_PLAYER, "return true;\n    }\n    if (current != NULL &&", "return false;\n    }\n    if (current != NULL &&", "idempotent publication"),
    (MEDIA_PLAYER, "vlc_player_Delete(p_mi->player);", "/* player deletion moved */", "output join before identity free"),
    (CONTROLLER, "_outputIdentity = outputIdentity;", "_outputIdentity = 0;", "immutable presentation identity"),
)


def run_mutations(files: dict[str, str]) -> int:
    detected = 0
    for path, old, new, name in MUTATIONS:
        require(old in files[path], f"mutation fixture is stale: {name}")
        mutated = dict(files)
        mutated[path] = mutated[path].replace(old, new)
        try:
            validate_all(mutated)
        except AssertionError:
            detected += 1
        else:
            raise AssertionError(f"validator accepted adversarial mutation: {name}")
    return detected


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_root", type=Path)
    parser.add_argument("patch", type=Path)
    args = parser.parse_args()
    files = {path: (args.source_root / path).read_text() for path in PATCH_PATHS}
    validate_patch(args.patch)
    validate_all(files)
    detected = run_mutations(files)
    print(
        "native PiP output identity source contract passed: "
        f"{len(PATCH_PATHS)} paths, {detected} adversarial mutations"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
