@testable import SwiftVLC
import Foundation
import Synchronization
import Testing

/// A seek target, once accepted, is the authoritative timeline.
///
/// Two things used to break that. The native seek result was ignored, so a
/// refused seek still published its target and the observable timeline
/// described a position playback never reached. And the internal event stream
/// is unbounded, so time and position samples produced *before* a seek could
/// still be queued when it was accepted — applying them afterwards snapped the
/// published time back to where playback used to be. While paused there may be
/// no later native clock event to repair that, so the wrong value simply
/// stayed on screen.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerSeekAuthorityTests {
    /// The core regression: a clock sample from before the seek must not
    /// overwrite the accepted target.
    @Test
    func `A clock sample predating an accepted seek does not snap the timeline back`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      // A sample libVLC produced before the seek, still queued.
      let stale = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(3)),
        timelineRevision: player.acceptedTimelineRevision
      )

      try player.seek(to: .seconds(42))
      #expect(player.currentTime == .seconds(42))

      player.handleSourcedEvent(stale)

      #expect(
        player.currentTime == .seconds(42),
        "a pre-seek clock sample overwrote the accepted seek target"
      )
    }

    /// The same guarantee for position, which drives the scrubber.
    @Test
    func `A position sample predating an accepted seek is discarded`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      let stale = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .positionChanged(0.03),
        timelineRevision: player.acceptedTimelineRevision
      )

      try player.seek(to: .seconds(50))
      let published = player.position

      player.handleSourcedEvent(stale)

      #expect(player.position == published, "a pre-seek position sample won over the seek target")
    }

    /// A sample produced *after* the seek is the newer truth and must still be
    /// applied — the filter must not freeze the timeline.
    @Test
    func `A clock sample after an accepted seek still updates the timeline`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      try player.seek(to: .seconds(42))

      let fresh = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(43)),
        timelineRevision: player.acceptedTimelineRevision
      )
      player.handleSourcedEvent(fresh)

      #expect(player.currentTime == .seconds(43))
    }

    /// Rapid seeks: only the newest target survives, and a sample stamped for
    /// the earlier one cannot resurrect it.
    @Test
    func `A superseded seek's clock samples cannot resurrect its target`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      try player.seek(to: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      try player.seek(to: .seconds(80))

      let supersededSample = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(10)),
        timelineRevision: firstRevision
      )
      player.handleSourcedEvent(supersededSample)

      #expect(player.currentTime == .seconds(80))
    }

    /// State transitions must stay lossless: only clock payloads are filtered,
    /// so a stale-stamped transition still reaches the mirror.
    @Test
    func `A stale-stamped state transition is still applied`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      try player.seek(to: .seconds(42))

      let staleTransition = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .stateChanged(.playing),
        timelineRevision: 0
      )
      player.handleSourcedEvent(staleTransition)

      #expect(player.state == .playing, "a one-shot transition was dropped by the clock filter")
    }

    /// A sample carrying the seek's own revision is current, not stale, so it
    /// must be applied. After a fast (keyframe) seek this is the position
    /// playback actually landed on, which is not the requested one.
    ///
    /// This pins the boundary condition of the filter — that the comparison is
    /// `>=` and not `>`.
    @Test
    func `A sample carrying the seek's own revision is applied`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      try player.seek(to: .seconds(42), fast: true)
      let acceptedRevision = player.acceptedTimelineRevision

      let landed = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(40)),
        timelineRevision: acceptedRevision
      )
      player.handleSourcedEvent(landed)

      #expect(
        player.currentTime == .seconds(40),
        "the landed position was discarded as stale; the timeline is stuck on the requested target"
      )
    }

    /// A rejected seek must not consume the timeline: clock samples keep
    /// flowing exactly as they did before the refused request.
    @Test
    func `A rejected seek leaves the accepted timeline revision alone`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)
      let before = player.acceptedTimelineRevision

      // Out of range for the known duration, so validation refuses it.
      #expect(throws: VLCError.self) {
        try player.seek(to: .seconds(5000))
      }

      #expect(player.acceptedTimelineRevision == before)
    }

    /// Loading new media starts a new timeline, so samples from the previous
    /// one cannot update it.
    @Test
    func `A clock sample from the previous media cannot update the new timeline`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(state: .paused, duration: .seconds(100), isSeekable: true)

      let previousGenerationSample = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(7)),
        timelineRevision: player.acceptedTimelineRevision
      )

      try player.load(Media(url: TestMedia.silenceURL))
      player.handleSourcedEvent(previousGenerationSample)

      #expect(
        player.currentTime == .zero,
        "a clock sample from the previous media updated the new one's timeline"
      )
    }

    /// `jump(by:)` is the seek entry point PiP skip controls route through, so
    /// it needs the same protection the absolute paths already have. It is
    /// also the one most exposed to it: a relative jump is issued while
    /// playback is running and clock samples are in flight, rather than from a
    /// settled scrubber drag.
    @Test
    func `A clock sample predating an accepted jump does not snap the timeline back`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      // `jump(by:)` gates on a live session; the intent flag is the
      // synchronous signal that gate reads.
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100),
        isSeekable: true
      )

      // Produced by libVLC before the jump, still queued behind it.
      let stale = SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(10)),
        timelineRevision: player.acceptedTimelineRevision
      )

      #expect(player.jump(by: .seconds(30)))
      #expect(player.currentTime == .seconds(40))

      player.handleSourcedEvent(stale)

      #expect(
        player.currentTime == .seconds(40),
        "a pre-jump clock sample overwrote the accepted jump target"
      )
    }

    /// A refused jump must not consume the reservation, or every later clock
    /// sample would be judged stale against a revision nothing ever adopted
    /// and the published time would freeze.
    @Test
    func `A rejected jump leaves the accepted timeline revision alone`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      // No media, so there is no session to jump in and the call is refused.
      let before = player.acceptedTimelineRevision

      #expect(player.jump(by: .seconds(5)) == false)

      #expect(player.acceptedTimelineRevision == before)
    }

    /// Conversion failure is a typed rejection and never reaches libVLC or
    /// consumes timeline authority.
    @Test
    func `An out-of-range jump offset is rejected before native dispatch`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      let before = player.acceptedTimelineRevision
      var nativeDispatchCount = 0
      player._nativeJumpTimeOverrideForTesting = { _ in
        nativeDispatchCount += 1
        return 0
      }

      let request = player.requestJump(by: .seconds(Int64.max))

      #expect(request.initialOutcome == .rejected)
      #expect(await request.outcome == .rejected)
      #expect(nativeDispatchCount == 0)
      #expect(player.acceptedTimelineRevision == before)
    }

    /// Native dispatch is only the pending state. Ordinary clock samples can
    /// update the mirror, but settlement needs seek end followed by a timer point.
    @Test
    func `An accepted jump settles after its post-seek timer point`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(30))
      let revision = player.acceptedTimelineRevision

      #expect(request.initialOutcome == .pending)
      #expect(player.currentTime == .seconds(10))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(41)),
        timelineRevision: revision
      ))

      #expect(player.currentTime == .seconds(41))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 40000,
        position: 0.4
      )
      await Task.yield()
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      await Task.yield()
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 41000,
        position: 0.41
      )
      for _ in 0..<50 where player.pendingSeekSettlement != nil {
        await Task.yield()
      }

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(41))
      #expect(abs(player.position - 0.41) < 0.000_001)
    }

    /// libVLC permits an unknown clock sentinel for live inputs. That point
    /// proves only that seeking ended, not where the relative jump landed.
    @Test
    func `An unknown post-seek clock does not settle the jump`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(30))
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: -1,
        position: 0.63
      )
      await Task.yield()

      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      #expect(player.currentTime == .seconds(10))

      let token = try #require(player.pendingSeekSettlement?.nativeSeekToken)
      player.nativeSeekDidLand(NativeSeekLanding(
        token: token,
        timeMilliseconds: -1,
        position: 0.63
      ))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 41000,
        position: 0.63
      )
      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(41))
    }

    /// Paused audio has no decoded video frame to produce a watched timer
    /// point. Seek-end therefore reads the native clock outside the callback
    /// and resolves the request without waiting for playback to resume.
    @Test
    func `A paused audio seek settles from its authoritative end read`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeSeekLandingOverrideForTesting = { (40000, 0.4) }

      let request = player.requestJump(by: .seconds(30))
      player.nativeSeekMonitor._noteSeekEndedForTesting()

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(40))
      #expect(abs(player.position - 0.4) < 0.000_001)
    }

    /// Native start callbacks consume command tokens in dispatch order. A
    /// later staged command must never be attributed to an earlier landing.
    @Test
    func `Staged native seek tokens preserve command order`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let deliveries = Mutex<[NativeSeekLanding]>([])
      player.nativeSeekMonitor.setHandler { landing in
        deliveries.withLock { $0.append(landing) }
      }
      let first = player.nativeSeekMonitor.stageCommand()
      let second = player.nativeSeekMonitor.stageCommand()

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 10000,
        position: 0.1
      )
      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )

      let tokens = deliveries.withLock { $0.map(\.token) }
      #expect(tokens == [first, second])
    }

    /// Replacing media on the same native handle gives its time watch a fresh
    /// attachment. A callback already in flight from the outgoing media must
    /// not consume the successor command's token.
    @Test
    func `Media reset quarantines outgoing native seek callbacks`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let deliveries = Mutex<[NativeSeekLanding]>([])
      player.nativeSeekMonitor.setHandler { landing in
        deliveries.withLock { $0.append(landing) }
      }
      let outgoingGeneration = player.nativeSeekMonitor._timelineGenerationForTesting
      _ = player.nativeSeekMonitor.stageCommand()

      player.resetMediaDerivedState()
      let successor = player.nativeSeekMonitor.stageCommand()

      player.nativeSeekMonitor._noteSeekStartedForTesting(
        timelineGeneration: outgoingGeneration
      )
      player.nativeSeekMonitor._noteSeekEndedForTesting(
        timelineGeneration: outgoingGeneration
      )
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 10000,
        position: 0.1,
        timelineGeneration: outgoingGeneration
      )
      let outgoingWasQuarantined = deliveries.withLock { $0.isEmpty }
      #expect(outgoingWasQuarantined)

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 20000,
        position: 0.2
      )

      let tokens = deliveries.withLock { $0.map(\.token) }
      #expect(tokens == [successor])
    }

    /// `load(_:)` has already adopted and reset the wrapper-owned generation
    /// before libVLC's MediaChanged echo reaches the main-actor event lane. A
    /// seek accepted in between belongs to that generation and must survive
    /// the delayed echo.
    @Test
    func `A wrapper media-change echo preserves a newer seek`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let generation = player.sessionGeneration

      let request = player.requestJump(by: .seconds(5))
      player.handleEvent(.mediaChanged, sourcePlaybackGeneration: generation)

      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      player._completePendingSeekForTesting(time: .seconds(15), position: 0.15)
      #expect(await request.outcome == .settled)
    }

    /// Acceptance-only jumps still occupy their native callback slot. A
    /// delayed start for one must not consume the later request's token and
    /// let the legacy landing settle that request against the wrong timeline.
    @Test
    func `A legacy jump cannot steal a later request token`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      #expect(player.jump(by: .seconds(5)))
      let request = player.requestJump(by: .seconds(30))

      // requestJump's deterministic test seam emits one seek-start. It must
      // consume the older legacy slot, so that landing cannot resolve the
      // tracked request.
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 15000,
        position: 0.15
      )
      await Task.yield()
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.nativeSeekMonitor._noteSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 45000,
        position: 0.45
      )

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(45))
    }

    /// Even if a tiny input lands before the C call returns, delivery is deferred
    /// to the main actor until the request has installed its waiter.
    @Test
    func `Synchronous native completion is retained until request registration`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in
        player.nativeSeekMonitor._noteSeekStartedForTesting()
        player.nativeSeekMonitor._noteSeekEndedForTesting()
        player.nativeSeekMonitor._noteTimeUpdatedForTesting(
          timeMilliseconds: 20000,
          position: 0.2
        )
        return 0
      }

      let request = player.requestJump(by: .seconds(10))

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(20))
      #expect(abs(player.position - 0.2) < 0.000_001)
    }

    /// Unknown-duration inputs cannot derive a fraction from the clock. The
    /// native fraction still has to reach observers before the waiter resumes.
    @Test
    func `Native completion publishes position before settlement`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        position: 0.2
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(30))
      player._completePendingSeekForTesting(time: .seconds(41), position: 0.63)

      #expect(await request.outcome == .settled)
      #expect(player.currentTime == .seconds(41))
      #expect(abs(player.position - 0.63) < 0.000_001)
    }

    /// A synchronous callback emitted by the native call belongs to the new
    /// timeline and must not be discarded, but it also cannot prove landing.
    @Test
    func `A clock callback racing native dispatch cannot settle the jump`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100)
      )
      let bridge = player.eventBridge
      let nativeGeneration = bridge.currentNativeHandleGeneration
      let playbackGeneration = player.sessionGeneration
      player._nativeJumpTimeOverrideForTesting = { _ in
        bridge._broadcastForTesting(
          .timeChanged(.seconds(11)),
          nativeHandleGeneration: nativeGeneration,
          playbackGeneration: playbackGeneration
        )
        return 0
      }

      let request = player.requestJump(by: .seconds(30))
      player._nativeJumpTimeOverrideForTesting = nil
      let revision = player.acceptedTimelineRevision
      bridge._broadcastForTesting(
        .stateChanged(.playing),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: playbackGeneration
      )
      for _ in 0..<50 where player.state != .playing {
        await Task.yield()
      }

      #expect(player.state == .playing, "the event-lane sentinel did not drain")
      #expect(player.currentTime == .seconds(11))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: playbackGeneration,
        event: .timeChanged(.seconds(41)),
        timelineRevision: revision
      ))

      #expect(player.currentTime == .seconds(41))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      player._completePendingSeekForTesting(time: .seconds(41), position: 0.41)
      #expect(await request.outcome == .settled)
    }

    /// A stale sample can neither overwrite the target nor falsely discharge
    /// the settlement promise.
    @Test
    func `A pre-jump sample does not settle the request`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10),
        duration: .seconds(100)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let staleRevision = player.acceptedTimelineRevision
      let request = player.requestJump(by: .seconds(5))
      let acceptedRevision = player.acceptedTimelineRevision

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(10)),
        timelineRevision: staleRevision
      ))

      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      #expect(player.currentTime == .seconds(10))

      // Neither an accepted-revision position nor time sample can impersonate
      // libVLC's causal seek end and following native timer point.
      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .positionChanged(0.16),
        timelineRevision: acceptedRevision
      ))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(16)),
        timelineRevision: acceptedRevision
      ))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player._completePendingSeekForTesting(time: .seconds(16), position: 0.16)
      #expect(await request.outcome == .settled)
    }

    /// A terminal event queued before the command cannot terminate a newer
    /// request merely because the main actor applies it after native dispatch.
    @Test
    func `A stale terminal event does not supersede a newer jump`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let staleRevision = player.acceptedTimelineRevision

      let request = player.requestJump(by: .seconds(10))
      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .stateChanged(.stopped),
        timelineRevision: staleRevision
      ))

      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      player._completePendingSeekForTesting(time: .seconds(10))
      #expect(await request.outcome == .settled)
    }

    /// An error callback can enter before a seek and wait in the control lane
    /// until afterwards. Its older revision cannot cancel the newer command.
    @Test
    func `A stale encountered error does not supersede a newer jump`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let staleRevision = player.acceptedTimelineRevision

      let request = player.requestJump(by: .seconds(10))
      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .encounteredError,
        timelineRevision: staleRevision
      ))

      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      player._completePendingSeekForTesting(time: .seconds(20), position: 0.2)
      #expect(await request.outcome == .settled)
    }

    /// Applying the causal landing advances authority beyond callbacks that
    /// entered after dispatch but before the native seek began.
    @Test
    func `A queued pre-landing clock cannot overwrite the settled timeline`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(30))
      let acceptedRevision = player.acceptedTimelineRevision
      player._completePendingSeekForTesting(time: .seconds(40), position: 0.4)
      #expect(await request.outcome == .settled)
      #expect(player.acceptedTimelineRevision > acceptedRevision)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(11)),
        timelineRevision: acceptedRevision
      ))

      #expect(player.currentTime == .seconds(40))
      #expect(abs(player.position - 0.4) < 0.000_001)
    }

    /// Native completion is scoped to the exact wrapper-issued seek token.
    @Test
    func `Settlement ignores a different native seek token`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      let token = try #require(player.pendingSeekSettlement?.nativeSeekToken)

      player._completePendingSeekForTesting(time: .seconds(10), token: token &+ 1)
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player._completePendingSeekForTesting(time: .seconds(10), token: token)
      #expect(await request.outcome == .settled)
    }

    /// Rapid alternating skip controls must give every displaced request an
    /// explicit result while leaving only the newest one able to settle.
    @Test
    func `A newer jump supersedes the previous request`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .buffering,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(50),
        duration: .seconds(100)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let first = player.requestJump(by: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      let second = player.requestJump(by: .seconds(-20))
      let secondRevision = player.acceptedTimelineRevision

      #expect(await first.outcome == .superseded)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(60)),
        timelineRevision: firstRevision
      ))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        playbackGeneration: player.sessionGeneration,
        event: .timeChanged(.seconds(40)),
        timelineRevision: secondRevision
      ))
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player._completePendingSeekForTesting(time: .seconds(40), position: 0.4)
      #expect(await second.outcome == .settled)
      #expect(player.currentTime == .seconds(40))
    }

    /// A rejected replacement changes no native timeline. The previous
    /// accepted request remains authoritative and can still settle normally.
    @Test
    func `A rejected newer jump preserves the previous request`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let first = player.requestJump(by: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      player._nativeJumpTimeOverrideForTesting = { _ in -1 }
      let rejected = player.requestJump(by: .seconds(20))

      #expect(rejected.initialOutcome == .rejected)
      #expect(await rejected.outcome == .rejected)
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)
      #expect(player.acceptedTimelineRevision == firstRevision)

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 10000,
        position: -.infinity
      )
      #expect(await first.outcome == .settled)
    }

    /// Position seeking follows the same transactional replacement rule as a
    /// relative jump: rejection preserves the old request; acceptance owns the
    /// new timeline and only then supersedes it.
    @Test
    func `A position seek supersedes pending work only after native acceptance`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let first = player.requestJump(by: .seconds(10))
      let firstRevision = player.acceptedTimelineRevision
      player._nativeSetPositionOverrideForTesting = { _, _ in -1 }

      #expect(!player.seek(toPosition: PlaybackPosition(0.4)))
      #expect(player.acceptedTimelineRevision == firstRevision)
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }
      #expect(player.seek(toPosition: PlaybackPosition(0.5)))
      #expect(await first.outcome == .superseded)
      #expect(player.acceptedTimelineRevision > firstRevision)
      #expect(player.position == 0.5)
    }

    /// The native return code is authoritative. A refusal is typed and does
    /// not publish either the requested estimate or a new accepted revision.
    @Test
    func `A native-rejected jump leaves the timeline unchanged`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(12),
        duration: .seconds(100)
      )
      player._nativeJumpTimeOverrideForTesting = { _ in -1 }
      let acceptedRevision = player.acceptedTimelineRevision

      let request = player.requestJump(by: .seconds(30))

      #expect(request.initialOutcome == .rejected)
      #expect(await request.outcome == .rejected)
      #expect(player.acceptedTimelineRevision == acceptedRevision)
      #expect(player.currentTime == .seconds(12))
    }

    /// An accepted command that never produces native completion cannot leave an
    /// AVKit completion suspended indefinitely.
    @Test
    func `An accepted jump has a bounded timeout result`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(12),
        duration: .seconds(100),
        position: 0.12
      )
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(30))
      player._expirePendingSeekForTesting()

      #expect(await request.outcome == .timedOut)
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.currentTime == .seconds(12))
      #expect(abs(player.position - 0.12) < 0.000_001)
    }

    /// Media replacement establishes a new generation and makes the outgoing
    /// request explicitly superseded, even if its old event arrives later.
    @Test
    func `A media reset supersedes a pending jump`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      player.resetMediaDerivedState()

      #expect(await request.outcome == .superseded)
    }

    /// Renderer recast establishes a successor playback generation without a
    /// media reset. That generation boundary must terminate the outgoing seek
    /// immediately rather than leaving it to time out.
    @Test
    func `A playback generation change supersedes a pending jump`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      player.sessionGeneration &+= 1

      #expect(await request.outcome == .superseded)
    }

    /// An explicit stop is authoritative immediately; completion does not
    /// wait for libVLC's asynchronous stopped event before discharging a skip.
    @Test
    func `Stopping supersedes a pending jump synchronously`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(10))
      player._nativePlaybackStateOverrideForTesting = .idle
      player.stop()

      #expect(await request.outcome == .superseded)
    }

    /// Cancelling an observer does not cancel or misclassify the shared seek.
    @Test
    func `Cancelling one waiter does not cancel the seek`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }
      let request = player.requestJump(by: .seconds(10))
      let waiter = Task { await request.outcome }

      waiter.cancel()
      await Task.yield()
      #expect(player.pendingSeekSettlement?.resolver.resolvedOutcome == nil)

      player._completePendingSeekForTesting(time: .seconds(10))

      #expect(await waiter.value == .settled)
    }

    /// Relative jumping changes only the timeline; it does not synthesize the
    /// pause/mute transport sequence that previously left PiP playback stuck.
    @Test
    func `A jump preserves pause intent and mute state`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: false,
        currentTime: .seconds(5),
        duration: .seconds(100)
      )
      player.isMuted = true
      player._nativePlaybackStateOverrideForTesting = .paused
      player._nativeJumpTimeOverrideForTesting = { _ in 0 }

      let request = player.requestJump(by: .seconds(5))
      player._completePendingSeekForTesting(time: .seconds(10), position: 0.1)

      #expect(await request.outcome == .settled)
      #expect(player.state == .paused)
      #expect(player.isPlaybackRequestedActive == false)
      #expect(player.isMuted)
    }
  }
}
