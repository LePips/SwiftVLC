#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVKit
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPCompatibilityAPITests {
    @Test
    func `Version 1 stop reasons remain exhaustively switchable`() {
      let reasons: [PiPStopReason] = [
        .userClosed,
        .restoreRequested,
        .failure,
        .mediaEnded,
        .unknown
      ]

      #expect(reasons.map(Self.compatibilityName) == [
        "userClosed",
        "restoreRequested",
        "failure",
        "mediaEnded",
        "unknown"
      ])
    }

    @Test
    func `Extensible stop causes preserve detail without expanding the compatibility enum`() {
      #expect(PiPStopCause.programmatic.rawValue == "programmatic")
      #expect(PiPStopCause.controllerReplaced.rawValue == "controllerReplaced")
      #expect(PiPStopCause.programmatic.compatibilityReason == .unknown)
      #expect(PiPStopCause.controllerReplaced.compatibilityReason == .unknown)
      #expect(PiPStopCause(rawValue: "futureCause").compatibilityReason == .unknown)

      #expect(PiPStopCause.userClosed.compatibilityReason == .userClosed)
      #expect(PiPStopCause.restoreRequested.compatibilityReason == .restoreRequested)
      #expect(PiPStopCause.failure.compatibilityReason == .failure)
      #expect(PiPStopCause.mediaEnded.compatibilityReason == .mediaEnded)
    }

    @Test
    func `Programmatic delegate stop preserves the version 1 event shape`() async throws {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let avController = makeDummyAVController(for: controller)
      var compatibilityEvents = controller.pipEvents.makeAsyncIterator()
      var attributedEvents = controller.pipEventEnvelopes.makeAsyncIterator()

      controller._setStateForTesting(isActive: true)
      controller.stop()
      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      let willStop = try #require(await compatibilityEvents.next())
      let didStop = try #require(await compatibilityEvents.next())
      guard case .willStop(reason: .unknown) = willStop else {
        Issue.record("Expected version-1-compatible .willStop(.unknown), got \(willStop)")
        return
      }
      guard case .didStop(reason: .unknown) = didStop else {
        Issue.record("Expected version-1-compatible .didStop(.unknown), got \(didStop)")
        return
      }

      let attributedWillStop = try #require(await attributedEvents.next())
      let attributedDidStop = try #require(await attributedEvents.next())
      #expect(attributedWillStop.stopCause == .programmatic)
      #expect(attributedDidStop.stopCause == .programmatic)
    }

    @Test
    func `Native fallback keeps a programmatic cause out of the compatibility enum`() async throws {
      let player = Player(instance: TestInstance.shared)
      #if os(iOS)
      let backend = IOSNativePiPBackend()
      #else
      let backend = MacNativePiPBackend()
      #endif
      let controller = PiPController(player: player, nativeBackend: backend)
      var events = controller.pipEventEnvelopes.makeAsyncIterator()

      controller.handleNativePictureInPictureActiveChanged(true)
      controller.stop()
      controller.handleNativePictureInPictureActiveChanged(false)

      _ = await events.next()
      let terminal = try #require(await events.next())
      guard case .didStop(reason: .unknown) = terminal.event else {
        Issue.record("Expected version-1-compatible .didStop(.unknown), got \(terminal.event)")
        return
      }
      #expect(terminal.stopCause == .programmatic)
    }

    private static func compatibilityName(_ reason: PiPStopReason) -> String {
      switch reason {
      case .userClosed: "userClosed"
      case .restoreRequested: "restoreRequested"
      case .failure: "failure"
      case .mediaEnded: "mediaEnded"
      case .unknown: "unknown"
      }
    }

    private func makeDummyAVController(
      for controller: PiPController
    ) -> AVPictureInPictureController {
      if let installed = controller.pipController {
        return installed
      }
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      return AVPictureInPictureController(contentSource: contentSource)
    }
  }
}
#endif
