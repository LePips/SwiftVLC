#if os(iOS) || os(macOS)
@testable import SwiftVLC
import Testing

/// The timebase rules the state observer applies on every event.
///
/// Every branch is gated on the player actively playing, which CI cannot
/// reach — so the rules live in a pure function and are asserted here rather
/// than being left as unreachable code inside the observer.
@Suite(.tags(.logic))
struct PiPTimebaseRetrackingTests {
  private func retracking(
    isActive: Bool = true,
    rate: Float = 1.0,
    lastRate: Float = 1.0,
    hasTimebase: Bool = true,
    isSkipPending: Bool = false,
    secondsSinceSkip: Double = 5.0,
    playerSeconds: Double = 0,
    timebaseSeconds: Double = 0
  )
    -> PiPController.TimebaseRetracking {
    PiPController.timebaseRetracking(
      isActive: isActive,
      rate: rate,
      lastRate: lastRate,
      hasTimebase: hasTimebase,
      isSkipPending: isSkipPending,
      secondsSinceSkip: secondsSinceSkip,
      playerSeconds: playerSeconds,
      timebaseSeconds: timebaseSeconds
    )
  }

  @Test
  func `A steady rate and an aligned clock ask for nothing`() {
    #expect(retracking() == PiPController.TimebaseRetracking())
  }

  @Test
  func `A rate change retracks the timebase`() {
    let result = retracking(rate: 2.0, lastRate: 1.0)
    #expect(result.adoptsRate)
    #expect(result.setsRate == 2.0)
  }

  /// The rate is adopted even when nothing is pushed, or the comparison would
  /// fire again on every subsequent event and never settle.
  @Test(arguments: [(false, true), (true, false)])
  func `An unpushable rate change is still adopted`(state: (isActive: Bool, hasTimebase: Bool)) {
    let result = retracking(
      isActive: state.isActive,
      rate: 0.5,
      lastRate: 1.0,
      hasTimebase: state.hasTimebase
    )
    #expect(result.adoptsRate, "the rate change would be re-detected forever")
    #expect(result.setsRate == nil)
    #expect(result.setsTime == nil)
  }

  @Test
  func `A large divergence resyncs the timebase`() {
    let result = retracking(playerSeconds: 40, timebaseSeconds: 10)
    #expect(result.setsTime == 40)
  }

  /// A PiP-issued skip writes the timebase itself; overwriting it while it
  /// settles would drag the scrubber back to where the player has not moved
  /// from yet.
  @Test
  func `A recent skip suppresses the resync`() {
    #expect(retracking(secondsSinceSkip: 0.5, playerSeconds: 40, timebaseSeconds: 10).setsTime == nil)
  }

  /// Settlement can legitimately outlast the historical one-second grace
  /// period. Pending state, not elapsed time, keeps the optimistic Player
  /// estimate from leaking into AVKit.
  @Test
  func `A pending skip suppresses resync beyond the grace period`() {
    #expect(
      retracking(
        isSkipPending: true,
        secondsSinceSkip: 5,
        playerSeconds: 40,
        timebaseSeconds: 10
      ).setsTime == nil
    )
  }

  /// Small drift is normal between a decoded clock and a host timebase.
  /// Correcting it every tick would be visible as a stutter.
  @Test(arguments: [0.0, 1.0, 1.9, -1.9])
  func `A small divergence is left alone`(offset: Double) {
    #expect(retracking(playerSeconds: 10 + offset, timebaseSeconds: 10).setsTime == nil)
  }

  @Test
  func `An inactive player is never retracked`() {
    let result = retracking(isActive: false, rate: 2.0, lastRate: 1.0, playerSeconds: 40, timebaseSeconds: 10)
    #expect(result.setsRate == nil)
    #expect(result.setsTime == nil)
  }

  @Test
  func `Rate resolutions use exact handle and playback provenance`() {
    let currentNative = NativePlayerGeneration(3)
    let currentPlayback = PlaybackGeneration(7)
    let current = EffectivePlaybackRateResolution(
      effectiveRate: 2,
      nativeGeneration: currentNative,
      playbackGeneration: currentPlayback
    )
    let retiredHandle = EffectivePlaybackRateResolution(
      effectiveRate: 0.5,
      nativeGeneration: NativePlayerGeneration(2),
      playbackGeneration: currentPlayback
    )
    let supersededPlayback = EffectivePlaybackRateResolution(
      effectiveRate: 0.5,
      nativeGeneration: currentNative,
      playbackGeneration: PlaybackGeneration(6)
    )

    #expect(PiPController.shouldObserveEffectivePlaybackRateResolution(
      current,
      nativeGeneration: currentNative,
      authoritativePlaybackGeneration: currentPlayback
    ))
    #expect(!PiPController.shouldObserveEffectivePlaybackRateResolution(
      retiredHandle,
      nativeGeneration: currentNative,
      authoritativePlaybackGeneration: currentPlayback
    ))
    #expect(!PiPController.shouldObserveEffectivePlaybackRateResolution(
      supersededPlayback,
      nativeGeneration: currentNative,
      authoritativePlaybackGeneration: currentPlayback
    ))
  }
}

extension Integration {
  /// PiP's state observer is the consumer issue #78 was filed about. The lane
  /// split landed, but this observer kept reading the mixed `events` stream,
  /// so the guarantee existed without reaching the code that needed it.
  ///
  /// What a loss costs here is not cosmetic: `.seekableChanged` is one-shot, so
  /// dropping it leaves the controller on the conservative media-changed reset
  /// for the rest of the session — linear playback, no skip controls, on media
  /// that is in fact seekable.
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PiPStateObserverLaneTests {
    /// Drains the observer until it has processed the sentinel, or gives up.
    ///
    /// The sentinel is broadcast last, so it survives a newest-wins buffer
    /// whether or not the fix is present. That is what makes the assertion
    /// after it meaningful rather than a race: reaching it proves the observer
    /// ran and drained, so a missing earlier event was dropped, not pending.
    private func drainObserver(of controller: PiPController, untilDurationIs milliseconds: Int64) async -> Bool {
      for _ in 0..<2000 {
        if controller.playbackStateObservation.durationMilliseconds == milliseconds {
          return true
        }
        await Task.yield()
      }
      return false
    }

    @Test(.timeLimit(.minutes(1)))
    func `Dedicated rate resolution retracks from its native payload`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let bridge = player.eventBridge

      bridge._broadcastEffectivePlaybackRateResolutionForTesting(
        1.75,
        nativeHandleGeneration: bridge.currentNativeHandleGeneration
      )

      for _ in 0..<2000 {
        if controller.lastObservedRate == 1.75 {
          break
        }
        await Task.yield()
      }
      #expect(controller.lastObservedRate == 1.75)
    }

    @Test(.timeLimit(.minutes(1)))
    func `A timing burst cannot evict the seekability the observer needs`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let bridge = player.eventBridge
      let nativeHandleGeneration = bridge.currentNativeHandleGeneration

      // Broadcast first, so it sits on the oldest side of the backlog — where
      // a newest-wins buffer evicts.
      bridge._broadcastForTesting(.seekableChanged(true), nativeHandleGeneration: nativeHandleGeneration)
      // Both observer tasks are @MainActor and so is this test, so none of
      // this is delivered until the first suspension below: the whole burst
      // queues against a stalled consumer, which is the real-world condition.
      for index in 0..<500 {
        bridge._broadcastForTesting(.timeChanged(.milliseconds(index)), nativeHandleGeneration: nativeHandleGeneration)
        bridge._broadcastForTesting(.positionChanged(Double(index) / 500), nativeHandleGeneration: nativeHandleGeneration)
      }
      bridge._broadcastForTesting(.lengthChanged(.seconds(7)), nativeHandleGeneration: nativeHandleGeneration)

      #expect(
        await drainObserver(of: controller, untilDurationIs: 7000),
        "the observer never processed the sentinel; the assertion below would be racing"
      )
      #expect(
        controller.playbackStateObservation.isSeekable,
        "a 1000-event timing burst evicted the seekability change, pinning PiP to linear playback"
      )
    }

    /// The other half: the observer must still converge from clock ticks. The
    /// timing lane is what makes duration and seekability reachable during
    /// steady playback, when no further state transition arrives — so routing
    /// control events losslessly must not come at the cost of dropping the
    /// tick that drives convergence.
    @Test(.timeLimit(.minutes(1)))
    func `The observer still reacts to timing events`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(player: player)
      let bridge = player.eventBridge
      let nativeHandleGeneration = bridge.currentNativeHandleGeneration

      bridge._broadcastForTesting(.lengthChanged(.seconds(3)), nativeHandleGeneration: nativeHandleGeneration)
      #expect(await drainObserver(of: controller, untilDurationIs: 3000))

      // A tick alone, with no control event following it, has to reach the
      // observer. Asserting on the timing lane's own delivery rather than on a
      // downstream effect keeps this independent of capability polling.
      var sawTick = false
      let timing = player.timingEvents
      bridge._broadcastForTesting(.timeChanged(.milliseconds(42)), nativeHandleGeneration: nativeHandleGeneration)
      for await event in timing {
        if case .timeChanged = event {
          sawTick = true
          break
        }
      }

      #expect(sawTick, "the timing lane stopped delivering clock ticks")
    }

    /// Player and PiP consume separate streams from one native callback. The
    /// bridge owns the media generation synchronously, but Player's main-actor
    /// mirror may not have consumed it when PiP drains the successor's following
    /// capability events. The whole successor burst must follow bridge
    /// authority; filtering against only `Player.generation` drops valid one-shot
    /// payloads and can leave PiP linear for the rest of the session.
    @Test(.timeLimit(.minutes(1)))
    func `Bridge-ahead successor capability reaches observer while Player mirror is stalled`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      // Deliberately hold the Player mirror behind the shared bridge. PiP keeps
      // its independent subscription, reproducing the scheduling order without
      // timing guesses about which main-actor task runs first.
      player.eventTask?.cancel()
      let outgoing = player.generation
      let controller = PiPController(player: player)
      let bridge = player.eventBridge
      let nativeHandleGeneration = bridge.currentNativeHandleGeneration
      let successorValue = bridge.synchronizePlaybackGeneration(
        player.sessionGeneration &+ 1,
        media: nil
      )
      let successor = PlaybackGeneration(successorValue)

      bridge._broadcastForTesting(
        .mediaChanged,
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: successorValue
      )
      bridge._broadcastForTesting(
        .seekableChanged(true),
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: successorValue
      )
      bridge._broadcastForTesting(
        .lengthChanged(.seconds(9)),
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: successorValue
      )

      #expect(await drainObserver(of: controller, untilDurationIs: 9000))
      #expect(
        player.generation == outgoing,
        "Player unexpectedly caught up, so this did not exercise the ahead-observer ordering"
      )
      #expect(controller.playbackStateObservation.playbackGeneration == successor)
      #expect(controller.playbackStateObservation.isSeekable)

      // A queued callback from the retired handle may carry the bridge's current
      // media stamp, so generation alone is insufficient. The exact native
      // attachment must reject it while a current-handle sentinel proves the
      // observer drained past it.
      bridge._broadcastForTesting(
        .seekableChanged(false),
        nativeHandleGeneration: nativeHandleGeneration &- 1,
        playbackGeneration: successorValue
      )
      bridge._broadcastForTesting(
        .lengthChanged(.seconds(11)),
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: successorValue
      )

      #expect(await drainObserver(of: controller, untilDurationIs: 11000))
      #expect(
        controller.playbackStateObservation.isSeekable,
        "a retired native handle rewrote the successor's PiP capability"
      )
    }
  }
}
#endif
