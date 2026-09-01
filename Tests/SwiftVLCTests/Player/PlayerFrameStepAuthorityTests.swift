@testable import SwiftVLC
import CustomDump
import Darwin
import Foundation
import Testing

private struct FrameStepMirror: Equatable {
  let currentTime: Duration
  let position: Double
  let pendingCount: Int
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerFrameStepAuthorityTests {
    @Test
    func `A typed frame request reports exact submitted clock evidence`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }

      let request = player.requestNextFrame()

      #expect(request.initialOutcome == .pending)
      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 3433,
        position: 0.03433
      )
      #expect(await request.outcome == .submitted(
        time: .milliseconds(3433),
        position: PlaybackPosition(0.03433)
      ))
      #expect(player.currentTime == .milliseconds(3433))
      #expect(player.playbackPosition == PlaybackPosition(0.03433))
    }

    @Test
    func `Typed frame terminals distinguish exhaustion failure and invalid evidence`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }

      let exhausted = player.requestNextFrame()
      await complete(
        player,
        requestID: 1,
        status: NativeFrameStepTerminalStatus.noFrame.rawValue,
        timeMilliseconds: -1,
        position: -.infinity
      )
      #expect(await exhausted.outcome == .noFrame)

      let failed = player.requestNextFrame()
      await complete(
        player,
        requestID: 2,
        status: -Int32(EIO),
        timeMilliseconds: -1,
        position: -.infinity
      )
      #expect(await failed.outcome == .failed(code: -Int32(EIO)))

      let invalid = player.requestNextFrame()
      await complete(
        player,
        requestID: 3,
        timeMilliseconds: -1,
        position: 0.5
      )
      #expect(await invalid.outcome == .invalidEvidence)
      #expect(player.currentTime == .milliseconds(3400))
    }

    @Test
    func `Typed frame requests distinguish rejection timeout and supersession`() async {
      let unavailable = makePausedPlayer()
      unavailable._nativeNextFrameOverrideForTesting = { _ in .unavailable }
      let rejected = unavailable.requestNextFrame()
      #expect(rejected.initialOutcome == .rejected)
      #expect(await rejected.outcome == .rejected)

      let timedOut = makePausedPlayer()
      timedOut._nativeNextFrameOverrideForTesting = { _ in .accepted }
      let expired = timedOut.requestNextFrame()
      timedOut._expirePendingFrameStepForTesting(token: 1)
      #expect(await expired.outcome == .timedOut)

      let replaced = makePausedPlayer()
      replaced._nativeNextFrameOverrideForTesting = { _ in .accepted }
      let superseded = replaced.requestNextFrame()
      replaced.resetMediaDerivedState()
      #expect(await superseded.outcome == .superseded)

      replaced.isShutdown = true
      let shutdown = replaced.requestNextFrame()
      #expect(shutdown.initialOutcome == .rejected)
      #expect(await shutdown.outcome == .rejected)
    }

    @Test
    func `Cancelling one typed frame waiter does not cancel the command`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      let request = player.requestNextFrame()
      let waiter = Task { await request.outcome }

      waiter.cancel()
      await Task.yield()
      #expect(player.pendingFrameSteps.first?.resolver.resolvedOutcome == nil)

      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 3433,
        position: 0.03433
      )
      #expect(await waiter.value == .submitted(
        time: .milliseconds(3433),
        position: PlaybackPosition(0.03433)
      ))
    }

    @Test
    func `A frame command does not publish the synchronous stale clock`() {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }

      player.nextFrame()

      expectNoDifference(
        FrameStepMirror(
          currentTime: player.currentTime,
          position: player.position,
          pendingCount: player.pendingFrameSteps.count
        ),
        FrameStepMirror(currentTime: .milliseconds(3400), position: 0.034, pendingCount: 1)
      )
      #expect(dispatched == [1])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)
    }

    @Test
    func `A terminal callback synchronous with native dispatch retains exact ownership`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { requestID in
        player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
          requestID: requestID,
          status: NativeFrameStepTerminalStatus.success.rawValue,
          timeMicroseconds: 3_433_000,
          position: 0.03433
        )
        return .accepted
      }

      player.nextFrame()
      // The callback only copied/enqueued while the native call was on-stack;
      // the Player queue is still coherent until the main actor consumes it.
      #expect(player.pendingFrameSteps.map(\.requestToken) == [1])
      await drainMainActor()

      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3433))
    }

    @Test
    func `A native output commit before a later terminal cannot be superseded`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      let request = player.requestNextFrame()

      // This helper represents the exact native output commit and sole
      // terminal already winning, while Player delivery remains a separately
      // scheduled MainActor task. The later stop cannot reclassify the result.
      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 1,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 3_433_000,
        position: 0.03433
      )
      player.handleEvent(.stateChanged(.stopped))
      await drainMainActor()

      #expect(await request.outcome == .submitted(
        time: .milliseconds(3433),
        position: PlaybackPosition(0.03433)
      ))
      #expect(player.currentTime == .zero)
    }

    @Test
    func `A terminal cancelling before native output commit keeps supersession`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      let request = player.requestNextFrame()

      player.handleEvent(.stateChanged(.stopped))
      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 1,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 9_000_000,
        position: 0.09
      )
      await drainMainActor()

      #expect(await request.outcome == .superseded)
      #expect(player.currentTime == .zero)
    }

    @Test
    func `A native commit that defeats cancellation retains its exact terminal`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { _ in false }
      let request = player.requestNextFrame()

      player.cancelPendingFrameSteps()
      #expect(request.initialOutcome == .pending)
      #expect(player.pendingFrameSteps.isEmpty)
      #expect(Set(player.committedFrameStepsAwaitingTerminal.keys) == Set([UInt64(1)]))

      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 1,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 3_433_000,
        position: 0.03433
      )
      await drainMainActor()

      #expect(await request.outcome == .submitted(
        time: .milliseconds(3433),
        position: PlaybackPosition(0.03433)
      ))
      #expect(player.currentTime == .milliseconds(3400))
      #expect(player.committedFrameStepsAwaitingTerminal.isEmpty)
    }

    @Test
    func `Attachment replacement fail closes a commit waiter with no callback`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { _ in false }
      let request = player.requestNextFrame()

      player.cancelPendingFrameSteps()
      #expect(request.initialOutcome == .pending)
      #expect(player.nativeSeekMonitor._frameResultAuthorityCountsForTesting
        .commitOwners == 1)

      // Timeline replacement detaches the old event attachment. With no
      // callback proof returned by that atomic boundary, the waiter must use
      // its recorded fallback instead of remaining suspended forever.
      player.resetMediaDerivedState()

      #expect(await request.outcome == .superseded)
      #expect(player.committedFrameStepsAwaitingTerminal.isEmpty)
      let counts = player.nativeSeekMonitor._frameResultAuthorityCountsForTesting
      #expect(counts.reservations == 0)
      #expect(counts.commitOwners == 0)
    }

    @Test
    func `Shutdown closes a commit waiter with no callback`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { _ in false }
      let request = player.requestNextFrame()

      player.cancelPendingFrameSteps()
      #expect(request.initialOutcome == .pending)
      await player.shutdown()

      #expect(await request.outcome == .superseded)
      #expect(player.committedFrameStepsAwaitingTerminal.isEmpty)
      let counts = player.nativeSeekMonitor._frameResultAuthorityCountsForTesting
      #expect(counts.reservations == 0)
      #expect(counts.commitOwners == 0)
    }

    @Test
    func `A retired terminal synchronous with busy dispatch retries B without anonymous ownership`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      var firstBAttempt = true
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        if requestID == 2, firstBAttempt {
          firstBAttempt = false
          player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
            requestID: 1,
            status: NativeFrameStepTerminalStatus.success.rawValue,
            timeMicroseconds: 3_433_000,
            position: 0.03433
          )
          return .busy
        }
        return .accepted
      }
      player._nativeCancelNextFrameOverrideForTesting = { _ in false }
      player.nextFrame()
      player.nextFrame()
      player._expirePendingFrameStepForTesting(token: 1)

      // Resume/seek boundaries may let B probe the native slot while the exact
      // retired A ID is still capable of completing synchronously in that call.
      player.nativeSeekMonitor.clearFrameQuarantineForCausalBoundary()
      player.dispatchNextPendingFrameStepIfNeeded()
      await drainMainActor()

      #expect(dispatched == [1, 2, 2])
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)
      #expect(player.currentTime == .milliseconds(3433))
    }

    @Test
    func `An exact terminal event completes even when the displayed frame has equal PTS`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      let revision = player.acceptedTimelineRevision
      player.nextFrame()

      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 3400,
        position: 0.034
      )

      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3400))
      #expect(player.acceptedTimelineRevision > revision)
    }

    @Test
    func `Explicit playing retry waits for authoritative pause then reissues the same command`() async {
      let player = makePlayingPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player.nextFrame()

      await complete(
        player,
        requestID: 1,
        status: NativeFrameStepTerminalStatus.pausedForRetry.rawValue,
        timeMilliseconds: -1,
        position: -.infinity
      )

      #expect(dispatched == [1])
      #expect(player.pendingFrameSteps.first?.phase == .awaitingFrame)
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == false)

      // A synchronous native getter becoming paused is not the lifecycle
      // boundary. The event consumer must adopt `.paused` first.
      player._nativePlaybackStateOverrideForTesting = .paused
      player.dispatchNextPendingFrameStepIfNeeded()
      #expect(dispatched == [1])

      player.handleEvent(.stateChanged(.paused))
      #expect(dispatched == [1, 1])
      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 3433,
        position: 0.03433
      )

      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3433))
    }

    @Test
    func `Explicit no-frame is terminal and never spins`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player.nextFrame()

      await complete(
        player,
        requestID: 1,
        status: NativeFrameStepTerminalStatus.noFrame.rawValue,
        timeMilliseconds: -1,
        position: -.infinity
      )
      player.handleEvent(.stateChanged(.paused))

      #expect(dispatched == [1])
      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3400))
    }

    @Test
    func `Native terminal status values are explicit and errno is only failure`() {
      #expect(NativeFrameStepTerminalStatus.success.rawValue == 0)
      #expect(NativeFrameStepTerminalStatus.pausedForRetry.rawValue == 1)
      #expect(NativeFrameStepTerminalStatus.noFrame.rawValue == 2)
      #expect(
        NativeFrameStepTerminalStatus(rawValue: -Int32(EAGAIN))
          == .failed(-Int32(EAGAIN))
      )
    }

    @Test
    func `A redundant playing event does not cancel a frame awaiting pause`() {
      let player = makePlayingPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }

      player.nextFrame()
      player.handleEvent(.stateChanged(.playing))

      #expect(dispatched == [1])
      #expect(player.pendingFrameSteps.first?.phase == .awaitingPause)
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)
    }

    @Test
    func `A genuine paused-to-playing event retires paused frame ownership`() async {
      let player = makePausedPlayer()
      var cancelled: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { requestID in
        cancelled.append(requestID)
        return true
      }
      player.nextFrame()

      player.handleEvent(.stateChanged(.playing))

      #expect(cancelled == [1])
      #expect(player.pendingFrameSteps.isEmpty)
      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 9000,
        position: 0.09
      )
      #expect(player.currentTime == .milliseconds(3400))
    }

    @Test
    func `Play on a paused session establishes the same frame boundary as resume`() async throws {
      let player = makePausedPlayer()
      var cancelled: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { requestID in
        cancelled.append(requestID)
        return true
      }
      player._nativePlayOverrideForTesting = { 0 }
      player.nextFrame()

      try player.play()

      #expect(cancelled == [1])
      #expect(player.pendingFrameSteps.isEmpty)
      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 9000,
        position: 0.09
      )
      #expect(player.currentTime == .milliseconds(3400))
    }

    @Test
    func `Frame commands are inert after shutdown begins`() {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player.isShutdown = true

      player.nextFrame()

      #expect(dispatched.isEmpty)
      #expect(player.pendingFrameSteps.isEmpty)
    }

    @Test
    func `An invalidated native monitor refuses new frame work`() {
      let player = makePausedPlayer()
      let generation = player.nativeSeekMonitor.frameGeneration
      player.nativeSeekMonitor.invalidate()

      let disposition = player.nativeSeekMonitor.requestFrameStep(
        requestID: 1,
        frameGeneration: generation
      )

      #expect(disposition == .unavailable)
    }

    @Test
    func `Native errors and unavailable strict ABI fail closed`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player.nextFrame()
      await complete(
        player,
        requestID: 1,
        status: -Int32(EINVAL),
        timeMilliseconds: -1,
        position: -.infinity
      )

      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3400))

      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .unavailable
      }
      player.nextFrame()
      #expect(dispatched == [1, 2])
      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3400))
    }

    @Test
    func `Five rapid frame commands serialize by exact request identity`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }

      for _ in 0..<5 {
        player.nextFrame()
      }
      #expect(player.pendingFrameSteps.count == 5)
      #expect(dispatched == [1])

      for requestID in UInt64(1)...5 {
        await complete(
          player,
          requestID: requestID,
          timeMilliseconds: 3400 + Int64(requestID) * 33,
          position: 0.034 + Double(requestID) * 0.00033
        )
        let expectedLast = requestID < 5 ? requestID + 1 : requestID
        #expect(dispatched == Array(UInt64(1)...expectedLast))
      }

      #expect(player.pendingFrameSteps.isEmpty)
      #expect(dispatched == [1, 2, 3, 4, 5])
      #expect(player.currentTime == .milliseconds(3565))
      #expect(abs(player.position - 0.03565) < 0.000_001)
    }

    @Test
    func `Timed out A stays quarantined until late A and cannot settle B`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      var cancelled: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player._nativeCancelNextFrameOverrideForTesting = { requestID in
        cancelled.append(requestID)
        return false
      }
      player.nextFrame()
      player.nextFrame()

      player._expirePendingFrameStepForTesting(token: 1)
      #expect(cancelled == [1])
      #expect(dispatched == [1])
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == false)

      // Cancellation returned false, so strict output commitment can already
      // own A. Its exact result updates the still-current paused timeline but
      // cannot consume B, whose identity remains separate.
      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 3433,
        position: 0.03433
      )
      #expect(player.currentTime == .milliseconds(3433))
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])
      #expect(dispatched == [1, 2])

      await complete(
        player,
        requestID: 2,
        timeMilliseconds: 3466,
        position: 0.03466
      )
      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3466))
    }

    @Test
    func `Busy front command has a bounded deadline without a terminal callback`() {
      let player = makePausedPlayer()
      var cancelled: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { requestID in
        cancelled.append(requestID)
        return false
      }
      player.nextFrame()
      player.nextFrame()

      player._expirePendingFrameStepForTesting(token: 1)
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == false)
      #expect(player.pendingFrameSteps.first?.timeoutTask != nil)

      // Native A never produces its terminal callback. B still retires on its
      // own front-of-FIFO deadline and does not attempt to cancel A again.
      player._expirePendingFrameStepForTesting(token: 2)
      #expect(player.pendingFrameSteps.isEmpty)
      #expect(cancelled == [1])
    }

    @Test
    func `A successful ID matched timeout cancellation releases B immediately`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      var cancelled: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player._nativeCancelNextFrameOverrideForTesting = { requestID in
        cancelled.append(requestID)
        return true
      }
      player.nextFrame()
      player.nextFrame()

      player._expirePendingFrameStepForTesting(token: 1)

      #expect(cancelled == [1])
      #expect(dispatched == [1, 2])
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)

      // Matched native cancellation still emits A's sole -ECANCELED terminal.
      // It must not release or fail the already accepted B slot.
      await complete(
        player,
        requestID: 1,
        status: -Int32(ECANCELED),
        timeMilliseconds: -1,
        position: -.infinity
      )
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)
    }

    @Test
    func `A retired frame request is cancelled at most once`() async {
      let player = makePausedPlayer()
      var cancelled: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { requestID in
        cancelled.append(requestID)
        return false
      }
      player.nextFrame()

      player._expirePendingFrameStepForTesting(token: 1)
      player.cancelPendingFrameSteps()
      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 3433,
        position: 0.03433
      )

      #expect(cancelled == [1])
      #expect(player.pendingFrameSteps.isEmpty)
      #expect(player.currentTime == .milliseconds(3433))
    }

    @Test
    func `External seek invalidates active and queued commands by generation`() async {
      let player = makePausedPlayer()
      var cancelled: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { requestID in
        cancelled.append(requestID)
        return true
      }
      player.nextFrame()
      player.nextFrame()

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      await drainMainActor()

      #expect(cancelled == [1])
      #expect(player.pendingFrameSteps.isEmpty)
      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 9000,
        position: 0.09
      )
      #expect(player.currentTime == .milliseconds(3400))
    }

    @Test
    func `External seek before native commit supersedes the later old result`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { _ in true }
      let request = player.requestNextFrame()

      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 1,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 9_000_000,
        position: 0.09
      )
      await drainMainActor()

      #expect(await request.outcome == .superseded)
      #expect(player.currentTime == .milliseconds(3400))
      #expect(player.playbackPosition == PlaybackPosition(0.034))
    }

    @Test
    func `Native commit before external seek retains outcome without rewriting timeline`() async {
      let player = makePausedPlayer()
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativeCancelNextFrameOverrideForTesting = { _ in false }
      let request = player.requestNextFrame()

      player.cancelPendingFrameSteps()
      #expect(Set(player.committedFrameStepsAwaitingTerminal.keys) == Set([UInt64(1)]))
      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 1,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 3_433_000,
        position: 0.03433
      )
      await drainMainActor()

      #expect(await request.outcome == .submitted(
        time: .milliseconds(3433),
        position: PlaybackPosition(0.03433)
      ))
      #expect(player.currentTime == .milliseconds(3400))
      #expect(player.playbackPosition == PlaybackPosition(0.034))
      #expect(player.committedFrameStepsAwaitingTerminal.isEmpty)
    }

    @Test
    func `Frame dispatch waits for a seek watched landing boundary`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      await drainMainActor()

      player.nextFrame()
      #expect(dispatched.isEmpty)
      #expect(player.pendingFrameSteps.count == 1)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 5000,
        position: 0.05
      )
      await drainMainActor()

      #expect(dispatched == [1])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)
    }

    @Test
    func `Seek drain without an end point cannot leave a frame pending forever`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      await drainMainActor()

      player.nextFrame()
      #expect(dispatched.isEmpty)
      #expect(player.pendingFrameSteps.first?.timeoutTask != nil)
      player._expirePendingFrameStepForTesting(token: 1)

      #expect(player.pendingFrameSteps.isEmpty)
      #expect(dispatched.isEmpty)
    }

    @Test
    func `A frame queued after wrapper seek dispatch survives its later start callback`() async throws {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
      player._nativeSeekBaselineOverrideForTesting = { (3400, 0.034) }
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }

      try player.seek(to: .seconds(5))
      player.nextFrame()
      #expect(dispatched.isEmpty)
      #expect(player.pendingFrameSteps.count == 1)

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 5000,
        position: 0.05
      )
      await drainMainActor()

      #expect(dispatched == [1])
      #expect(player.pendingFrameSteps.first?.nativeRequestInFlight == true)
    }

    @Test
    func `Native commit before resume retains outcome without rewriting resumed timeline`() async {
      let player = makePausedPlayer()
      var dispatched: [UInt64] = []
      player._nativeNextFrameOverrideForTesting = { requestID in
        dispatched.append(requestID)
        return .accepted
      }
      player._nativeCancelNextFrameOverrideForTesting = { _ in false }
      let request = player.requestNextFrame()
      player.resume()
      #expect(player.pendingFrameSteps.isEmpty)

      player._nativePlaybackStateOverrideForTesting = .paused
      player.handleEvent(.stateChanged(.paused))
      player.nextFrame()
      #expect(dispatched == [1, 2])

      await complete(
        player,
        requestID: 1,
        timeMilliseconds: 9000,
        position: 0.09
      )
      #expect(await request.outcome == .submitted(
        time: .milliseconds(9000),
        position: PlaybackPosition(0.09)
      ))
      #expect(player.pendingFrameSteps.map(\.requestToken) == [2])
      #expect(player.currentTime == .milliseconds(3400))
      #expect(player.playbackPosition == PlaybackPosition(0.034))
      #expect(player.committedFrameStepsAwaitingTerminal.isEmpty)
    }

    @Test
    func `Stop and media replacement cancel ownership and reject late results`() async {
      let stopped = makePausedPlayer()
      var stoppedCancellation: [UInt64] = []
      stopped._nativeNextFrameOverrideForTesting = { _ in .accepted }
      stopped._nativeCancelNextFrameOverrideForTesting = { requestID in
        stoppedCancellation.append(requestID)
        return true
      }
      stopped.nextFrame()
      stopped.handleEvent(.stateChanged(.stopped))
      #expect(stoppedCancellation == [1])
      #expect(stopped.pendingFrameSteps.isEmpty)
      await complete(
        stopped,
        requestID: 1,
        timeMilliseconds: 9000,
        position: 0.09
      )
      #expect(stopped.currentTime == .zero)

      let replaced = makePausedPlayer()
      var replacedCancellation: [UInt64] = []
      replaced._nativeNextFrameOverrideForTesting = { _ in .accepted }
      replaced._nativeCancelNextFrameOverrideForTesting = { requestID in
        replacedCancellation.append(requestID)
        return true
      }
      replaced.nextFrame()
      replaced.resetMediaDerivedState()
      #expect(replacedCancellation == [1])
      #expect(replaced.pendingFrameSteps.isEmpty)
      await complete(
        replaced,
        requestID: 1,
        timeMilliseconds: 9000,
        position: 0.09
      )
      #expect(replaced.currentTime == .zero)
    }
  }
}

@MainActor
extension Integration.PlayerFrameStepAuthorityTests {
  fileprivate func makePausedPlayer() -> Player {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player._setStateForTesting(
      state: .paused,
      currentTime: .milliseconds(3400),
      duration: .seconds(100),
      position: 0.034,
      isSeekable: true
    )
    player._nativePlaybackStateOverrideForTesting = .paused
    player._nativeCancelNextFrameOverrideForTesting = { _ in true }
    return player
  }

  fileprivate func makePlayingPlayer() -> Player {
    let player = makePausedPlayer()
    player._setStateForTesting(
      state: .playing,
      currentTime: .milliseconds(3400),
      duration: .seconds(100),
      position: 0.034,
      isSeekable: true
    )
    player._nativePlaybackStateOverrideForTesting = .playing
    return player
  }

  fileprivate func complete(
    _ player: Player,
    requestID: UInt64,
    status: Int32 = NativeFrameStepTerminalStatus.success.rawValue,
    timeMilliseconds: Int64,
    position: Double
  )
    async {
    player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
      requestID: requestID,
      status: status,
      timeMicroseconds: timeMilliseconds >= 0 ? timeMilliseconds * 1000 : -1,
      position: position
    )
    await drainMainActor()
  }

  fileprivate func drainMainActor() async {
    for _ in 0..<20 {
      await Task.yield()
    }
  }
}
