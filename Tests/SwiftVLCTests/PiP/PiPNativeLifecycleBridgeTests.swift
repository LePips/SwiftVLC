#if os(iOS)
@testable import SwiftVLC
import AVFoundation
import AVKit
import Synchronization
import Testing

private final class NativePiPDownstreamRecorder: NSObject,
  AVPictureInPictureControllerDelegate,
  @unchecked Sendable {
  let calls = Mutex<[String]>([])

  nonisolated func pictureInPictureControllerWillStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    calls.withLock { $0.append("willStart") }
  }

  nonisolated func pictureInPictureControllerDidStartPictureInPicture(
    _: AVPictureInPictureController
  ) {
    calls.withLock { $0.append("didStart") }
  }

  nonisolated func pictureInPictureControllerWillStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    calls.withLock { $0.append("willStop") }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(
    _: AVPictureInPictureController
  ) {
    calls.withLock { $0.append("didStop") }
  }
}

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPNativeLifecycleBridgeTests {
    @Test
    func `playback failure reports its authoritative stop reason`() async {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(),
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let avController = AVPictureInPictureController(contentSource: contentSource)
      var events = controller.pipEvents.makeAsyncIterator()
      player._setStateForTesting(state: .error)

      controller.pictureInPictureControllerWillStopPictureInPicture(avController)
      controller.pictureInPictureControllerDidStopPictureInPicture(avController)

      guard
        case .willStop(reason: .failure) = await events.next(),
        case .didStop(reason: .failure) = await events.next()
      else {
        Issue.record("playback failure stop was not classified as failure")
        return
      }
    }

    @Test
    func `native delegate bridge publishes the complete ordered lifecycle`() async throws {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let attachment = backend.attach(to: player)
      let ready = try #require(
        backend.callbackGenerations.reserveReadyCallback(for: attachment)
      )
      let controller = PiPController(player: player, nativeBackend: backend)
      var events = controller.pipEventEnvelopes.makeAsyncIterator()

      backend.nativeDelegateWillStart(generation: ready)
      backend.nativeDelegateDidStart(generation: ready)
      backend.nativeDelegateWillStop(generation: ready)
      backend.nativeDelegateDidStop(generation: ready)

      let received = await [
        events.next(),
        events.next(),
        events.next(),
        events.next()
      ]
      guard
        case .willStart = received[0]?.event,
        case .didStart = received[1]?.event,
        case .willStop(reason: .userClosed) = received[2]?.event,
        case .didStop(reason: .userClosed) = received[3]?.event
      else {
        Issue.record("native lifecycle events were missing or out of order")
        return
      }
      #expect(controller.isActive == false)
    }

    @Test
    func `native delegate bridge preserves libVLC delegate behavior`() async throws {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let attachment = backend.attach(to: player)
      let ready = try #require(
        backend.callbackGenerations.reserveReadyCallback(for: attachment)
      )
      let owner = PiPController(player: player, nativeBackend: backend)
      var events = owner.pipEvents.makeAsyncIterator()
      let downstream = NativePiPDownstreamRecorder()
      let bridge = IOSNativePiPDelegateBridge(
        backend: backend,
        downstream: downstream,
        generation: ready
      )
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(),
        playbackDelegate: owner._playbackDelegateForTesting
      )
      let avController = AVPictureInPictureController(contentSource: contentSource)

      bridge.pictureInPictureControllerWillStartPictureInPicture(avController)
      bridge.pictureInPictureControllerDidStartPictureInPicture(avController)
      bridge.pictureInPictureControllerWillStopPictureInPicture(avController)
      bridge.pictureInPictureControllerDidStopPictureInPicture(avController)

      _ = await events.next()
      _ = await events.next()
      _ = await events.next()
      _ = await events.next()
      #expect(
        downstream.calls.withLock { $0 }
          == ["willStart", "didStart", "willStop", "didStop"]
      )
    }

    @Test
    func `native controller replacement closes the old lifecycle authoritatively`() async throws {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let attachment = backend.attach(to: player)
      let ready = try #require(
        backend.callbackGenerations.reserveReadyCallback(for: attachment)
      )
      let controller = PiPController(player: player, nativeBackend: backend)
      var events = controller.pipEventEnvelopes.makeAsyncIterator()

      backend.nativeDelegateWillStart(generation: ready)
      backend.nativeDelegateDidStart(generation: ready)
      controller.handleNativePictureInPictureControllerReplacement(
        wasActive: true,
        mediaGeneration: player.generation
      )
      backend.nativeDelegateWillStart(generation: ready)
      backend.nativeDelegateDidStart(generation: ready)

      let received = await [
        events.next(),
        events.next(),
        events.next(),
        events.next(),
        events.next(),
        events.next()
      ]
      guard
        case .willStart = received[0]?.event,
        case .didStart = received[1]?.event,
        case .willStop(reason: .controllerReplaced) = received[2]?.event,
        case .didStop(reason: .controllerReplaced) = received[3]?.event,
        case .willStart = received[4]?.event,
        case .didStart = received[5]?.event
      else {
        Issue.record("replacement lifecycle was missing or misattributed")
        return
      }
      #expect(received.prefix(4).allSatisfy { $0?.controllerGeneration == 1 })
      #expect(received.suffix(2).allSatisfy { $0?.controllerGeneration == 2 })
    }

    @Test
    func `native delegate failure carries its error and generation`() async throws {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let attachment = backend.attach(to: player)
      let ready = try #require(
        backend.callbackGenerations.reserveReadyCallback(for: attachment)
      )
      let controller = PiPController(player: player, nativeBackend: backend)
      var events = controller.pipEventEnvelopes.makeAsyncIterator()
      let failure = NSError(domain: "swiftvlc.test.native-pip", code: 84)

      backend.nativeDelegateFailedToStart(failure, generation: ready)

      let envelope = try #require(await events.next())
      guard case .failedToStart(let error) = envelope.event else {
        Issue.record("expected native failedToStart, got \(envelope.event)")
        return
      }
      #expect((error as NSError).domain == failure.domain)
      #expect((error as NSError).code == failure.code)
      #expect(envelope.mediaGeneration == player.generation)
    }

    @Test
    func `native restore answers AVKit exactly once when host answers twice`() async throws {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let attachment = backend.attach(to: player)
      let ready = try #require(
        backend.callbackGenerations.reserveReadyCallback(for: attachment)
      )
      let controller = PiPController(player: player, nativeBackend: backend)
      controller.onRestoreUserInterface = { answer in
        answer(true)
        answer(false)
      }
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: AVSampleBufferDisplayLayer(),
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let avController = AVPictureInPictureController(contentSource: contentSource)
      let answers = Mutex<[Bool]>([])

      backend.nativeDelegateRestore(
        avController,
        downstream: nil,
        generation: ready
      ) { restored in
        answers.withLock { $0.append(restored) }
      }

      try #require(
        await poll(timeout: .seconds(2), until: { !answers.withLock { $0 }.isEmpty }),
        "native restore never answered AVKit"
      )
      #expect(answers.withLock { $0 } == [true])
    }
  }
}
#endif
