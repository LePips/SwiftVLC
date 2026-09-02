#if os(iOS) || os(macOS)
@testable import SwiftVLC
import CoreMedia
import Synchronization
import Testing

@Suite(.tags(.logic, .mainActor))
@MainActor struct PiPPlaybackStateTransitionTests {
  @Test
  func `loading live media invalidates even when duration remains unknown`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let update = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )

    #expect(update.invalidatesPlaybackState)
    #expect(update.requiresLinearPlayback == true)
    assertEffects(of: update, expectedLinearPlayback: true)
  }

  @Test
  func `media replacement ignores stale pre-event player state`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )

    let update = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: Duration.seconds(120).milliseconds,
        isSeekable: true
      )
    )

    #expect(update.invalidatesPlaybackState)
    #expect(update.requiresLinearPlayback == true)
    #expect(state.durationMilliseconds == nil)
    #expect(state.isSeekable == false)
  }

  @Test
  func `seekability payload wins subscriber race and updates linear playback`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let becameSeekable = state.consume(
      .seekableChanged(true),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )
    #expect(becameSeekable.invalidatesPlaybackState)
    #expect(becameSeekable.requiresLinearPlayback == false)
    #expect(state.isSeekable)
    assertEffects(of: becameSeekable, expectedLinearPlayback: false)

    let becameLinear = state.consume(
      .seekableChanged(false),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: true
      )
    )
    #expect(becameLinear.invalidatesPlaybackState)
    #expect(becameLinear.requiresLinearPlayback == true)
    #expect(state.isSeekable == false)
    assertEffects(of: becameLinear, expectedLinearPlayback: true)
  }

  @Test
  func `seekability payload survives following events while player mirror is stale`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let payloadUpdate = state.consume(
      .seekableChanged(true),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )
    #expect(payloadUpdate.invalidatesPlaybackState)
    #expect(payloadUpdate.requiresLinearPlayback == false)

    let whileStale = state.consume(
      .timeChanged(.seconds(1)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )
    #expect(whileStale == PiPController.PlaybackStateUpdate())
    #expect(state.isSeekable)

    let mirrorCaughtUp = state.consume(
      .timeChanged(.seconds(2)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: true
      )
    )
    #expect(mirrorCaughtUp == PiPController.PlaybackStateUpdate())
    #expect(state.isSeekable)
  }

  @Test
  func `media reset survives following events while player mirrors are stale`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )

    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: Duration.seconds(120).milliseconds,
        isSeekable: true
      )
    )
    let whileStale = state.consume(
      .timeChanged(.zero),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: Duration.seconds(120).milliseconds,
        isSeekable: true
      )
    )

    #expect(whileStale == PiPController.PlaybackStateUpdate())
    #expect(state.durationMilliseconds == nil)
    #expect(state.isSeekable == false)
  }

  @Test
  func `duration payload wins subscriber race and invalidates`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )

    let update = state.consume(
      .lengthChanged(.seconds(90)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: nil,
        isSeekable: false
      )
    )

    #expect(update.invalidatesPlaybackState)
    #expect(state.durationMilliseconds == 90000)
    assertEffects(of: update, expectedLinearPlayback: nil)
  }

  @Test
  func `native range query ignores a stale finite Player mirror after live media change`() throws {
    let staleMirrorRange = PiPPlaybackDelegateProxy.playbackTimeRange(
      hasMedia: true,
      duration: .seconds(120)
    )
    #expect(staleMirrorRange.duration.seconds == 120)

    let retainedMedia = try #require(OpaquePointer(bitPattern: 0x1))
    var releaseCount = 0
    let nativeRange = try PiPPlaybackDelegateProxy.playbackTimeRange(
      playerPointer: #require(OpaquePointer(bitPattern: 0x2)),
      getSnapshot: { _ in (retainedMedia, 0) },
      releaseMedia: { media in
        #expect(media == retainedMedia)
        releaseCount += 1
      }
    )

    #expect(nativeRange.isValid)
    #expect(nativeRange.duration.isPositiveInfinity)
    #expect(releaseCount == 1)
  }

  // MARK: - Capability convergence

  /// The regression this issue is about. libVLC does not reliably emit
  /// `MediaPlayerSeekableChanged`, so `Player` repairs seekability by polling.
  /// Reacting only to the raw event left finite seekable VOD pinned to the
  /// conservative media-changed reset: linear playback, no skip controls.
  @Test
  func `Finite seekable VOD converges without a seekable event`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    // `Player` has already processed the media change, so the snapshot holds
    // the reset values under the new generation.
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    let update = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 600_000,
        isSeekable: true
      )
    )

    #expect(update.requiresLinearPlayback == false, "PiP stayed linear for seekable VOD")
    assertEffects(of: update, expectedLinearPlayback: false)
  }

  /// Steady playback can run without another state transition, so convergence
  /// has to be reachable from a clock tick too.
  @Test
  func `Capability converges on a clock tick`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    let update = state.consume(
      .timeChanged(.seconds(5)),
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 600_000,
        isSeekable: true
      )
    )

    #expect(update.requiresLinearPlayback == false)
    assertEffects(of: update, expectedLinearPlayback: false)
  }

  /// **The case that broke my first attempt.** A state transition arriving
  /// before `Player` has processed the media change must not resurrect the
  /// previous media's capability — the generation is what proves the snapshot
  /// is still describing the outgoing media.
  @Test
  func `A stale mirror does not resurrect capability on a state transition`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )
    let stale = PlayerCapabilitySnapshot(
      generation: 1,
      durationMilliseconds: 120_000,
      isSeekable: true
    )
    _ = state.consume(.mediaChanged, capability: stale)

    let update = state.consume(.stateChanged(.opening), capability: stale)

    #expect(update.requiresLinearPlayback == nil, "stale capability was adopted")
    #expect(state.durationMilliseconds == nil)
    #expect(!state.isSeekable)
  }

  /// Once the generation moves past the reset, the same values are the *new*
  /// media's and must be adopted.
  @Test
  func `Capability is adopted once the generation moves on`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: 120_000,
        isSeekable: true
      )
    )

    let update = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 300_000,
        isSeekable: true
      )
    )

    #expect(update.requiresLinearPlayback == false)
    #expect(state.durationMilliseconds == 300_000)
  }

  /// Unseekable live media must stay linear: convergence must not invent
  /// capability the media does not have.
  @Test
  func `Unseekable live media stays linear`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: false
    )
    _ = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    let update = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(generation: 2)
    )

    #expect(update.requiresLinearPlayback == nil, "linear playback was republished")
    assertEffects(of: update, expectedLinearPlayback: nil)
  }

  /// A clock tick on a converged snapshot must produce nothing — invalidating
  /// AVKit at the clock rate would be worse than the bug being fixed.
  @Test
  func `A clock tick on a converged snapshot produces no update`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(600),
      isSeekable: true
    )

    let update = state.consume(
      .timeChanged(.seconds(5)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: 600_000,
        isSeekable: true
      )
    )

    #expect(update == PiPController.PlaybackStateUpdate())
  }

  /// A timeshift window can grow or slide without a new media generation.
  /// Polling must republish the changed finite range without reverting the
  /// already-interactive seek policy.
  @Test
  func `A sliding finite duration converges within one generation`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true
    )

    let update = state.consume(
      .timeChanged(.seconds(30)),
      capability: PlayerCapabilitySnapshot(
        generation: 1,
        durationMilliseconds: 180_000,
        isSeekable: true
      )
    )

    #expect(state.durationMilliseconds == 180_000)
    #expect(state.isSeekable)
    #expect(update.invalidatesPlaybackState)
    #expect(update.requiresLinearPlayback == nil)
    assertEffects(of: update, expectedLinearPlayback: nil)
  }

  @Test
  func `Capability fault injection excludes raw callbacks from the PiP observer`() {
    var suppression = PiPController.PlaybackStateEventSuppression()

    let observesLength = suppression.shouldObserve(
      .lengthChanged(.seconds(30)),
      suppressingRawCapabilityEvents: true
    )
    let observesSeekable = suppression.shouldObserve(
      .seekableChanged(true),
      suppressingRawCapabilityEvents: true
    )
    #expect(!observesLength)
    #expect(!observesSeekable)
    #expect(suppression.suppressedLengthEventCount == 1)
    #expect(suppression.suppressedSeekableEventCount == 1)
    let observesTime = suppression.shouldObserve(
      .timeChanged(.seconds(1)),
      suppressingRawCapabilityEvents: true
    )
    let observesUnsuppressedLength = suppression.shouldObserve(
      .lengthChanged(.seconds(30)),
      suppressingRawCapabilityEvents: false
    )
    #expect(observesTime)
    #expect(observesUnsuppressedLength)
    #expect(suppression.suppressedLengthEventCount == 1)
    #expect(suppression.suppressedSeekableEventCount == 1)
  }

  @Test
  func `Retired native handle cannot restore outgoing media capability`() {
    let envelope = PlayerEventEnvelope(
      event: .seekableChanged(true),
      nativeGeneration: NativePlayerGeneration(1),
      playbackGeneration: PlaybackGeneration(2)
    )

    #expect(
      !PiPController.shouldObservePlaybackStateEnvelope(
        envelope,
        nativeGeneration: NativePlayerGeneration(2),
        authoritativePlaybackGeneration: PlaybackGeneration(2)
      )
    )
  }

  @Test
  func `Successor media change follows bridge authority before Player publication`() {
    let envelope = PlayerEventEnvelope(
      event: .mediaChanged,
      nativeGeneration: NativePlayerGeneration(2),
      playbackGeneration: PlaybackGeneration(2)
    )

    #expect(
      PiPController.shouldObservePlaybackStateEnvelope(
        envelope,
        nativeGeneration: NativePlayerGeneration(2),
        authoritativePlaybackGeneration: PlaybackGeneration(2)
      )
    )
  }

  @Test
  func `Superseded media event on current handle is rejected`() {
    let envelope = PlayerEventEnvelope(
      event: .lengthChanged(.seconds(120)),
      nativeGeneration: NativePlayerGeneration(2),
      playbackGeneration: PlaybackGeneration(1)
    )

    #expect(
      !PiPController.shouldObservePlaybackStateEnvelope(
        envelope,
        nativeGeneration: NativePlayerGeneration(2),
        authoritativePlaybackGeneration: PlaybackGeneration(2)
      )
    )
  }

  /// Drawable-backed active replacement sets media before attaching the new
  /// event manager, so there may be no native `MediaChanged` callback. The
  /// first successor envelope must still reset the outgoing VOD policy.
  @Test
  func `Successor generation resets capability without media changed`() throws {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true,
      playbackGeneration: PlaybackGeneration(1)
    )

    let generationUpdate = state.adoptPlaybackGeneration(
      PlaybackGeneration(2),
      capability: PlayerCapabilitySnapshot(generation: 2)
    )
    let update = try #require(generationUpdate)

    #expect(update.invalidatesPlaybackState)
    #expect(update.requiresLinearPlayback == true)
    #expect(state.durationMilliseconds == nil)
    #expect(!state.isSeekable)
    #expect(
      state.adoptPlaybackGeneration(
        PlaybackGeneration(2),
        capability: PlayerCapabilitySnapshot(generation: 2)
      ) == nil,
      "the same generation published a duplicate reset"
    )
  }

  /// A successor can finish its synchronous load and capability poll before
  /// PiP receives the first sourced envelope for it. The populated snapshot
  /// is already B's truth; waiting for another capability-generation bump
  /// would wait until C and leave B permanently linear.
  @Test
  func `Successor adopts an already populated capability snapshot for its exact generation`() throws {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true,
      playbackGeneration: PlaybackGeneration(1)
    )
    let successor = PlaybackGeneration(2)
    let successorCapability = PlayerCapabilitySnapshot(
      generation: 2,
      playbackGeneration: successor,
      durationMilliseconds: 90000,
      isSeekable: true
    )

    let boundaryCandidate = state.adoptPlaybackGeneration(
      successor,
      capability: successorCapability
    )
    let boundary = try #require(boundaryCandidate)
    #expect(boundary.invalidatesPlaybackState)
    #expect(boundary.requiresLinearPlayback == false)
    #expect(state.durationMilliseconds == 90000)
    #expect(state.isSeekable)
  }

  /// A cold replay creates a new playback generation for the same loaded
  /// media. No media reset or capability setter runs, so the generation
  /// boundary itself must carry the unchanged finite/seekable snapshot into
  /// the successor episode. Otherwise a persistent PiP observer resets on B,
  /// rejects A's snapshot forever, and exposes linear playback with no skips.
  @Test
  func `Cold replay retags unchanged same media capability for persistent PiP`() throws {
    let player = Player(instance: TestInstance.makeAudioOnly())
    player._setStateForTesting(
      state: .stopped,
      nativeState: .stopped,
      duration: .seconds(90),
      isSeekable: true
    )
    player.nativePlayerHasStartedPlayback = true
    player._nativePlayOverrideForTesting = { 0 }

    let retiringGeneration = player.generation
    let retiringCapability = player.capabilitySnapshot.withLock { $0 }
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(90),
      isSeekable: true,
      playbackGeneration: retiringGeneration
    )

    try player.play()

    let successorGeneration = player.generation
    let successorCapability = player.capabilitySnapshot.withLock { $0 }
    #expect(successorGeneration > retiringGeneration)
    #expect(retiringCapability.playbackGeneration == retiringGeneration)
    #expect(successorCapability.playbackGeneration == successorGeneration)
    #expect(successorCapability.generation == retiringCapability.generation)
    #expect(successorCapability.durationMilliseconds == 90000)
    #expect(successorCapability.isSeekable)

    let boundaryCandidate = state.adoptPlaybackGeneration(
      successorGeneration,
      capability: successorCapability
    )
    let boundary = try #require(boundaryCandidate)
    #expect(boundary.invalidatesPlaybackState)
    #expect(boundary.requiresLinearPlayback == false)

    let tick = state.consume(
      .timeChanged(.seconds(1)),
      capability: successorCapability
    )
    #expect(tick.requiresLinearPlayback == nil)
    #expect(state.durationMilliseconds == 90000)
    #expect(state.isSeekable)
  }

  @Test
  func `Observer never adopts capability tagged for a future generation`() throws {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true,
      playbackGeneration: PlaybackGeneration(1)
    )
    let successor = PlaybackGeneration(2)

    let boundaryCandidate = state.adoptPlaybackGeneration(
      successor,
      capability: PlayerCapabilitySnapshot(
        generation: 3,
        playbackGeneration: PlaybackGeneration(3),
        durationMilliseconds: 180_000,
        isSeekable: true
      )
    )
    _ = try #require(boundaryCandidate)
    let update = state.consume(
      .stateChanged(.opening),
      capability: PlayerCapabilitySnapshot(
        generation: 3,
        playbackGeneration: PlaybackGeneration(3),
        durationMilliseconds: 180_000,
        isSeekable: true
      )
    )

    #expect(update.requiresLinearPlayback == nil)
    #expect(state.durationMilliseconds == nil)
    #expect(!state.isSeekable)
  }

  /// Rate, timing, and control envelopes use separate main-actor tasks. If a
  /// rate envelope adopts B first and a timing tick then learns B's finite
  /// capability, the delayed control-lane MediaChanged(B) is only an echo of
  /// the reset already performed at adoption. Resetting again would strand a
  /// paused or quiet input in linear playback with no skip controls.
  @Test
  func `Delayed media changed echo cannot erase capability learned after cross lane adoption`() throws {
    var state = PiPController.PlaybackStateObservationState(
      duration: .seconds(120),
      isSeekable: true,
      playbackGeneration: PlaybackGeneration(1)
    )
    let successor = PlaybackGeneration(2)

    let boundaryCandidate = state.adoptPlaybackGeneration(
      successor,
      capability: PlayerCapabilitySnapshot(generation: 2)
    )
    _ = try #require(boundaryCandidate)
    let learned = state.consume(
      .timeChanged(.seconds(1)),
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 90000,
        isSeekable: true
      )
    )
    #expect(learned.invalidatesPlaybackState)
    #expect(learned.requiresLinearPlayback == false)
    #expect(state.durationMilliseconds == 90000)
    #expect(state.isSeekable)

    let delayedEcho = state.consume(
      .mediaChanged,
      capability: PlayerCapabilitySnapshot(
        generation: 2,
        durationMilliseconds: 90000,
        isSeekable: true
      )
    )

    #expect(delayedEcho == PiPController.PlaybackStateUpdate())
    #expect(state.durationMilliseconds == 90000)
    #expect(state.isSeekable)
  }

  /// A poll that has not learned the length must not undo a length event that
  /// already arrived, or the two sources fight each other.
  @Test
  func `A polled nil duration does not clear a length payload`() {
    var state = PiPController.PlaybackStateObservationState(
      duration: nil,
      isSeekable: true
    )
    _ = state.consume(
      .lengthChanged(.seconds(420)),
      capability: PlayerCapabilitySnapshot(generation: 1, isSeekable: true)
    )

    _ = state.consume(
      .stateChanged(.playing),
      capability: PlayerCapabilitySnapshot(generation: 1, isSeekable: true)
    )

    #expect(
      state.durationMilliseconds == 420_000,
      "a polled nil duration erased a length the media had already reported"
    )
  }

  private func assertEffects(
    of update: PiPController.PlaybackStateUpdate,
    expectedLinearPlayback: Bool?
  ) {
    var invalidationCount = 0
    var linearPlaybackValues: [Bool] = []

    PiPController.applyPlaybackStateUpdate(
      update,
      setRequiresLinearPlayback: { linearPlaybackValues.append($0) },
      invalidatePlaybackState: { invalidationCount += 1 }
    )

    #expect(invalidationCount == 1)
    #expect(linearPlaybackValues == expectedLinearPlayback.map { [$0] } ?? [])
  }
}
#endif
