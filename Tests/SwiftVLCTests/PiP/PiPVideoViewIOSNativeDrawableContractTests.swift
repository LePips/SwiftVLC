#if os(iOS)
@testable import SwiftVLC
import CLibVLC
import CustomDump
import SwiftUI
import Synchronization
import Testing
import UIKit

extension Integration.PiPVideoViewIOSNativeTests {
  @Test
  func `iOS native PiP drawable exposes VLC PiP selectors`() throws {
    let player = Player(instance: TestInstance.shared)
    let view = IOSNativePiPDrawableView()
    view.attach(to: player)
    let attachment = try #require(view.drawableAttachment)

    #expect(attachment.responds(to: NSSelectorFromString("addSubview:")))
    #expect(attachment.responds(to: NSSelectorFromString("bounds")))
    #expect(attachment.responds(to: NSSelectorFromString("mediaController")))
    #expect(attachment.responds(to: NSSelectorFromString("pictureInPictureReady")))
    #expect(attachment.responds(to: NSSelectorFromString("canStartPictureInPictureAutomaticallyFromInline")))
    for selector in [
      "takePreservedPictureInPictureWindowControllerForNativeHandle:playbackGeneration:outputIdentity:wasSuperseded:",
      "preservePictureInPictureWindowController:fromNativeHandle:playbackGeneration:outputIdentity:sameMediaGenerationRebuild:",
      "pictureInPictureWindowController:didClaimNativeHandle:playbackGeneration:outputIdentity:",
      "pictureInPictureWindowController:didBecomeReadyForNativeHandle:playbackGeneration:outputIdentity:",
      "pictureInPictureControllerCreationFailedForNativeHandle:playbackGeneration:outputIdentity:",
      "pictureInPictureWindowController:cancelHandoffForNativeHandle:playbackGeneration:outputIdentity:",
      "pictureInPictureWindowController:handoffDidTimeOutForNativeHandle:playbackGeneration:outputIdentity:"
    ] {
      #expect(attachment.responds(to: NSSelectorFromString(selector)))
    }
    if let protocolObject = NSProtocolFromString("VLCPictureInPictureDrawable") {
      // Bind `conforms(to:)` to a plain Bool first. Calling it through an
      // `AnyObject` (below) inside the `#expect` autoclosure makes SILGen
      // emit a reabstraction thunk that crashes the iOS compiler (Swift
      // 6.3.2); hoisting the call out of the autoclosure sidesteps it, and
      // we keep both conformance checks consistent.
      let conformsToDrawable = attachment.conforms(to: protocolObject)
      #expect(conformsToDrawable)
    } else {
      Issue.record("VLCPictureInPictureDrawable protocol is not registered")
    }

    let mediaController = attachment.mediaController()
    if let protocolObject = NSProtocolFromString("VLCPictureInPictureMediaControlling") {
      let conformsToMediaControlling = mediaController.conforms(to: protocolObject)
      #expect(conformsToMediaControlling)
    } else {
      Issue.record("VLCPictureInPictureMediaControlling protocol is not registered")
    }

    var legacyWasSuperseded = ObjCBool(false)
    #expect(
      attachment.takePreservedPictureInPictureWindowController(
        wasSuperseded: &legacyWasSuperseded
      ) == nil
    )
    #expect(legacyWasSuperseded.boolValue)
    view.detach()
  }

  /// The VLCPictureInPictureDrawable selectors are invoked by libVLC
  /// from its vout thread; their bodies are `nonisolated` and must be
  /// callable (and return correct values) off the main actor.
  @Test
  func `iOS native PiP drawable selectors are callable off the main actor`() async throws {
    let player = Player(instance: TestInstance.shared)
    let view = IOSNativePiPDrawableView(startsAutomaticallyFromInline: false)
    view.attach(to: player)
    let attachment = try #require(view.drawableAttachment)

    struct Refs: @unchecked Sendable {
      let attachment: IOSNativePiPDrawableAttachment
    }
    let refs = Refs(attachment: attachment)

    let (canStart, hasMediaController) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Bool), Never>) in
      DispatchQueue.global().async {
        let canStart = refs.attachment.canStartPictureInPictureAutomaticallyFromInline()
        let mediaController = refs.attachment.mediaController()
        // Building the ready block off-main must also be safe; it only
        // captures a weak backend reference.
        _ = refs.attachment.pictureInPictureReady()
        continuation.resume(returning: (canStart, mediaController is IOSNativePiPMediaController))
      }
    }

    #expect(canStart == false)
    #expect(hasMediaController)
    view.detach()
  }

  @Test
  func `iOS native PiP drawable reports the configured auto-start flag`() throws {
    let supportsExactOutputIdentity = swiftvlc_native_pip_handoff_v9_available()
    let enabledPlayer = Player(instance: TestInstance.shared)
    let enabledView = IOSNativePiPDrawableView(startsAutomaticallyFromInline: true)
    enabledView.attach(to: enabledPlayer)
    let enabled = try #require(enabledView.drawableAttachment)
    #expect(
      enabled.canStartPictureInPictureAutomaticallyFromInline()
        == supportsExactOutputIdentity
    )

    let disabledPlayer = Player(instance: TestInstance.shared)
    let disabledView = IOSNativePiPDrawableView(startsAutomaticallyFromInline: false)
    disabledView.attach(to: disabledPlayer)
    let disabled = try #require(disabledView.drawableAttachment)
    #expect(disabled.canStartPictureInPictureAutomaticallyFromInline() == false)

    // Omitting the argument defaults to auto-start enabled.
    let defaultPlayer = Player(instance: TestInstance.shared)
    let defaultView = IOSNativePiPDrawableView()
    defaultView.attach(to: defaultPlayer)
    let defaultAttachment = try #require(defaultView.drawableAttachment)
    #expect(
      defaultAttachment.canStartPictureInPictureAutomaticallyFromInline()
        == supportsExactOutputIdentity
    )

    enabledView.detach()
    disabledView.detach()
    defaultView.detach()
  }

  @Test
  func `iOS native PiP host propagates the auto-start flag to its drawable`() throws {
    let supportsExactOutputIdentity = swiftvlc_native_pip_handoff_v9_available()
    let player = Player(instance: TestInstance.shared)
    let host = IOSNativePiPHostView(startsAutomaticallyFromInline: false)
    host.attach(to: player)
    let attachment = try #require(host.drawableView.drawableAttachment)
    #expect(attachment.canStartPictureInPictureAutomaticallyFromInline() == false)

    let defaultPlayer = Player(instance: TestInstance.shared)
    let defaultHost = IOSNativePiPHostView()
    defaultHost.attach(to: defaultPlayer)
    let defaultAttachment = try #require(defaultHost.drawableView.drawableAttachment)
    #expect(
      defaultAttachment.canStartPictureInPictureAutomaticallyFromInline()
        == supportsExactOutputIdentity
    )

    host.detach()
    defaultHost.detach()
  }

  @Test
  func `iOS native PiP drawable sizes VLC content to its bounds`() throws {
    let player = Player(instance: TestInstance.shared)
    let view = IOSNativePiPDrawableView()
    view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
    view.attach(to: player)
    let attachment = try #require(view.drawableAttachment)
    let vlcSubview = UIView()
    attachment.addSubview(vlcSubview)
    view.layoutIfNeeded()
    attachment.layoutIfNeeded()

    #expect(vlcSubview.frame.size == CGSize(width: 640, height: 360))
    #expect(vlcSubview.autoresizingMask == [.flexibleWidth, .flexibleHeight])

    view.frame = CGRect(x: 0, y: 0, width: 480, height: 270)
    view.layoutIfNeeded()
    attachment.layoutIfNeeded()

    #expect(vlcSubview.frame.size == CGSize(width: 480, height: 270))
    #expect(vlcSubview.autoresizingMask == [.flexibleWidth, .flexibleHeight])

    view.detach()
  }

  @Test
  func `iOS native PiP media controller reports playback intent`() {
    let player = Player(instance: TestInstance.shared)
    let mediaController = IOSNativePiPMediaController()
    mediaController.player = player

    #expect(mediaController.isMediaPlaying() == false)

    player.setPlaybackIntentFromExternalControl(true)
    #expect(mediaController.isMediaPlaying() == true)

    player.setPlaybackIntentFromExternalControl(false)
    #expect(mediaController.isMediaPlaying() == false)
  }

  /// libVLC's native PiP controller compares this callback result against
  /// `VLC_TICK_INVALID`, which is 0 in the pinned libVLC build. Returning
  /// libvlc's public `-1` length sentinel would instead make AVKit receive a
  /// finite negative time range for live/unknown-duration media.
  @Test
  func `iOS native PiP media controller maps unknown length to VLC tick invalid`() {
    let player = Player(instance: TestInstance.shared)
    let mediaController = IOSNativePiPMediaController()
    mediaController.player = player

    #expect(mediaController.mediaLength() == 0)
  }

  /// A ready block can outlive the drawable/player attachment that created
  /// it. Once a successor attachment starts, the old block must be unable
  /// to install its window controller or publish state into that successor.
  @Test
  func `iOS native PiP generation rejects callbacks from an old attachment`() throws {
    let generations = IOSNativePiPCallbackGenerations()
    let firstAttachment = generations.beginAttachment()
    let firstReady = try #require(
      generations.reserveReadyCallback(for: firstAttachment)
    )

    let secondAttachment = generations.beginAttachment()
    var staleMutationRan = false

    #expect(generations.reserveReadyCallback(for: firstAttachment) == nil)
    #expect(generations.reserveReadyCallback(for: secondAttachment) != nil)
    #expect(!generations.isCurrent(firstReady))
    #expect(!generations.performIfCurrent(firstReady) { staleMutationRan = true })
    #expect(!staleMutationRan)
  }

  /// libVLC may rebuild its native PiP window controller without changing
  /// players. Work queued by the previous ready callback must not overwrite
  /// state published by the replacement controller.
  @Test
  func `iOS native PiP generation keeps only the newest ready callback`() throws {
    let generations = IOSNativePiPCallbackGenerations()
    let attachment = generations.beginAttachment()
    let firstReady = try #require(
      generations.reserveReadyCallback(for: attachment)
    )
    let secondReady = try #require(
      generations.reserveReadyCallback(for: attachment)
    )
    var appliedGeneration = 0

    #expect(!generations.performIfCurrent(firstReady) { appliedGeneration = 1 })
    #expect(generations.performIfCurrent(secondReady) { appliedGeneration = 2 })
    #expect(appliedGeneration == 2)
  }
}
#endif
