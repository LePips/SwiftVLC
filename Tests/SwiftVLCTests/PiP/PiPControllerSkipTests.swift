#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVKit
import CoreMedia
import CustomDump
import Synchronization
import Testing

/// Covers PiP skip: how AVKit's requested interval reaches the player, and
/// what happens when the resulting jump is refused.
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPControllerSkipTests {
    @MainActor
    final class PlaybackRecorder {
      var skipIntervals: [CMTime] = []
      var skipOutcome: PiPController.SkipOutcome = .settled
      var skipRequest: PiPController.SkipRequest?

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: { _, _ in .init(accepted: true, playbackControlRevision: nil) },
          resume: { _ in true },
          cancelPendingPause: { _, _, _ in },
          shouldResume: { false },
          skip: { interval in
            self.skipIntervals.append(interval)
            return self.skipRequest ?? .init(resolved: self.skipOutcome)
          }
        )
      }
    }

    /// The interval AVKit asked for reaches the player unchanged.
    ///
    /// Bounds are deliberately *not* applied here any more. PiP used to
    /// convert the interval into an absolute target and clamp it against
    /// `currentTime` and `duration` before issuing a strict seek, which broke
    /// exactly where a DVR skip matters most: live and timeshift media have no
    /// duration to clamp against, and `currentTime` is itself an estimate
    /// between native clock samples, so rounding through it landed the skip
    /// somewhere other than the requested distance away. The relative jump is
    /// resolved against the input's own clock instead, and bounds are libVLC's
    /// to enforce.
    @Test
    func `A backwards skip from zero passes the interval through unclamped`() async {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      await controller._skipByIntervalForTesting(CMTime(seconds: -10, preferredTimescale: 1000))

      expectNoDifference(recorder.skipIntervals.map(\.seconds), [-10])
    }

    /// An overshoot past a known duration is libVLC's to bound, not PiP's.
    @Test
    func `A skip past duration passes the interval through unclamped`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(9),
        duration: .seconds(10)
      )
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      await controller._skipByIntervalForTesting(CMTime(seconds: 60, preferredTimescale: 1000))

      expectNoDifference(recorder.skipIntervals.map(\.seconds), [60])
    }

    /// A mid-range skip fires exactly one jump carrying the requested offset.
    @Test
    func `A skip within bounds issues one jump with the requested interval`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(
        currentTime: .seconds(5),
        duration: .seconds(60)
      )
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      await controller._skipByIntervalForTesting(CMTime(seconds: 3, preferredTimescale: 1000))

      expectNoDifference(recorder.skipIntervals.map(\.seconds), [3])
    }

    /// A refused jump must not be recorded as a skip that happened.
    ///
    /// The controller suppresses its timebase drift corrector for a second
    /// after each skip, so that the corrector does not fight a seek that is
    /// still settling. Arming that suppression for a skip libVLC refused blinds
    /// the corrector for a second over a timeline that never moved — precisely
    /// when it should be free to correct.
    @Test
    func `A rejected skip is not recorded as a skip`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(5), duration: .seconds(60))
      let recorder = PlaybackRecorder()
      recorder.skipOutcome = .rejected
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      await controller._skipByIntervalForTesting(CMTime(seconds: 30, preferredTimescale: 1000))

      #expect(
        controller._didRecordSkipForTesting() == false,
        "a refused skip armed the drift-corrector suppression"
      )
    }

    /// The accepted counterpart, so the test above is proving a difference
    /// rather than an always-false property.
    @Test
    func `A settled skip is recorded`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(5), duration: .seconds(60))
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      await controller._skipByIntervalForTesting(CMTime(seconds: 30, preferredTimescale: 1000))

      #expect(controller._didRecordSkipForTesting())
    }

    /// AVKit's contract: the completion handler runs once the skip finishes or
    /// fails. Never twice, and never not at all — a missing call leaves the PiP
    /// transport spinning.
    @Test
    func `A skip calls its completion handler exactly once`() async {
      let player = Player(instance: TestInstance.shared)
      player._setStateForTesting(currentTime: .seconds(5), duration: .seconds(60))
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )
      let interval = CMTime(seconds: 3, preferredTimescale: 1000)

      #expect(await controller._skipCompletionCountForTesting(interval) == 1)

      recorder.skipOutcome = .rejected
      #expect(
        await controller._skipCompletionCountForTesting(interval) == 1,
        "a refused skip must still complete, exactly once"
      )

      // Note: an unrepresentable interval cannot be covered through the stub
      // driver, which returns a canned outcome without converting anything.
      // `performSkip` classifies that case, and is tested directly below.
    }

    /// Dispatch acceptance is not completion. AVKit must stay pending until
    /// the matching native clock sample proves that the jump landed.
    @Test
    func `Completion waits for authoritative settlement`() async {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let resolver = SeekOutcomeResolver()
      recorder.skipRequest = .init(seekRequest: SeekRequest(resolver: resolver))
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )
      let completionCount = Mutex(0)

      controller.handleSkip(
        by: CMTime(seconds: 3, preferredTimescale: 1000)
      ) { completionCount.withLock { $0 += 1 } }
      await Task.yield()

      #expect(completionCount.withLock { $0 } == 0)
      #expect(controller._didRecordSkipForTesting() == false)
      #expect(controller.pendingSkipCount == 1)

      resolver.resolve(.settled)
      for _ in 0..<20 where completionCount.withLock({ $0 }) == 0 {
        await Task.yield()
      }

      #expect(completionCount.withLock { $0 } == 1)
      #expect(controller._didRecordSkipForTesting())
      #expect(controller.pendingSkipCount == 0)
    }

    /// A bounded failure still discharges AVKit's completion debt, but does
    /// not claim that the timeline moved.
    @Test
    func `A timed out skip completes without recording a landing`() async {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let resolver = SeekOutcomeResolver()
      recorder.skipRequest = .init(seekRequest: SeekRequest(resolver: resolver))
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )
      let completionCount = Mutex(0)

      controller.handleSkip(
        by: CMTime(seconds: 3, preferredTimescale: 1000)
      ) { completionCount.withLock { $0 += 1 } }
      resolver.resolve(.timedOut)
      for _ in 0..<20 where completionCount.withLock({ $0 }) == 0 {
        await Task.yield()
      }

      #expect(completionCount.withLock { $0 } == 1)
      #expect(controller._didRecordSkipForTesting() == false)
    }

    /// The task waiting for native settlement deliberately holds the
    /// controller weakly. Dropping the owner must still discharge AVKit's
    /// completion debt after the request reaches a terminal result.
    @Test
    func `A pending skip still completes after the controller is released`() async {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let resolver = SeekOutcomeResolver()
      recorder.skipRequest = .init(seekRequest: SeekRequest(resolver: resolver))
      var controller: PiPController? = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )
      let completionCount = Mutex(0)

      controller?.handleSkip(
        by: CMTime(seconds: 3, preferredTimescale: 1000)
      ) { completionCount.withLock { $0 += 1 } }
      await Task.yield()
      controller = nil

      resolver.resolve(.superseded)
      for _ in 0..<20 where completionCount.withLock({ $0 }) == 0 {
        await Task.yield()
      }

      #expect(completionCount.withLock { $0 } == 1)
    }

    /// The interval classification lives in `performSkip`, so it is tested
    /// against the real function rather than through the stub driver — the stub
    /// returns a canned outcome and never converts an interval, so routing
    /// these through it would assert nothing.
    @Test
    func `An unrepresentable interval is classified without reaching the player`() async {
      let player = Player(instance: TestInstance.shared)

      for interval in [
        CMTime.invalid,
        .indefinite,
        .positiveInfinity,
        .negativeInfinity,
        CMTime(value: LibVLCTimeMilliseconds.minimum - 1, timescale: 1000),
        CMTime(value: LibVLCTimeMilliseconds.maximum + 1, timescale: 1000)
      ] {
        let request = PiPController.performSkip(on: player, by: interval)
        #expect(request.initialOutcome == .unrepresentableInterval)
        #expect(await request.outcome == .unrepresentableInterval)
      }
    }

    @Test
    func `Exact VLC tick boundary PiP intervals remain representable`() async {
      let player = Player(instance: TestInstance.shared)

      for interval in [
        CMTime(value: LibVLCTimeMilliseconds.minimum, timescale: 1000),
        CMTime(value: LibVLCTimeMilliseconds.maximum, timescale: 1000)
      ] {
        let request = PiPController.performSkip(on: player, by: interval)
        #expect(request.initialOutcome == .rejected)
        #expect(await request.outcome == .rejected)
      }
    }

    /// A representable interval with no session to seek in is a rejection, not
    /// an unrepresentable interval. Distinguishing the two is the point of the
    /// typed outcome.
    @Test
    func `A representable interval without a session is rejected`() async {
      let player = Player(instance: TestInstance.shared)

      let request = PiPController.performSkip(
        on: player,
        by: CMTime(seconds: 3, preferredTimescale: 1000)
      )

      #expect(request.initialOutcome == .rejected)
      #expect(await request.outcome == .rejected)
    }

    /// Completion still has to run exactly once when the interval cannot be
    /// converted — that path returns before the driver is consulted at all.
    @Test
    func `An unrepresentable interval still completes exactly once`() async {
      let player = Player(instance: TestInstance.shared)
      let recorder = PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10)
      )

      #expect(await controller._skipCompletionCountForTesting(.invalid) == 1)
      #expect(recorder.skipIntervals.isEmpty, "an unconvertible interval reached the driver")
    }
  }
}
#endif
