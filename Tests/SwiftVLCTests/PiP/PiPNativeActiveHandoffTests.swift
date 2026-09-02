#if os(iOS)
@testable import SwiftVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPNativeActiveHandoffTests {
    private func authorizeReadyController(
      _ controller: NSObject,
      output: IOSNativePiPOutputIdentity,
      on coordinator: IOSNativePiPContinuityCoordinator
    ) {
      if case .createFresh = coordinator.takePreservedControllerOutcome(for: output) {
        // Expected: the first exact output owns the fresh authorization.
      } else {
        Issue.record("the first output was not authorized to create a controller")
      }
      #expect(coordinator.didClaimFreshController(controller, output: output))
      #expect(coordinator.didBecomeReady(controller, output: output))
    }

    /// AVKit's synchronous active state can lead the backend's main-actor
    /// mirror by one queued callback. The successor must still wait for the
    /// retiring native output to preserve its live controller in that gap.
    @Test
    func `play replacement expects handoff while AVKit active state leads its mirror`() async throws {
      let player = Player(instance: TestInstance.shared)
      let view = IOSNativePiPDrawableView()
      view.attach(to: player)
      let attachment = try #require(view.drawableAttachment)
      let backend = attachment.nativePiPBackend
      let coordinator = attachment.continuityCoordinator
      let outgoing = IOSNativePiPOutputIdentity(
        nativeHandle: 41,
        playbackGeneration: PlaybackGeneration(41),
        output: 41
      )
      let successor = IOSNativePiPOutputIdentity(
        nativeHandle: 42,
        playbackGeneration: PlaybackGeneration(42),
        output: 42
      )
      let controller = NSObject()

      authorizeReadyController(controller, output: outgoing, on: coordinator)
      #expect(!backend.isActive, "the Swift mirror must remain inactive")
      backend._avControllerIsActiveForHandoffOverrideForTesting = true
      defer {
        backend._avControllerIsActiveForHandoffOverrideForTesting = nil
      }

      #expect(coordinator.expectHandoff(to: successor.binding))
      let take = Task.detached {
        coordinator.takePreservedController(for: successor)
          .map(ObjectIdentifier.init)
      }

      try #require(
        await poll(
          every: .milliseconds(10),
          timeout: .seconds(2),
          until: {
            coordinator._isWaitingForExpectedHandoffForTesting(successor)
          }
        ),
        "the successor did not wait for the native-active controller"
      )
      #expect(coordinator.preserve(controller, from: outgoing))
      let takenController = await take.value
      #expect(takenController == ObjectIdentifier(controller))
    }

    /// MediaListPlayer can advance media without rebuilding the current vout.
    /// The externally adopted generation must retire PiP before the mutable
    /// player mirror advances, while a wrapper echo and stale callback leave
    /// the exact current controller untouched.
    @Test
    func `external media change fails PiP closed without a vout callback`() throws {
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.testMP4URL))
      let view = IOSNativePiPDrawableView()
      view.attach(to: player)
      defer { view.detach() }
      let attachment = try #require(view.drawableAttachment)
      let coordinator = attachment.continuityCoordinator
      let controller = NSObject()
      let currentGeneration = player.sessionGeneration
      let output = IOSNativePiPOutputIdentity(
        nativeHandle: player.nativeHandleLifetime.nativePiPHandleIdentity,
        playbackGeneration: PlaybackGeneration(currentGeneration),
        output: 901
      )
      authorizeReadyController(controller, output: output, on: coordinator)

      let nativeHandleGeneration = player.eventBridge.currentNativeHandleGeneration
      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: currentGeneration,
        event: .mediaChanged
      ))
      #expect(coordinator.isCurrentReady(controller, output: output))

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: currentGeneration &- 1,
        event: .mediaChanged
      ))
      #expect(coordinator.isCurrentReady(controller, output: output))

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: currentGeneration &+ 1,
        event: .mediaChanged
      ))
      #expect(!coordinator.isCurrentReady(controller, output: output))
      #expect(player.sessionGeneration == currentGeneration &+ 1)
      #expect(player.activeVideoOutputs == 0)
    }
  }
}
#endif
