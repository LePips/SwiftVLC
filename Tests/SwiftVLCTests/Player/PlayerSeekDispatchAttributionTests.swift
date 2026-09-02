@testable import SwiftVLC
import CustomDump
import Foundation
import Testing

private enum GetterInjectedExternalEpisode: CaseIterable, Sendable {
  case start
  case startEnd
  case startEndPoint
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekDispatchAttributionTests {
    @Test(arguments: GetterInjectedExternalEpisode.allCases)
    fileprivate func `Immediate finalization cannot expose B to a getter injected external seek`(
      episode: GetterInjectedExternalEpisode
    )
      async {
      let player = makePlayingPlayer()
      var baselineReads = 0
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        return 0
      }
      player._nativeSeekBaselineOverrideForTesting = {
        baselineReads += 1
        if baselineReads == 2 {
          emitGetterExternalEpisode(episode, on: player)
        }
        return (10000, 0.1)
      }

      let request = player.requestJump(by: .seconds(20))
      await drainMainActor()

      #expect(await request.outcome == .superseded)
      #expect(dispatchedOffsets.isEmpty)
      #expect(player.nativeSeekMonitor.externalSeekEpoch == 1)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.currentTime != .seconds(30))
      if episode == .startEndPoint {
        #expect(player.latestAppliedExternalSeekEpoch == 1)
        #expect(player.currentTime == .seconds(33))
      } else {
        #expect(player.nativeSeekMonitor.hasSeekDrainPending)
      }
    }

    @Test(arguments: GetterInjectedExternalEpisode.allCases)
    fileprivate func `Queued finalization cannot expose B to a getter injected external seek`(
      episode: GetterInjectedExternalEpisode
    )
      async {
      let player = makePlayingPlayer()
      var dispatchedTimes: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTimes.append(milliseconds)
        return 0
      }

      try? player.seek(to: .seconds(20))
      let request = player.requestJump(by: .seconds(20))
      var baselineReads = 0
      player._nativeSeekBaselineOverrideForTesting = {
        baselineReads += 1
        if baselineReads == 1 {
          emitGetterExternalEpisode(episode, on: player)
        }
        return (20000, 0.2)
      }

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )
      await drainMainActor()

      #expect(await request.outcome == .superseded)
      expectNoDifference(dispatchedTimes, [20000])
      #expect(player.nativeSeekMonitor.externalSeekEpoch == 1)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.currentTime != .seconds(40))
      if episode == .startEndPoint {
        #expect(player.latestAppliedExternalSeekEpoch == 1)
        #expect(player.currentTime == .seconds(33))
      } else {
        #expect(player.nativeSeekMonitor.hasSeekDrainPending)
      }
    }

    @Test
    func `Unattributed start in the setter window invalidates B before publication`() async {
      let player = makePlayingPlayer()
      var dispatchedOffsets: [Int64] = []
      player._nativeJumpTimeOverrideForTesting = { offset in
        dispatchedOffsets.append(offset)
        // Model a callback from an independently-issued setter interleaving
        // after B was staged. It deliberately has no exact B attribution.
        player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
        return 0
      }

      let request = player.requestJump(by: .seconds(20))
      await drainMainActor()

      #expect(await request.outcome == .superseded)
      expectNoDifference(dispatchedOffsets, [20000])
      #expect(player.nativeSeekMonitor.externalSeekEpoch == 1)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.currentTime == .seconds(10))
      #expect(player.nativeSeekMonitor.hasSeekDrainPending)
    }

    private func makePlayingPlayer() -> Player {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100),
        position: 0.1,
        isSeekable: true
      )
      return player
    }

    private func emitGetterExternalEpisode(
      _ episode: GetterInjectedExternalEpisode,
      on player: Player
    ) {
      // The finalization seam runs before B is staged. This production-shaped
      // tokenless start must therefore advance the external epoch, never claim B.
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      guard episode != .start else { return }
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      guard episode == .startEndPoint else { return }
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
    }

    private func drainMainActor() async {
      for _ in 0..<30 {
        await Task.yield()
      }
    }
  }
}
