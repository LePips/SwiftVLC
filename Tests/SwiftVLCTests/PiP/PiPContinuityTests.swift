#if os(iOS)
@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPContinuityTests {
    private enum Marker: Equatable, Sendable {
      case rebuilding(PlaybackGeneration, PlaybackGeneration)
      case restored(PlaybackGeneration, PlaybackGeneration)
      case timedOut(PlaybackGeneration, PlaybackGeneration)
    }

    private nonisolated static func marker(
      for transition: IOSNativePiPContinuityCoordinator.Transition
    ) -> Marker {
      switch transition {
      case .rebuilding(let previous, let successor):
        .rebuilding(previous, successor)
      case .restored(let previous, let successor, _):
        .restored(previous, successor)
      case .timedOut(let previous, let successor, _):
        .timedOut(previous, successor)
      }
    }

    @Test
    func `one native controller is handed to the successor generation`() {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let controller = NSObject()
      let original = PlaybackGeneration(11)
      let successor = PlaybackGeneration(12)

      coordinator.didBecomeReady(controller, mediaGeneration: original)
      #expect(coordinator.preserve(controller, for: original) == false)
      #expect(coordinator.preserve(controller, for: successor))
      #expect(coordinator.takePreservedController(for: successor) === controller)
      #expect(coordinator.takePreservedController(for: successor) == nil)
      coordinator.didBecomeReady(controller, mediaGeneration: successor)

      #expect(events.withLock { $0 } == [
        .rebuilding(original, successor),
        .restored(original, successor)
      ])
    }

    @Test
    func `successor waits for asynchronously retiring output to preserve controller`() async {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator(
        expectedHandoffWait: .seconds(1)
      ) { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let controller = NSObject()
      let original = PlaybackGeneration(71)
      let successor = PlaybackGeneration(72)

      coordinator.didBecomeReady(controller, mediaGeneration: original)
      coordinator.expectHandoff(for: successor)
      // A late readiness callback from the current output must not cancel the
      // successor expectation staged just before asynchronous retirement.
      coordinator.didBecomeReady(controller, mediaGeneration: original)
      let take = Task.detached { @Sendable in
        coordinator.takePreservedController(for: successor).map(ObjectIdentifier.init)
      }
      try? await Task.sleep(for: .milliseconds(20))
      #expect(coordinator.preserve(controller, for: successor))
      let preservedIdentity = await take.value
      #expect(preservedIdentity == ObjectIdentifier(controller))
      coordinator.didBecomeReady(controller, mediaGeneration: successor)

      #expect(events.withLock { $0 } == [
        .rebuilding(original, successor),
        .restored(original, successor)
      ])
    }

    @Test
    func `same-generation handoff requires explicit rebuild proof`() {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let controller = NSObject()
      let generation = PlaybackGeneration(13)

      coordinator.didBecomeReady(controller, mediaGeneration: generation)
      #expect(coordinator.preserve(controller, for: generation) == false)
      #expect(coordinator.preserve(
        controller,
        for: generation,
        allowsSameGenerationRebuild: true
      ))
      #expect(coordinator.takePreservedController(for: generation) === controller)
      coordinator.didBecomeReady(controller, mediaGeneration: generation)

      #expect(events.withLock { $0 } == [
        .rebuilding(generation, generation),
        .restored(generation, generation)
      ])
    }

    @Test
    func `seek rebuild permit is generation-bound one-shot and cancelable`() throws {
      let permits = IOSNativePiPVideoOutputRebuildPermit()
      let generation = PlaybackGeneration(14)
      let other = PlaybackGeneration(15)

      #expect(permits.stage(for: generation) == nil)
      permits.setPiPActive(true)
      let first = try #require(permits.stage(for: generation))
      #expect(permits.consume(for: other) == false)
      #expect(permits.consume(for: generation))
      #expect(permits.consume(for: generation) == false)

      let canceled = try #require(permits.stage(for: generation))
      permits.cancel(canceled)
      #expect(permits.consume(for: generation) == false)

      _ = permits.stage(for: generation)
      permits.invalidate()
      #expect(permits.consume(for: generation) == false)

      _ = first
      _ = permits.stage(for: generation, validity: .zero)
      #expect(permits.consume(for: generation) == false)

      _ = permits.stage(for: generation)
      permits.setPiPActive(false)
      permits.setPiPActive(true)
      #expect(permits.consume(for: generation) == false)
    }

    @Test
    func `terminal player events invalidate a staged seek rebuild permit`() throws {
      let player = Player()
      player.nativePiPVideoOutputRebuildPermit.setPiPActive(true)

      _ = try #require(
        player.nativePiPVideoOutputRebuildPermit.stage(for: player.generation)
      )
      player.handleEvent(.stateChanged(.stopped))
      #expect(
        player.nativePiPVideoOutputRebuildPermit.consume(for: player.generation) == false
      )

      _ = try #require(
        player.nativePiPVideoOutputRebuildPermit.stage(for: player.generation)
      )
      player.handleEvent(.encounteredError)
      #expect(
        player.nativePiPVideoOutputRebuildPermit.consume(for: player.generation) == false
      )
    }

    @Test
    func `the native timeout publishes one terminal outcome`() {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let controller = NSObject()
      let original = PlaybackGeneration(21)
      let successor = PlaybackGeneration(22)

      coordinator.didBecomeReady(controller, mediaGeneration: original)
      #expect(coordinator.preserve(controller, for: successor))
      #expect(coordinator.takePreservedController(for: successor) === controller)
      coordinator.didTimeOut(controller)
      coordinator.didBecomeReady(controller, mediaGeneration: successor)
      coordinator.didTimeOut(controller)

      #expect(events.withLock { $0 } == [
        .rebuilding(original, successor),
        .timedOut(original, successor)
      ])
    }

    @Test
    func `a stale controller or generation cannot complete a handoff`() {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let controller = NSObject()
      let staleController = NSObject()
      let original = PlaybackGeneration(31)
      let successor = PlaybackGeneration(32)
      let laterSuccessor = PlaybackGeneration(33)

      coordinator.didBecomeReady(controller, mediaGeneration: original)
      #expect(coordinator.preserve(controller, for: successor))
      #expect(coordinator.takePreservedController(for: successor) === controller)
      coordinator.didBecomeReady(staleController, mediaGeneration: successor)
      coordinator.didBecomeReady(controller, mediaGeneration: original)
      coordinator.didTimeOut(controller)
      coordinator.didBecomeReady(controller, mediaGeneration: successor)
      #expect(coordinator.preserve(controller, for: laterSuccessor))
      #expect(coordinator.takePreservedController(for: laterSuccessor) === controller)
      coordinator.didBecomeReady(controller, mediaGeneration: laterSuccessor)

      #expect(events.withLock { $0 } == [
        .rebuilding(original, successor),
        .timedOut(original, successor),
        .rebuilding(original, laterSuccessor),
        .restored(original, laterSuccessor)
      ])
    }

    @Test
    func `a fresh controller can recover the generation that timed out`() {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let expiredController = NSObject()
      let freshController = NSObject()
      let original = PlaybackGeneration(41)
      let timedOut = PlaybackGeneration(42)
      let successor = PlaybackGeneration(43)

      coordinator.didBecomeReady(expiredController, mediaGeneration: original)
      #expect(coordinator.preserve(expiredController, for: timedOut))
      #expect(coordinator.takePreservedController(for: timedOut) === expiredController)
      coordinator.didTimeOut(expiredController)

      coordinator.didBecomeReady(freshController, mediaGeneration: timedOut)
      #expect(coordinator.preserve(freshController, for: successor))
      #expect(coordinator.takePreservedController(for: successor) === freshController)
      coordinator.didBecomeReady(freshController, mediaGeneration: successor)

      #expect(events.withLock { $0 } == [
        .rebuilding(original, timedOut),
        .timedOut(original, timedOut),
        .rebuilding(timedOut, successor),
        .restored(timedOut, successor)
      ])
    }

    @Test
    func `a skipped output retargets the held controller to the newest generation`() {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let controller = NSObject()
      let original = PlaybackGeneration(51)
      let skipped = PlaybackGeneration(52)
      let newest = PlaybackGeneration(53)

      coordinator.didBecomeReady(controller, mediaGeneration: original)
      #expect(coordinator.preserve(controller, for: skipped))
      #expect(coordinator.takePreservedController(for: original) == nil)
      #expect(coordinator.takePreservedController(for: newest) === controller)
      coordinator.didBecomeReady(controller, mediaGeneration: skipped)
      coordinator.didBecomeReady(controller, mediaGeneration: newest)

      #expect(events.withLock { $0 } == [
        .rebuilding(original, skipped),
        .rebuilding(original, newest),
        .restored(original, newest)
      ])
    }

    @Test
    func `an intermediate output can preserve the same controller for a later load`() {
      let events = Mutex<[Marker]>([])
      let coordinator = IOSNativePiPContinuityCoordinator { transition in
        events.withLock { $0.append(Self.marker(for: transition)) }
      }
      let controller = NSObject()
      let original = PlaybackGeneration(61)
      let intermediate = PlaybackGeneration(62)
      let newest = PlaybackGeneration(63)

      coordinator.didBecomeReady(controller, mediaGeneration: original)
      #expect(coordinator.preserve(controller, for: intermediate))
      #expect(coordinator.takePreservedController(for: intermediate) === controller)
      #expect(coordinator.preserve(controller, for: newest))
      #expect(coordinator.takePreservedController(for: newest) === controller)
      coordinator.didBecomeReady(controller, mediaGeneration: intermediate)
      coordinator.didBecomeReady(controller, mediaGeneration: newest)

      #expect(events.withLock { $0 } == [
        .rebuilding(original, intermediate),
        .rebuilding(original, newest),
        .restored(original, newest)
      ])
    }
  }
}
#endif
