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
