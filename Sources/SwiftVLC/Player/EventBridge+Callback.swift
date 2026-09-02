// swiftlint:disable file_length
import CLibVLC
import Synchronization

struct SourcedPlayerEvent: Sendable {
  let nativeHandleGeneration: UInt64
  let playbackGeneration: UInt64
  let event: PlayerEvent
  /// The timeline revision current when libVLC emitted this event.
  ///
  /// An accepted seek advances the revision, so a clock sample produced
  /// before it carries a lower value and can be discarded instead of
  /// overwriting the seek target. Defaults to zero, which is never newer
  /// than an accepted seek, so a directly-constructed event is treated as
  /// pre-seek rather than silently authoritative.
  let timelineRevision: UInt64
  /// External-seek ownership frozen when the native callback entered. Direct
  /// unit construction may omit it; every real EventBridge callback carries
  /// one and is therefore immune to MainActor reordering across seek drain.
  let nativeSeekEmissionStamp: NativeSeekEmissionStamp?
  /// Playback-control ordering captured in the same callback-entry critical
  /// section as `playbackGeneration`. `nil` is reserved for directly-created
  /// test values that intentionally retain the legacy, unstamped behavior.
  let lifecycleControlEpoch: UInt64?

  init(
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64,
    event: PlayerEvent,
    timelineRevision: UInt64 = 0,
    nativeSeekEmissionStamp: NativeSeekEmissionStamp? = nil,
    lifecycleControlEpoch: UInt64? = nil
  ) {
    self.nativeHandleGeneration = nativeHandleGeneration
    self.playbackGeneration = playbackGeneration
    self.event = event
    self.timelineRevision = timelineRevision
    self.nativeSeekEmissionStamp = nativeSeekEmissionStamp
    self.lifecycleControlEpoch = lifecycleControlEpoch
  }
}

/// Exact callback-entry provenance retained when event detachment wins the
/// race with an EOS callback's ordered `Stopped` transition.
struct RetiredNaturalEndEmission: Sendable {
  let nativeHandleGeneration: UInt64
  let playbackGeneration: UInt64
  let timelineRevision: UInt64
  let nativeSeekEmissionStamp: NativeSeekEmissionStamp
  let lifecycleControlEpoch: UInt64
}

/// One ordered input to the Player observable mirror.
///
/// Effective-rate resolutions cannot live in `PlayerEvent` without breaking
/// exhaustive switches compiled against the stable enum. Keeping them in the
/// same private broadcaster still preserves native callback order relative to
/// media changes and every other mirrored event.
///
/// This relies narrowly on the production boundary that matters here:
/// `MediaChanged` and the patched effective-rate notification are both
/// `vlc_player_cbs` callbacks invoked while the same `vlc_player_t` lock is
/// held. They cannot overlap for one player. `Broadcaster` is thread-safe but
/// intentionally does not impose an order on concurrent producers because it
/// yields outside its mutex. The pinned-source proof for that native boundary
/// lives in `scripts/patches/validation/0031-effective-playback-rate-event-provenance.md`.
enum SourcedPlayerSignal: Sendable {
  case event(SourcedPlayerEvent)
  case effectivePlaybackRateResolution(EffectivePlaybackRateResolution)
}

/// Immutable identity and shared fan-out context for one native attachment.
/// A fresh retained token is passed to libVLC on every handle replacement;
/// callbacks can therefore never acquire a successor's generation by reading
/// mutable shared state after they were emitted by a predecessor.
final class EventBridgeCallbackAttachment: Sendable {
  let context: EventBridgeCallbackContext
  let nativeHandleGeneration: UInt64
  private let active: Mutex<Bool>

  init(
    context: EventBridgeCallbackContext,
    nativeHandleGeneration: UInt64,
    active: Bool = true
  ) {
    self.context = context
    self.nativeHandleGeneration = nativeHandleGeneration
    self.active = Mutex(active)
  }

  var isActive: Bool {
    active.withLock { $0 }
  }

  func activate() {
    active.withLock { $0 = true }
  }
}

/// Sendable terminal evidence extracted from the C event before entering the
/// callback authorities. Pointer identity is represented as an integer so the
/// native event itself never escapes into a `@Sendable` critical section.
enum NativeTerminalCallbackFact: Sendable {
  case mediaStopping(mediaIdentity: UInt?, engineCause: PlaybackTerminalCause)
  case encounteredError(PlaybackFailureKind)
  case stopped
}

/// Lifecycle evidence extracted from the C payload before entering any
/// mutable authority. Media identity is an integer because the native event
/// must not escape into a `@Sendable` critical section.
enum NativeLifecycleCallbackFact: Sendable {
  case mediaChanged(mediaIdentity: UInt?)
  case currentGenerationProgress
  case terminal(NativeTerminalCallbackFact)
  case other
}

// The lifecycle authority intentionally lives in one lock-owning type so its
// invariants cannot be split across independently synchronized helpers.
// swiftlint:disable:next type_body_length
final class EventBridgeCallbackContext: Sendable {
  private let events = Broadcaster<PlayerEvent>(defaultBufferSize: 64)
  private let eventEnvelopes = Broadcaster<PlayerEventEnvelope>(defaultBufferSize: 64)
  private let sourcedEvents = Broadcaster<SourcedPlayerEvent>(defaultBufferSize: 64)
  private let sourcedPlayerSignals = Broadcaster<SourcedPlayerSignal>(defaultBufferSize: 64)
  private let effectivePlaybackRateResolutions =
    Broadcaster<EffectivePlaybackRateResolution>(defaultBufferSize: 16)
  private let terminalOutcomes = Broadcaster<PlaybackTerminalOutcome>(defaultBufferSize: 16)
  private struct TerminalOutcomePublicationState: Sendable {
    var pending: [UInt64: PlaybackTerminalOutcome] = [:]
    var isPublishing = false
  }

  /// Outcome creation happens under playback lifecycle, while subscriber
  /// delivery must not. This tiny publisher gate preserves generation order
  /// even when a later finalizer leaves lifecycle before an earlier callback
  /// thread reaches its broadcast call.
  private let terminalOutcomePublication = Mutex(TerminalOutcomePublicationState())
  /// Stamped onto every sourced event so the consumer can tell clock samples
  /// that predate an accepted seek from ones that follow it. Lives here
  /// because the stamp has to be taken on libVLC's thread, at emission.
  private let timelineRevision = Mutex<UInt64>(0)
  private let nativeSeekEmissionAuthority: NativeSeekEmissionAuthority
  struct TimelineSnapshot: Sendable {
    var time: Duration = .zero
    var duration: Duration?
    var position: Double = 0
    var bufferFill: Float = 0
    var activeVideoOutputs = 0
    var timelineRevision: UInt64 = 0
    var timelineEmissionSequence: UInt64 = 0

    var publicValue: PlaybackFinalTimeline {
      PlaybackFinalTimeline(
        time: time,
        duration: duration,
        position: position,
        bufferFill: bufferFill,
        activeVideoOutputs: activeVideoOutputs
      )
    }
  }

  /// Bounded, callback-entry-readable mirror of committed timeline state.
  ///
  /// Terminal entry and wrapper-originated lifecycle/timeline mutations use
  /// `nativeSeekEmissionAuthority -> playbackLifecycle -> state`. A native
  /// event which already reserved its emission order may finish publishing via
  /// `playbackLifecycle -> state`; it never reacquires native authority. No
  /// path acquires these locks in reverse.
  private final class TerminalTimelineAuthority: Sendable {
    /// Lifecycle retains the ending generation plus a small successor window.
    /// Match the existing 32-generation outcome-retention horizon explicitly;
    /// terminal capture therefore never grows with clock-event count.
    private static let maximumRetainedGenerations = 33

    private let state = Mutex<[UInt64: TimelineSnapshot]>([:])

    func capture() -> TerminalTimelineCheckpoint {
      state.withLock { TerminalTimelineCheckpoint(snapshots: $0) }
    }

    func store(_ snapshot: TimelineSnapshot, generation: UInt64) {
      state.withLock { snapshots in
        snapshots[generation] = snapshot
        guard snapshots.count > Self.maximumRetainedGenerations else { return }
        let retained = Set(
          snapshots.keys.sorted().suffix(Self.maximumRetainedGenerations)
        )
        snapshots = snapshots.filter { retained.contains($0.key) }
      }
    }

    func retain(generationsAtLeast generation: UInt64) {
      state.withLock { snapshots in
        snapshots = snapshots.filter { $0.key >= generation }
      }
    }
  }

  struct TerminalTimelineCheckpoint: Sendable {
    let snapshots: [UInt64: TimelineSnapshot]
  }

  struct NativeCallbackTimelineEntry: Sendable {
    let native: NativeTimelineCallbackEntry
    let timelineRevision: UInt64
    let playbackGeneration: UInt64
    let lifecycleControlEpoch: UInt64
    let terminalReservation: TerminalCallbackReservation?
    let lifecycleOutcome: PlaybackTerminalOutcome?
  }

  private struct NativeCallbackLifecycleClaim: Sendable {
    let timelineRevision: UInt64
    let playbackGeneration: UInt64
    let lifecycleControlEpoch: UInt64
    let terminalReservation: TerminalCallbackReservation?
    let lifecycleOutcome: PlaybackTerminalOutcome?
  }

  /// The first terminal callback to enter for a playback generation freezes
  /// all terminal identity here. Competing wrapper/external finalizers consume
  /// this exact value instead of re-reading mutable lifecycle state.
  struct TerminalCallbackReservation: Sendable {
    let playbackGeneration: UInt64
    let nativeHandleGeneration: UInt64
    let cause: PlaybackTerminalCause
    let timelineSnapshot: TimelineSnapshot
  }

  private struct PlaybackLifecycleState: Sendable {
    var currentGeneration: UInt64 = 0
    var currentMediaIdentity: UInt?
    var currentNativeHandleGeneration: UInt64 = 1
    /// Playback start is monotonic for both identities. A stopped list-driven
    /// handle is still used, and a later media generation on that handle is
    /// independently unstarted until an accepted play or Opening callback.
    var startedNativeHandleGeneration: UInt64?
    var startedPlaybackGeneration: UInt64?
    var mediaGenerations: [UInt: UInt64] = [:]
    /// Wrapper-initiated `set_media` calls echo through `MediaChanged`. This
    /// token distinguishes that echo from an external change which happens to
    /// reuse the same media pointer.
    var pendingWrapperMediaChangedGeneration: UInt64?
    /// Retired generations awaiting their ordered `MediaStopping` callback
    /// when the successor reuses the exact same retained media pointer.
    var retiredMediaGenerations: [UInt: [UInt64]] = [:]
    var snapshots: [UInt64: TimelineSnapshot] = [:]
    var terminalIntents: [UInt64: PlaybackTerminalCause] = [:]
    /// Recent frozen outcomes retained for synchronous generation-scoped
    /// attribution (for example a late PiP stop). Bounded in `makeOutcome` so
    /// long-running playlist players do not accumulate one entry per item.
    var terminalCauses: [UInt64: PlaybackTerminalCause] = [:]
    /// Callback-entry reservations waiting for exactly one finalizer. Bounded
    /// to the same recent-generation horizon as frozen terminal causes.
    var terminalReservations: [UInt64: TerminalCallbackReservation] = [:]
    var lastEmittedGeneration: UInt64 = 0
    var pendingStoppedGeneration: UInt64?
    /// A deferred drawable-media load has committed this Swift generation,
    /// but intentionally has not installed it on the retiring native handle.
    /// Every callback from the still-attached handle remains owned by the
    /// exact prior generation until `EventBridge.reattach(to:)` clears both.
    var dormantSuccessorGeneration: UInt64?
    var dormantRetiringGeneration: UInt64?
    /// Natural-end delivery deferred across handle replacement until Player's
    /// pointer/lifetime/session transaction is fully committed.
    var pendingNaturalEndEmission: RetiredNaturalEndEmission?
    /// Monotonic barrier separating callbacks emitted before and after an
    /// explicit transport boundary on the same playback generation.
    var lifecycleControlEpoch: UInt64 = 0
    /// A stop quarantine remains active for its exact generation until a new
    /// generation is adopted or a native Play attempt is accepted.
    var explicitStopGeneration: UInt64?
    var nextRecastLeaseID: UInt64 = 0
    var nextRecastMutationPermitID: UInt64 = 0
    var activeRecastLease: RecastLeaseIdentity?
    var activeRecastMutationPermit: RecastMutationPermitIdentity?
  }

  private struct RecastLeaseIdentity: Equatable, Sendable {
    let id: UInt64
    let playbackGeneration: UInt64
    let nativeHandleGeneration: UInt64
    let ownershipEpoch: UInt64
  }

  private struct RecastMutationPermitIdentity: Equatable, Sendable {
    let id: UInt64
    let lease: RecastLeaseIdentity
  }

  private let playbackLifecycle = Mutex(PlaybackLifecycleState())
  private let terminalTimelineAuthority = TerminalTimelineAuthority()
  let endCoordinator: PlaybackEndCoordinator
  #if DEBUG
  private let nativeEventCallbackBeforePlaybackClaimHook = Mutex<(@Sendable () -> Void)?>(nil)
  private let nativeEventCallbackAfterNativeReservationHook = Mutex<(@Sendable () -> Void)?>(nil)
  private let nativeEventCallbackEntryHook = Mutex<(@Sendable () -> Void)?>(nil)
  #endif

  init(
    endCoordinator: PlaybackEndCoordinator,
    nativeSeekEmissionAuthority: NativeSeekEmissionAuthority
  ) {
    self.endCoordinator = endCoordinator
    self.nativeSeekEmissionAuthority = nativeSeekEmissionAuthority
  }

  func makeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEvent) -> Bool)?
  ) -> AsyncStream<PlayerEvent> {
    events.subscribe(policy: policy, filter: filter)
  }

  func makeSourcedStream(policy: EventBufferingPolicy) -> AsyncStream<SourcedPlayerEvent> {
    sourcedEvents.subscribe(policy: policy)
  }

  func makeSourcedPlayerSignalStream(
    policy: EventBufferingPolicy
  ) -> AsyncStream<SourcedPlayerSignal> {
    sourcedPlayerSignals.subscribe(policy: policy)
  }

  func makeEffectivePlaybackRateResolutionStream()
    -> AsyncStream<EffectivePlaybackRateResolution> {
    effectivePlaybackRateResolutions.subscribe(policy: .unbounded)
  }

  func makeEnvelopeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEventEnvelope) -> Bool)?
  ) -> AsyncStream<PlayerEventEnvelope> {
    eventEnvelopes.subscribe(policy: policy, filter: filter)
  }

  func makeTerminalOutcomeStream() -> AsyncStream<PlaybackTerminalOutcome> {
    terminalOutcomes.subscribe(policy: .unbounded)
  }

  func terminalCause(for playbackGeneration: UInt64) -> PlaybackTerminalCause? {
    playbackLifecycle.withLock { $0.terminalCauses[playbackGeneration] }
  }

  var currentNativeHandleHasStartedPlayback: Bool {
    playbackLifecycle.withLock { state in
      state.startedNativeHandleGeneration == state.currentNativeHandleGeneration
    }
  }

  var currentPlaybackGenerationHasStartedPlayback: Bool {
    playbackLifecycle.withLock { state in
      state.startedPlaybackGeneration == state.currentGeneration
    }
  }

  /// Records native acceptance before callback delivery. This is monotonic for
  /// the exact handle and playback generation and therefore remains true after
  /// stopped/error, including when playback was driven by MediaListPlayer.
  func recordAcceptedPlaybackStart(
    playbackGeneration: UInt64,
    nativeHandleGeneration: UInt64
  ) {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard
          playbackGeneration == state.currentGeneration,
          nativeHandleGeneration == state.currentNativeHandleGeneration
        else { return }
        state.startedNativeHandleGeneration = nativeHandleGeneration
        state.startedPlaybackGeneration = playbackGeneration
      }
    }
  }

  func commitRecastReplacementIfCurrent(
    expectation: RecastReplacementExpectation,
    successorPlaybackGeneration: UInt64,
    successorNativeHandleGeneration: UInt64
  ) -> RecastReplacementCommitResult {
    let result = nativeSeekEmissionAuthority.withCallbackOrderingSnapshot { latest in
      self.playbackLifecycle.withLock { state -> (
        RecastReplacementCommitResult,
        PlaybackTerminalOutcome?
      ) in
        guard
          state.currentGeneration == expectation.playbackGeneration,
          state.currentNativeHandleGeneration == expectation.nativeHandleGeneration,
          state.lifecycleControlEpoch == expectation.lifecycleControlEpoch,
          state.currentMediaIdentity == expectation.mediaIdentity,
          expectation.playbackGeneration < UInt64.max,
          expectation.nativeHandleGeneration < UInt64.max,
          successorPlaybackGeneration == expectation.playbackGeneration + 1,
          successorNativeHandleGeneration == expectation.nativeHandleGeneration + 1
        else {
          return ((.interrupted(.superseded)), nil)
        }
        if
          let interruption = self.recastInterruption(
            generation: expectation.playbackGeneration,
            in: state
          ) {
          return ((.interrupted(interruption)), nil)
        }

        self.mergeNativeTimelineCallbackEmission(
          latest,
          playbackGeneration: expectation.playbackGeneration,
          in: &state
        )
        let outgoingTimeline = (state.snapshots[expectation.playbackGeneration]
          ?? TimelineSnapshot()).publicValue
        let outcome = self.makeOutcome(
          in: &state,
          generation: expectation.playbackGeneration,
          cause: .replacement,
          nativeHandleGeneration: expectation.nativeHandleGeneration
        )

        state.currentGeneration = successorPlaybackGeneration
        self.advanceLifecycleControlEpoch(in: &state)
        state.explicitStopGeneration = nil
        state.currentMediaIdentity = expectation.mediaIdentity
        state.pendingWrapperMediaChangedGeneration = successorPlaybackGeneration
        if let identity = expectation.mediaIdentity {
          state.mediaGenerations[identity] = successorPlaybackGeneration
        }
        let successorSnapshot = TimelineSnapshot()
        state.snapshots[successorPlaybackGeneration] = successorSnapshot
        self.terminalTimelineAuthority.store(
          successorSnapshot,
          generation: successorPlaybackGeneration
        )

        // From this point until old-listener detach returns, every active token
        // is the retiring handle. Route all of its callbacks to the frozen
        // predecessor even though the successor carries the same media.
        state.dormantSuccessorGeneration = successorPlaybackGeneration
        state.dormantRetiringGeneration = expectation.playbackGeneration
        state.currentNativeHandleGeneration = successorNativeHandleGeneration
        precondition(state.nextRecastLeaseID < UInt64.max, "Recast lease exhausted")
        state.nextRecastLeaseID += 1
        let identity = RecastLeaseIdentity(
          id: state.nextRecastLeaseID,
          playbackGeneration: successorPlaybackGeneration,
          nativeHandleGeneration: successorNativeHandleGeneration,
          ownershipEpoch: expectation.ownershipEpoch
        )
        state.activeRecastLease = identity
        state.activeRecastMutationPermit = nil
        return ((.committed(RecastReplacementLease(
          id: identity.id,
          playbackGeneration: identity.playbackGeneration,
          nativeHandleGeneration: identity.nativeHandleGeneration,
          ownershipEpoch: identity.ownershipEpoch,
          outgoingTimeline: outgoingTimeline
        ))), outcome)
      }
    }
    if result.1 != nil {
      publishPendingTerminalOutcomes()
    }
    return result.0
  }

  func reserveRecastMutation(
    for lease: RecastReplacementLease
  ) -> RecastMutationReservation {
    nativeSeekEmissionAuthority.withCallbackOrderingSnapshot { latest in
      self.playbackLifecycle.withLock { state in
        guard
          self.recastLeaseIdentity(for: lease) == state.activeRecastLease,
          state.currentGeneration == lease.playbackGeneration,
          state.currentNativeHandleGeneration == lease.nativeHandleGeneration
        else { return .interrupted(.superseded) }
        self.mergeNativeTimelineCallbackEmission(
          latest,
          playbackGeneration: lease.playbackGeneration,
          in: &state
        )
        if
          let interruption = self.recastInterruption(
            generation: lease.playbackGeneration,
            in: state
          ) {
          state.activeRecastLease = nil
          return .interrupted(interruption)
        }
        precondition(
          state.nextRecastMutationPermitID < UInt64.max,
          "Recast mutation permit exhausted"
        )
        guard state.activeRecastMutationPermit == nil else {
          return .interrupted(.superseded)
        }
        state.nextRecastMutationPermitID += 1
        let permit = RecastMutationPermit(
          id: state.nextRecastMutationPermitID,
          lease: lease
        )
        state.activeRecastMutationPermit = RecastMutationPermitIdentity(
          id: permit.id,
          lease: self.recastLeaseIdentity(for: permit.lease)
        )
        return .permitted(permit)
      }
    }
  }

  func currentRecastInterruption(
    for lease: RecastReplacementLease
  ) -> RecastTransactionInterruption? {
    playbackLifecycle.withLock { state in
      guard
        recastLeaseIdentity(for: lease) == state.activeRecastLease,
        state.currentGeneration == lease.playbackGeneration,
        state.currentNativeHandleGeneration == lease.nativeHandleGeneration
      else { return .superseded }
      return recastInterruption(generation: lease.playbackGeneration, in: state)
    }
  }

  func finishRecastMutation(
    _ permit: RecastMutationPermit
  ) -> RecastTransactionInterruption? {
    nativeSeekEmissionAuthority.withCallbackOrderingSnapshot { latest in
      self.playbackLifecycle.withLock { state in
        let permitIdentity = RecastMutationPermitIdentity(
          id: permit.id,
          lease: self.recastLeaseIdentity(for: permit.lease)
        )
        guard state.activeRecastMutationPermit == permitIdentity else {
          return .superseded
        }
        state.activeRecastMutationPermit = nil
        guard
          self.recastLeaseIdentity(for: permit.lease) == state.activeRecastLease,
          state.currentGeneration == permit.lease.playbackGeneration,
          state.currentNativeHandleGeneration == permit.lease.nativeHandleGeneration
        else { return .superseded }
        self.mergeNativeTimelineCallbackEmission(
          latest,
          playbackGeneration: permit.lease.playbackGeneration,
          in: &state
        )
        if
          let interruption = self.recastInterruption(
            generation: permit.lease.playbackGeneration,
            in: state
          ) {
          state.activeRecastLease = nil
          return interruption
        }
        return nil
      }
    }
  }

  /// Makes the final `.settled` decision and relinquishes mutation authority
  /// in the same critical section. A terminal cause can therefore be either
  /// before this decision or after it, never hidden between check and return.
  func settleRecast(
    _ lease: RecastReplacementLease
  ) -> RecastTransactionInterruption? {
    nativeSeekEmissionAuthority.withCallbackOrderingSnapshot { latest in
      self.playbackLifecycle.withLock { state in
        guard
          self.recastLeaseIdentity(for: lease) == state.activeRecastLease,
          state.currentGeneration == lease.playbackGeneration,
          state.currentNativeHandleGeneration == lease.nativeHandleGeneration,
          state.activeRecastMutationPermit == nil
        else { return .superseded }
        self.mergeNativeTimelineCallbackEmission(
          latest,
          playbackGeneration: lease.playbackGeneration,
          in: &state
        )
        let interruption = self.recastInterruption(
          generation: lease.playbackGeneration,
          in: state
        )
        state.activeRecastLease = nil
        return interruption
      }
    }
  }

  func abandonRecast(_ lease: RecastReplacementLease) {
    playbackLifecycle.withLock { state in
      guard recastLeaseIdentity(for: lease) == state.activeRecastLease else { return }
      state.activeRecastLease = nil
      if state.activeRecastMutationPermit?.lease == recastLeaseIdentity(for: lease) {
        state.activeRecastMutationPermit = nil
      }
    }
  }

  private func recastLeaseIdentity(
    for lease: RecastReplacementLease
  ) -> RecastLeaseIdentity {
    RecastLeaseIdentity(
      id: lease.id,
      playbackGeneration: lease.playbackGeneration,
      nativeHandleGeneration: lease.nativeHandleGeneration,
      ownershipEpoch: lease.ownershipEpoch
    )
  }

  private func recastInterruption(
    generation: UInt64,
    in state: PlaybackLifecycleState
  ) -> RecastTransactionInterruption? {
    if let reservation = state.terminalReservations[generation] {
      return .terminal(reservation.cause)
    }
    if
      let cause = state.terminalCauses[generation]
      ?? state.terminalIntents[generation] {
      return .terminal(cause)
    }
    if state.explicitStopGeneration == generation {
      return .terminal(.requestedStop)
    }
    if generation <= state.lastEmittedGeneration {
      return .terminal(.unknownNativeStop)
    }
    return nil
  }

  func synchronizePlaybackGeneration(
    _ generation: UInt64,
    media: OpaquePointer?,
    nativeHandleGeneration: UInt64,
    retiringNativeHandle: Bool,
    expectRetiringHandleStopped: Bool
  ) -> UInt64 {
    let mediaIdentity = Self.identity(of: media)
    let result = nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
        let outgoing = state.currentGeneration
        let outgoingIdentity = state.currentMediaIdentity
        let outcome = self.makeOutcome(
          in: &state,
          generation: outgoing,
          cause: state.terminalIntents[outgoing] ?? .replacement,
          nativeHandleGeneration: nativeHandleGeneration
        )
        precondition(state.currentGeneration < UInt64.max, "Playback generation exhausted")
        let adoptedGeneration = max(generation, state.currentGeneration + 1)
        state.currentGeneration = adoptedGeneration
        self.advanceLifecycleControlEpoch(in: &state)
        state.explicitStopGeneration = nil
        if retiringNativeHandle, outgoing > 0 {
          // Deferred drawable-media replacement stops the still-attached old
          // handle only after committing the successor in Swift. libVLC
          // normally emits MediaStopping first, but every callback in the
          // teardown tail still describes the native media that preceded the
          // dormant successor. Preserve the original retiring generation
          // across repeated deferred loads on the same un-replaced handle.
          let retiringGeneration = state.dormantRetiringGeneration ?? outgoing
          state.dormantSuccessorGeneration = adoptedGeneration
          state.dormantRetiringGeneration = retiringGeneration
          if expectRetiringHandleStopped {
            state.pendingStoppedGeneration = retiringGeneration
          }
        }
        state.currentMediaIdentity = mediaIdentity
        state.pendingWrapperMediaChangedGeneration = adoptedGeneration
        if let identity = state.currentMediaIdentity {
          if
            !retiringNativeHandle,
            outcome != nil,
            outgoing > 0,
            identity == outgoingIdentity {
            state.retiredMediaGenerations[identity, default: []].append(outgoing)
          }
          state.mediaGenerations[identity] = adoptedGeneration
        }
        let snapshot = TimelineSnapshot()
        state.snapshots[adoptedGeneration] = snapshot
        self.terminalTimelineAuthority.store(snapshot, generation: adoptedGeneration)
        return (adoptedGeneration, outcome)
      }
    }
    if result.1 != nil {
      publishPendingTerminalOutcomes()
    }
    return result.0
  }

  func beginPlaybackGeneration(
    _ generation: UInt64,
    media: OpaquePointer?,
    nativeHandleGeneration: UInt64
  ) -> UInt64 {
    let mediaIdentity = Self.identity(of: media)
    let result = nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
        let outgoing = state.currentGeneration
        let outcome = self.makeOutcome(
          in: &state,
          generation: outgoing,
          cause: state.terminalIntents[outgoing] ?? .replacement,
          nativeHandleGeneration: nativeHandleGeneration
        )
        precondition(state.currentGeneration < UInt64.max, "Playback generation exhausted")
        let adoptedGeneration = max(generation, state.currentGeneration + 1)
        state.currentGeneration = adoptedGeneration
        self.advanceLifecycleControlEpoch(in: &state)
        state.explicitStopGeneration = nil
        state.currentMediaIdentity = mediaIdentity
        state.pendingWrapperMediaChangedGeneration = nil
        if let identity = state.currentMediaIdentity {
          state.mediaGenerations[identity] = adoptedGeneration
        }
        let snapshot = TimelineSnapshot()
        state.snapshots[adoptedGeneration] = snapshot
        self.terminalTimelineAuthority.store(snapshot, generation: adoptedGeneration)
        return (adoptedGeneration, outcome)
      }
    }
    if result.1 != nil {
      publishPendingTerminalOutcomes()
    }
    return result.0
  }

  func markRequestedStop(playbackGeneration: UInt64) {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard playbackGeneration > state.lastEmittedGeneration else { return }
        if
          playbackGeneration == state.currentGeneration,
          state.explicitStopGeneration != playbackGeneration {
          self.advanceLifecycleControlEpoch(in: &state)
          state.explicitStopGeneration = playbackGeneration
        }
        state.terminalIntents[playbackGeneration] = .requestedStop
        state.pendingStoppedGeneration = playbackGeneration
        // An explicit stop applies to the session the caller can currently see.
        // Prefer it over an unresolved same-pointer replacement callback; a late
        // retiring callback is harmless because this generation is now ending
        // too, while attributing the requested stop to the retired generation
        // would leave the current one without an outcome.
        if
          playbackGeneration == state.currentGeneration,
          let identity = state.currentMediaIdentity {
          state.retiredMediaGenerations[identity] = nil
        }
      }
    }
  }

  /// Establishes the current generation's Stop quarantine and, when that
  /// generation is eligible to emit a terminal outcome, records its requested
  /// cause in the same callback-ordering critical section. Generation zero is
  /// a valid externally driven initial episode even though it is also the
  /// terminal-outcome sentinel, so it still receives the quarantine.
  func beginRequestedStopBarrier(playbackGeneration: UInt64) {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard playbackGeneration == state.currentGeneration else { return }
        if state.explicitStopGeneration != playbackGeneration {
          self.advanceLifecycleControlEpoch(in: &state)
          state.explicitStopGeneration = playbackGeneration
        }
        guard playbackGeneration > state.lastEmittedGeneration else { return }
        state.terminalIntents[playbackGeneration] = .requestedStop
        state.pendingStoppedGeneration = playbackGeneration
        if let identity = state.currentMediaIdentity {
          state.retiredMediaGenerations[identity] = nil
        }
      }
    }
  }

  /// Creates the synchronous control boundary for `Player.stop()`. Terminal
  /// intent is recorded separately because an already-stopped native player
  /// has no new terminal callback to classify, while its active-state
  /// quarantine is still required immediately.
  func beginExplicitStopBarrier(playbackGeneration: UInt64) {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard playbackGeneration == state.currentGeneration else { return }
        guard state.explicitStopGeneration != playbackGeneration else { return }
        self.advanceLifecycleControlEpoch(in: &state)
        state.explicitStopGeneration = playbackGeneration
      }
    }
  }

  struct PlaybackStartAttempt: Sendable {
    let playbackGeneration: UInt64
    let lifecycleControlEpoch: UInt64
    let restoresExplicitStopOnRejection: Bool
  }

  /// Establishes callback ordering immediately before entering
  /// `libvlc_media_player_play`. This is an attempt until the native return
  /// value is known: rejection advances the epoch again and restores any stop
  /// quarantine, making callbacks emitted by the failed call stale.
  func beginPlaybackStartAttempt(
    playbackGeneration: UInt64
  ) -> PlaybackStartAttempt? {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard playbackGeneration == state.currentGeneration else { return nil }
        let restoresExplicitStop = state.explicitStopGeneration == playbackGeneration
        self.advanceLifecycleControlEpoch(in: &state)
        state.explicitStopGeneration = nil
        return PlaybackStartAttempt(
          playbackGeneration: playbackGeneration,
          lifecycleControlEpoch: state.lifecycleControlEpoch,
          restoresExplicitStopOnRejection: restoresExplicitStop
        )
      }
    }
  }

  func finishPlaybackStartAttempt(
    _ attempt: PlaybackStartAttempt?,
    accepted: Bool
  ) {
    guard let attempt, !accepted else { return }
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard
          state.currentGeneration == attempt.playbackGeneration,
          state.lifecycleControlEpoch == attempt.lifecycleControlEpoch
        else { return }
        self.advanceLifecycleControlEpoch(in: &state)
        if attempt.restoresExplicitStopOnRejection {
          state.explicitStopGeneration = attempt.playbackGeneration
        }
      }
    }
  }

  /// Clears an existing Stop quarantine after an external owner (notably
  /// `MediaListPlayer`) has already accepted a playback-enabling command.
  /// No epoch is spent when no quarantine exists.
  func acceptExternalPlaybackActivation(playbackGeneration: UInt64) {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard
          playbackGeneration == state.currentGeneration,
          state.explicitStopGeneration == playbackGeneration
        else { return }
        self.advanceLifecycleControlEpoch(in: &state)
        state.explicitStopGeneration = nil
      }
    }
  }

  func updateKnownDuration(_ duration: Duration?, playbackGeneration: UInt64) {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard
          playbackGeneration == state.currentGeneration,
          playbackGeneration > state.lastEmittedGeneration
        else { return }
        var snapshot = state.snapshots[playbackGeneration] ?? TimelineSnapshot()
        snapshot.duration = duration
        state.snapshots[playbackGeneration] = snapshot
        self.terminalTimelineAuthority.store(snapshot, generation: playbackGeneration)
      }
    }
  }

  func updateAuthoritativeTimeline(
    time: Duration,
    position: Double?,
    playbackGeneration: UInt64,
    timelineRevision: UInt64,
    timelineEmissionSequence: UInt64? = nil
  ) {
    nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        guard
          playbackGeneration == state.currentGeneration,
          playbackGeneration > state.lastEmittedGeneration
        else { return }
        var snapshot = state.snapshots[playbackGeneration] ?? TimelineSnapshot()
        if let timelineEmissionSequence {
          guard timelineEmissionSequence >= snapshot.timelineEmissionSequence else { return }
          if timelineEmissionSequence == snapshot.timelineEmissionSequence {
            guard timelineRevision >= snapshot.timelineRevision else { return }
          }
          snapshot.timelineEmissionSequence = timelineEmissionSequence
        } else {
          guard timelineRevision >= snapshot.timelineRevision else { return }
        }
        snapshot.time = time
        if let position {
          snapshot.position = position
        }
        snapshot.timelineRevision = timelineRevision
        state.snapshots[playbackGeneration] = snapshot
        self.terminalTimelineAuthority.store(snapshot, generation: playbackGeneration)
      }
    }
  }

  func finishPlaybackGeneration(
    _ generation: UInt64,
    cause: PlaybackTerminalCause,
    nativeHandleGeneration: UInt64
  ) {
    let outcome = nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state in
        self.makeOutcome(
          in: &state,
          generation: generation,
          cause: state.terminalIntents[generation] ?? cause,
          nativeHandleGeneration: nativeHandleGeneration
        )
      }
    }
    if outcome != nil {
      publishPendingTerminalOutcomes()
    }
  }

  func broadcast(
    _ event: PlayerEvent,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64? = nil,
    emittedTimelineRevision: UInt64? = nil,
    nativeSeekEmissionStamp: NativeSeekEmissionStamp? = nil,
    lifecycleControlEpoch: UInt64? = nil
  ) {
    let playbackGeneration = playbackGeneration ?? currentPlaybackGeneration
    let emittedTimelineRevision = emittedTimelineRevision ?? captureTimelineRevision()
    let nativeSeekEmissionStamp = nativeSeekEmissionStamp
      ?? nativeSeekEmissionAuthority.capture()
    let lifecycleControlEpoch = lifecycleControlEpoch ?? currentLifecycleControlEpoch
    recordTimeline(
      event,
      generation: playbackGeneration,
      timelineRevision: emittedTimelineRevision,
      nativeSeekEmissionStamp: nativeSeekEmissionStamp
    )
    // Each broadcaster is gated on its own emptiness so a libVLC event
    // with no consumers costs neither the lock-and-snapshot nor the
    // sourced-wrapper construction. The signal broadcast (the player's
    // internal observable mirror; never carries user filters) runs
    // first, so a slow user filter on the public stream can only delay
    // public delivery — internal state is already on its way.
    if !sourcedPlayerSignals.isEmpty || !sourcedEvents.isEmpty {
      let sourcedEvent = SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: playbackGeneration,
        event: event,
        timelineRevision: emittedTimelineRevision,
        nativeSeekEmissionStamp: nativeSeekEmissionStamp,
        lifecycleControlEpoch: lifecycleControlEpoch
      )
      if !sourcedPlayerSignals.isEmpty {
        sourcedPlayerSignals.broadcast(.event(sourcedEvent))
      }
      if !sourcedEvents.isEmpty {
        sourcedEvents.broadcast(sourcedEvent)
      }
    }
    if !eventEnvelopes.isEmpty {
      eventEnvelopes.broadcast(
        PlayerEventEnvelope(
          event: event,
          nativeGeneration: NativePlayerGeneration(nativeHandleGeneration),
          playbackGeneration: PlaybackGeneration(playbackGeneration)
        )
      )
    }
    if !events.isEmpty {
      events.broadcast(event)
    }
  }

  /// Publishes one native effective-rate resolution with provenance frozen at
  /// callback entry. The private signal and public stream receive the exact
  /// same immutable value, so observation invalidation cannot disagree with
  /// what API consumers saw.
  func broadcastEffectivePlaybackRateResolution(
    _ effectiveRate: Float,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64
  ) {
    guard
      !sourcedPlayerSignals.isEmpty || !effectivePlaybackRateResolutions.isEmpty
    else { return }
    let resolution = EffectivePlaybackRateResolution(
      effectiveRate: effectiveRate,
      nativeGeneration: NativePlayerGeneration(nativeHandleGeneration),
      playbackGeneration: PlaybackGeneration(playbackGeneration)
    )
    if !sourcedPlayerSignals.isEmpty {
      sourcedPlayerSignals.broadcast(.effectivePlaybackRateResolution(resolution))
    }
    if !effectivePlaybackRateResolutions.isEmpty {
      effectivePlaybackRateResolutions.broadcast(resolution)
    }
  }

  func advanceTimelineRevision() -> UInt64 {
    timelineRevision.withLock { revision in
      revision &+= 1
      return revision
    }
  }

  /// Shares a native callback-order barrier with the seek watcher and exact
  /// frame event lane. Wrapper dispatch reserves one before entering libVLC and
  /// adopts it only if the native command succeeds.
  func advanceNativeTimelineEmissionSequence() -> UInt64 {
    nativeSeekEmissionAuthority.advanceTimelineEmissionSequence()
  }

  /// Captures authority at native callback entry, before event classification
  /// or lifecycle bookkeeping can delay delivery past a seek boundary.
  func captureTimelineRevision() -> UInt64 {
    timelineRevision.withLock { $0 }
  }

  func captureNativeSeekEmissionStamp() -> NativeSeekEmissionStamp {
    nativeSeekEmissionAuthority.capture()
  }

  func captureNativeTimelineCallbackEntry(
    lifecycleFact: NativeLifecycleCallbackFact,
    nativeHandleGeneration: UInt64
  ) -> NativeCallbackTimelineEntry {
    let capture = nativeSeekEmissionAuthority.captureCallbackEntry { nativeEntry in
      let timelineRevision = self.captureTimelineRevision()
      #if DEBUG
      if case .terminal = lifecycleFact {
        self.invokeNativeEventCallbackAfterNativeReservationHookForTesting()
      }
      #endif
      return self.playbackLifecycle.withLock { state in
        let playbackGeneration: UInt64
        let terminalReservation: TerminalCallbackReservation?
        let lifecycleOutcome: PlaybackTerminalOutcome?
        if
          state.dormantSuccessorGeneration == state.currentGeneration,
          let retiringGeneration = state.dormantRetiringGeneration {
          // The successor exists only in Swift until a fresh handle is
          // installed. Consequently every event from this attachment still
          // belongs to its original retiring media — including MediaChanged,
          // active-state progress, capability/track/vout changes, and the
          // post-Stopped vout(0) tail. Never clear this quarantine from a
          // callback; only detach/reattach proves the old producer is gone.
          playbackGeneration = retiringGeneration
          lifecycleOutcome = nil
          switch lifecycleFact {
          case .terminal(let terminalFact):
            let checkpoint = self.terminalTimelineAuthority.capture()
            let timelineSnapshot = self.makeTerminalTimelineSnapshot(
              from: checkpoint,
              folding: nativeEntry.latestTimelineEmission,
              playbackGeneration: playbackGeneration
            )
            terminalReservation = self.reserveTerminalCallback(
              terminalFact,
              playbackGeneration: playbackGeneration,
              nativeHandleGeneration: nativeHandleGeneration,
              timelineSnapshot: timelineSnapshot,
              in: &state
            )
          case .mediaChanged, .currentGenerationProgress, .other:
            self.mergeNativeTimelineCallbackEmission(
              nativeEntry.latestTimelineEmission,
              playbackGeneration: playbackGeneration,
              in: &state
            )
            terminalReservation = nil
          }
        } else {
          switch lifecycleFact {
          case .mediaChanged(let mediaIdentity):
            self.mergeNativeTimelineCallbackEmission(
              nativeEntry.latestTimelineEmission,
              playbackGeneration: state.currentGeneration,
              in: &state
            )
            let classification = self.classifyMediaChangedAtCallbackEntry(
              mediaIdentity: mediaIdentity,
              nativeHandleGeneration: nativeHandleGeneration,
              in: &state
            )
            playbackGeneration = classification.playbackGeneration
            lifecycleOutcome = classification.outcome
            terminalReservation = nil

          case .currentGenerationProgress:
            playbackGeneration = state.currentGeneration
            self.mergeNativeTimelineCallbackEmission(
              nativeEntry.latestTimelineEmission,
              playbackGeneration: playbackGeneration,
              in: &state
            )
            self.noteCurrentGenerationProgress(
              playbackGeneration,
              nativeHandleGeneration: nativeHandleGeneration,
              in: &state
            )
            terminalReservation = nil
            lifecycleOutcome = nil

          case .terminal(let terminalFact):
            playbackGeneration = self.claimPlaybackGenerationAtCallbackEntry(
              terminalFact,
              in: &state
            )
            let checkpoint = self.terminalTimelineAuthority.capture()
            let timelineSnapshot = self.makeTerminalTimelineSnapshot(
              from: checkpoint,
              folding: nativeEntry.latestTimelineEmission,
              playbackGeneration: playbackGeneration
            )
            terminalReservation = self.reserveTerminalCallback(
              terminalFact,
              playbackGeneration: playbackGeneration,
              nativeHandleGeneration: nativeHandleGeneration,
              timelineSnapshot: timelineSnapshot,
              in: &state
            )
            lifecycleOutcome = nil

          case .other:
            playbackGeneration = state.currentGeneration
            self.mergeNativeTimelineCallbackEmission(
              nativeEntry.latestTimelineEmission,
              playbackGeneration: playbackGeneration,
              in: &state
            )
            terminalReservation = nil
            lifecycleOutcome = nil
          }
        }
        if
          state.pendingNaturalEndEmission == nil,
          case .terminal(.mediaStopping(_, .naturalEnd)) = lifecycleFact,
          let terminalReservation,
          terminalReservation.cause == .naturalEnd,
          playbackGeneration > state.lastEmittedGeneration {
          // Bind the exact first-winner callback entry before any debug hook,
          // generation synchronizer, duplicate EOS, or public filter can
          // advance mutable lifecycle state.
          state.pendingNaturalEndEmission = RetiredNaturalEndEmission(
            nativeHandleGeneration: nativeHandleGeneration,
            playbackGeneration: playbackGeneration,
            timelineRevision: timelineRevision,
            nativeSeekEmissionStamp: nativeEntry.seekStamp,
            lifecycleControlEpoch: state.lifecycleControlEpoch
          )
        }
        return NativeCallbackLifecycleClaim(
          timelineRevision: timelineRevision,
          playbackGeneration: playbackGeneration,
          lifecycleControlEpoch: state.lifecycleControlEpoch,
          terminalReservation: terminalReservation,
          lifecycleOutcome: lifecycleOutcome
        )
      }
    }
    return NativeCallbackTimelineEntry(
      native: capture.entry,
      timelineRevision: capture.checkpoint.timelineRevision,
      playbackGeneration: capture.checkpoint.playbackGeneration,
      lifecycleControlEpoch: capture.checkpoint.lifecycleControlEpoch,
      terminalReservation: capture.checkpoint.terminalReservation,
      lifecycleOutcome: capture.checkpoint.lifecycleOutcome
    )
  }

  /// Reconstructs the terminal timeline from state committed no later than the
  /// immutable callback-entry boundary. Watcher/frame evidence captured in
  /// the same native critical section is allowed to advance time/position;
  /// mutable lifecycle state is deliberately not consulted.
  func makeTerminalTimelineSnapshot(
    from checkpoint: TerminalTimelineCheckpoint?,
    folding emission: NativeTimelineCallbackEmission?,
    playbackGeneration: UInt64
  ) -> TimelineSnapshot {
    guard let checkpoint else { return TimelineSnapshot() }
    var snapshot = checkpoint.snapshots[playbackGeneration] ?? TimelineSnapshot()
    guard
      let emission,
      emission.playbackGeneration == playbackGeneration,
      emission.timelineEmissionSequence >= snapshot.timelineEmissionSequence
    else { return snapshot }
    if let timeMilliseconds = emission.timeMilliseconds {
      snapshot.time = .milliseconds(timeMilliseconds)
    }
    if let position = emission.position {
      snapshot.position = position
    }
    snapshot.timelineEmissionSequence = emission.timelineEmissionSequence
    return snapshot
  }

  /// Folds watcher/frame evidence captured at this native callback's entry into
  /// the generation snapshot before terminal lifecycle code can freeze it.
  /// MainActor delivery may still be queued; callback order is sufficient.
  func mergeNativeTimelineCallbackEmission(
    _ emission: NativeTimelineCallbackEmission?,
    playbackGeneration: UInt64
  ) {
    guard let emission else { return }
    playbackLifecycle.withLock { state in
      mergeNativeTimelineCallbackEmission(
        emission,
        playbackGeneration: playbackGeneration,
        in: &state
      )
    }
  }

  private func mergeNativeTimelineCallbackEmission(
    _ emission: NativeTimelineCallbackEmission?,
    playbackGeneration: UInt64,
    in state: inout PlaybackLifecycleState
  ) {
    guard
      let emission,
      emission.playbackGeneration == playbackGeneration,
      playbackGeneration > state.lastEmittedGeneration
    else { return }
    var snapshot = state.snapshots[playbackGeneration] ?? TimelineSnapshot()
    guard emission.timelineEmissionSequence >= snapshot.timelineEmissionSequence else {
      return
    }
    if let timeMilliseconds = emission.timeMilliseconds {
      snapshot.time = .milliseconds(timeMilliseconds)
    }
    if let position = emission.position {
      snapshot.position = position
    }
    snapshot.timelineEmissionSequence = emission.timelineEmissionSequence
    state.snapshots[playbackGeneration] = snapshot
    terminalTimelineAuthority.store(snapshot, generation: playbackGeneration)
  }

  /// Permanently closes both broadcasters, so streams handed out after this
  /// point are already finished rather than waiting on a source that will
  /// never emit again.
  func terminate() {
    events.terminate()
    eventEnvelopes.terminate()
    sourcedEvents.terminate()
    sourcedPlayerSignals.terminate()
    effectivePlaybackRateResolutions.terminate()
    terminalOutcomes.terminate()
  }

  var currentPlaybackGeneration: UInt64 {
    playbackLifecycle.withLock { $0.currentGeneration }
  }

  var currentLifecycleControlEpoch: UInt64 {
    playbackLifecycle.withLock { $0.lifecycleControlEpoch }
  }

  /// Whether one exact callback/control identity still owns nonterminal
  /// playback. Terminal callbacks reserve their generation synchronously at
  /// callback entry, before their observable Player state can reach the main
  /// actor; consulting that reservation closes the queued-delivery window.
  func ownsNonterminalPlayback(
    playbackGeneration: UInt64,
    nativeHandleGeneration: UInt64,
    lifecycleControlEpoch: UInt64
  ) -> Bool {
    playbackLifecycle.withLock { state in
      guard
        state.currentGeneration == playbackGeneration,
        state.currentNativeHandleGeneration == nativeHandleGeneration,
        state.lifecycleControlEpoch == lifecycleControlEpoch
      else { return false }
      if recastInterruption(generation: playbackGeneration, in: state) == nil {
        return true
      }
      // Zero is both the initial playable generation and the sentinel below
      // `lastEmittedGeneration`. It has not ended merely because 0 <= 0. Keep
      // synthetic/external initial-handle playback valid while still rejecting
      // every terminal marker that can exist for that generation.
      return playbackGeneration == 0
        && state.lastEmittedGeneration == 0
        && state.terminalReservations[0] == nil
        && state.terminalCauses[0] == nil
        && state.terminalIntents[0] == nil
        && state.pendingStoppedGeneration != 0
        && state.explicitStopGeneration != 0
    }
  }

  func hasExplicitStopBarrier(playbackGeneration: UInt64) -> Bool {
    playbackLifecycle.withLock {
      $0.currentGeneration == playbackGeneration
        && $0.explicitStopGeneration == playbackGeneration
    }
  }

  @MainActor
  func performIfCurrentPlaybackGeneration(
    _ expectedGeneration: UInt64,
    _ mutation: () -> Void
  ) -> Bool {
    playbackLifecycle.withLock { state in
      guard state.currentGeneration == expectedGeneration else { return false }
      mutation()
      return true
    }
  }

  func noteExternalMediaChanged(
    _ media: OpaquePointer?,
    nativeHandleGeneration: UInt64
  ) -> UInt64 {
    let identity = Self.identity(of: media)
    let result = nativeSeekEmissionAuthority.withCallbackOrdering {
      self.playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
        let classification = self.classifyMediaChangedAtCallbackEntry(
          mediaIdentity: identity,
          nativeHandleGeneration: nativeHandleGeneration,
          in: &state
        )
        return (classification.playbackGeneration, classification.outcome)
      }
    }
    if result.1 != nil {
      publishPendingTerminalOutcomes()
    }
    return result.0
  }

  func publishLifecycleOutcome(_ outcome: PlaybackTerminalOutcome?) {
    if outcome != nil {
      publishPendingTerminalOutcomes()
    }
  }

  /// Classifies the wrapper echo vs external adoption while callback order and
  /// playback lifecycle are both owned. No observer is invoked here; a
  /// resulting terminal outcome is returned for publication after all locks
  /// have been released.
  private func classifyMediaChangedAtCallbackEntry(
    mediaIdentity identity: UInt?,
    nativeHandleGeneration: UInt64,
    in state: inout PlaybackLifecycleState
  ) -> (playbackGeneration: UInt64, outcome: PlaybackTerminalOutcome?) {
    if
      state.pendingWrapperMediaChangedGeneration == state.currentGeneration,
      identity == state.currentMediaIdentity {
      state.pendingWrapperMediaChangedGeneration = nil
      return (state.currentGeneration, nil)
    }
    state.pendingWrapperMediaChangedGeneration = nil
    let outgoing = state.currentGeneration
    let outgoingIdentity = state.currentMediaIdentity
    let outcome = makeOutcome(
      in: &state,
      generation: outgoing,
      cause: state.terminalIntents[outgoing] ?? .replacement,
      nativeHandleGeneration: nativeHandleGeneration
    )
    precondition(state.currentGeneration < UInt64.max, "Playback generation exhausted")
    state.currentGeneration += 1
    advanceLifecycleControlEpoch(in: &state)
    state.explicitStopGeneration = nil
    state.currentMediaIdentity = identity
    if let identity {
      if outcome != nil, outgoing > 0, identity == outgoingIdentity {
        state.retiredMediaGenerations[identity, default: []].append(outgoing)
      }
      state.mediaGenerations[identity] = state.currentGeneration
    }
    let snapshot = TimelineSnapshot()
    state.snapshots[state.currentGeneration] = snapshot
    terminalTimelineAuthority.store(snapshot, generation: state.currentGeneration)
    return (state.currentGeneration, outcome)
  }

  /// Claims terminal playback ownership while the native-emission authority
  /// is still held. This is deliberately an `inout` helper: callers must
  /// already own `playbackLifecycle`, so no hidden lock edge can be introduced.
  private func claimPlaybackGenerationAtCallbackEntry(
    _ fact: NativeTerminalCallbackFact,
    in state: inout PlaybackLifecycleState
  ) -> UInt64 {
    switch fact {
    case .mediaStopping(let identity, _):
      let generation: UInt64
      if
        let identity,
        var retired = state.retiredMediaGenerations[identity],
        !retired.isEmpty {
        generation = retired.removeFirst()
        state.retiredMediaGenerations[identity] = retired.isEmpty ? nil : retired
      } else {
        generation = identity.flatMap { state.mediaGenerations[$0] }
          ?? state.currentGeneration
      }
      state.pendingStoppedGeneration = generation
      return generation

    case .stopped:
      let generation = state.pendingStoppedGeneration ?? state.currentGeneration
      state.pendingStoppedGeneration = nil
      return generation

    case .encounteredError:
      // libVLC normally follows the error with Stopped. Preserve the outgoing
      // owner across a wrapper cold replay between those serialized callbacks.
      state.pendingStoppedGeneration = state.currentGeneration
      return state.currentGeneration
    }
  }

  private func reserveTerminalCallback(
    _ fact: NativeTerminalCallbackFact,
    playbackGeneration: UInt64,
    nativeHandleGeneration: UInt64,
    timelineSnapshot: TimelineSnapshot,
    in state: inout PlaybackLifecycleState
  ) -> TerminalCallbackReservation {
    if let existing = state.terminalReservations[playbackGeneration] {
      return existing
    }

    let cause: PlaybackTerminalCause = switch fact {
    case .mediaStopping(_, let engineCause):
      state.terminalIntents[playbackGeneration] ?? engineCause
    case .encounteredError(let failure):
      .failure(failure)
    case .stopped:
      state.terminalIntents[playbackGeneration] ?? .unknownNativeStop
    }
    if
      case .encounteredError = fact,
      playbackGeneration > state.lastEmittedGeneration {
      state.terminalIntents[playbackGeneration] = cause
    }

    let reservation = TerminalCallbackReservation(
      playbackGeneration: playbackGeneration,
      nativeHandleGeneration: nativeHandleGeneration,
      cause: cause,
      timelineSnapshot: timelineSnapshot
    )
    guard playbackGeneration > state.lastEmittedGeneration else {
      return reservation
    }
    state.terminalReservations[playbackGeneration] = reservation
    if state.terminalReservations.count > 33 {
      let retained = Set(state.terminalReservations.keys.sorted().suffix(33))
      state.terminalReservations = state.terminalReservations.filter {
        retained.contains($0.key)
      }
    }
    return reservation
  }

  func noteMediaStopping(
    playbackGeneration: UInt64,
    reason: libvlc_stopping_reason_t,
    nativeHandleGeneration: UInt64,
    terminalTimelineSnapshot: TimelineSnapshot
  ) -> UInt64 {
    let result = playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
      let engineCause: PlaybackTerminalCause = switch reason {
      case libvlc_stopping_reason_eos: .naturalEnd
      case libvlc_stopping_reason_user: .requestedStop
      case libvlc_stopping_reason_error: .failure(.unknown)
      default: .unknownNativeStop
      }
      let outcome = makeOutcome(
        in: &state,
        generation: playbackGeneration,
        cause: state.terminalIntents[playbackGeneration] ?? engineCause,
        nativeHandleGeneration: nativeHandleGeneration,
        terminalTimelineSnapshot: terminalTimelineSnapshot
      )
      return (playbackGeneration, outcome)
    }
    if result.1 != nil {
      publishPendingTerminalOutcomes()
    }
    return result.0
  }

  func noteEncounteredError(
    _ failure: PlaybackFailureKind,
    playbackGeneration: UInt64,
    nativeHandleGeneration: UInt64,
    terminalTimelineSnapshot: TimelineSnapshot
  ) -> UInt64 {
    let result = playbackLifecycle.withLock { state -> (UInt64, PlaybackTerminalOutcome?) in
      guard playbackGeneration > state.lastEmittedGeneration else {
        return (playbackGeneration, nil)
      }
      state.terminalIntents[playbackGeneration] = .failure(failure)
      let outcome = makeOutcome(
        in: &state,
        generation: playbackGeneration,
        cause: .failure(failure),
        nativeHandleGeneration: nativeHandleGeneration,
        terminalTimelineSnapshot: terminalTimelineSnapshot
      )
      return (playbackGeneration, outcome)
    }
    if result.1 != nil {
      publishPendingTerminalOutcomes()
    }
    return result.0
  }

  func noteStopped(
    playbackGeneration: UInt64,
    nativeHandleGeneration: UInt64,
    terminalTimelineSnapshot: TimelineSnapshot
  ) -> (playbackGeneration: UInt64, consumedNaturalEndEmission: Bool) {
    let result = playbackLifecycle.withLock { state in
      let outcome = makeOutcome(
        in: &state,
        generation: playbackGeneration,
        cause: state.terminalIntents[playbackGeneration] ?? .unknownNativeStop,
        nativeHandleGeneration: nativeHandleGeneration,
        terminalTimelineSnapshot: terminalTimelineSnapshot
      )
      let consumedNaturalEndEmission = state.pendingNaturalEndEmission?
        .playbackGeneration == playbackGeneration
      if consumedNaturalEndEmission {
        state.pendingNaturalEndEmission = nil
      }
      return (playbackGeneration, consumedNaturalEndEmission, outcome)
    }
    if result.2 != nil {
      publishPendingTerminalOutcomes()
    }
    return (result.0, result.1)
  }

  #if DEBUG
  func setNativeEventCallbackBeforePlaybackClaimHookForTesting(
    _ hook: (@Sendable () -> Void)?
  ) {
    nativeEventCallbackBeforePlaybackClaimHook.withLock { $0 = hook }
  }

  func invokeNativeEventCallbackBeforePlaybackClaimHookForTesting() {
    let hook = nativeEventCallbackBeforePlaybackClaimHook.withLock { $0 }
    hook?()
  }

  func setNativeEventCallbackAfterNativeReservationHookForTesting(
    _ hook: (@Sendable () -> Void)?
  ) {
    nativeEventCallbackAfterNativeReservationHook.withLock { $0 = hook }
  }

  func invokeNativeEventCallbackAfterNativeReservationHookForTesting() {
    let hook = nativeEventCallbackAfterNativeReservationHook.withLock { $0 }
    hook?()
  }

  func setNativeEventCallbackEntryHookForTesting(
    _ hook: (@Sendable () -> Void)?
  ) {
    nativeEventCallbackEntryHook.withLock { $0 = hook }
  }

  func invokeNativeEventCallbackEntryHookForTesting() {
    let hook = nativeEventCallbackEntryHook.withLock { $0 }
    hook?()
  }
  #endif

  func noteCurrentGenerationProgress(
    _ generation: UInt64,
    nativeHandleGeneration: UInt64
  ) {
    playbackLifecycle.withLock { state in
      noteCurrentGenerationProgress(
        generation,
        nativeHandleGeneration: nativeHandleGeneration,
        in: &state
      )
    }
  }

  private func noteCurrentGenerationProgress(
    _ generation: UInt64,
    nativeHandleGeneration: UInt64,
    in state: inout PlaybackLifecycleState
  ) {
    guard generation == state.currentGeneration else { return }
    state.startedNativeHandleGeneration = nativeHandleGeneration
    if nativeHandleGeneration == state.currentNativeHandleGeneration {
      state.startedPlaybackGeneration = generation
    }
    if let identity = state.currentMediaIdentity {
      // Native callbacks are serialized. Once the successor opens or plays,
      // every stopping callback ordered before that progress has arrived, so
      // an unresolved same-pointer retirement can no longer be consumed by a
      // future stop belonging to the successor.
      state.retiredMediaGenerations[identity] = nil
    }
    state.pendingWrapperMediaChangedGeneration = nil
    if
      let pending = state.pendingStoppedGeneration,
      pending < generation,
      pending <= state.lastEmittedGeneration {
      state.pendingStoppedGeneration = nil
    }
  }

  func completeNativeHandleReplacement(nativeHandleGeneration: UInt64) {
    playbackLifecycle.withLock { state in
      state.pendingStoppedGeneration = nil
      state.dormantSuccessorGeneration = nil
      state.dormantRetiringGeneration = nil
      state.pendingNaturalEndEmission = nil
      state.pendingWrapperMediaChangedGeneration = nil
      state.retiredMediaGenerations.removeAll()
      state.currentNativeHandleGeneration = nativeHandleGeneration
      if state.startedNativeHandleGeneration != nativeHandleGeneration {
        state.startedNativeHandleGeneration = nil
      }
      state.startedPlaybackGeneration = nil
    }
  }

  /// Claims the exact retiring playback generation whose authoritative EOS
  /// was already frozen but whose ordered `Stopped` callback did not arrive
  /// before event detachment. Returning the emission consumes this handoff;
  /// a later replacement cannot synthesize the same natural end again.
  func consumePendingNaturalEndForNativeHandleReplacement()
    -> RetiredNaturalEndEmission? {
    playbackLifecycle.withLock { state in
      guard
        let emission = state.pendingNaturalEndEmission,
        state.pendingStoppedGeneration == emission.playbackGeneration
      else { return nil }
      state.pendingNaturalEndEmission = nil
      state.pendingStoppedGeneration = nil
      return emission
    }
  }

  private func recordTimeline(
    _ event: PlayerEvent,
    generation: UInt64,
    timelineRevision: UInt64,
    nativeSeekEmissionStamp: NativeSeekEmissionStamp
  ) {
    guard generation > 0 else { return }
    playbackLifecycle.withLock { state in
      guard generation > state.lastEmittedGeneration else { return }
      var snapshot = state.snapshots[generation] ?? TimelineSnapshot()
      switch event {
      case .timeChanged(let time):
        guard
          !nativeSeekEmissionStamp.externalDrainPending,
          !nativeSeekEmissionStamp.externalOverlapAmbiguous
        else { return }
        guard
          nativeSeekEmissionStamp.timelineEmissionSequence
          >= snapshot.timelineEmissionSequence
        else { return }
        if
          nativeSeekEmissionStamp.timelineEmissionSequence
          == snapshot.timelineEmissionSequence {
          guard timelineRevision >= snapshot.timelineRevision else { return }
        }
        snapshot.time = time
        snapshot.timelineRevision = timelineRevision
        snapshot.timelineEmissionSequence = nativeSeekEmissionStamp
          .timelineEmissionSequence
      case .lengthChanged(let duration): snapshot.duration = duration
      case .positionChanged(let position):
        guard
          !nativeSeekEmissionStamp.externalDrainPending,
          !nativeSeekEmissionStamp.externalOverlapAmbiguous
        else { return }
        guard
          nativeSeekEmissionStamp.timelineEmissionSequence
          >= snapshot.timelineEmissionSequence
        else { return }
        if
          nativeSeekEmissionStamp.timelineEmissionSequence
          == snapshot.timelineEmissionSequence {
          guard timelineRevision >= snapshot.timelineRevision else { return }
        }
        snapshot.position = position
        snapshot.timelineRevision = timelineRevision
        snapshot.timelineEmissionSequence = nativeSeekEmissionStamp
          .timelineEmissionSequence
      case .bufferingProgress(let fill): snapshot.bufferFill = fill
      case .voutChanged(let count): snapshot.activeVideoOutputs = count
      default: break
      }
      state.snapshots[generation] = snapshot
      terminalTimelineAuthority.store(snapshot, generation: generation)
    }
  }

  private func makeOutcome(
    in state: inout PlaybackLifecycleState,
    generation: UInt64,
    cause: PlaybackTerminalCause,
    nativeHandleGeneration: UInt64,
    terminalTimelineSnapshot: TimelineSnapshot? = nil
  ) -> PlaybackTerminalOutcome? {
    let reservation = state.terminalReservations.removeValue(forKey: generation)
    guard generation > state.lastEmittedGeneration else { return nil }
    state.lastEmittedGeneration = generation
    let resolvedCause = reservation?.cause ?? cause
    let resolvedNativeHandleGeneration = reservation?.nativeHandleGeneration
      ?? nativeHandleGeneration
    let snapshot = reservation?.timelineSnapshot
      ?? terminalTimelineSnapshot
      ?? state.snapshots[generation]
      ?? TimelineSnapshot()
    state.terminalCauses[generation] = resolvedCause
    let oldestRetainedGeneration = generation > 32 ? generation - 32 : 0
    let pendingNaturalEndGeneration = state.pendingNaturalEndEmission?
      .playbackGeneration
    state.terminalCauses = state.terminalCauses.filter {
      $0.key >= oldestRetainedGeneration
        || $0.key == pendingNaturalEndGeneration
    }
    state.terminalReservations = state.terminalReservations.filter {
      $0.key > generation
    }
    state.terminalIntents[generation] = nil
    state.snapshots = state.snapshots.filter { $0.key >= generation }
    terminalTimelineAuthority.retain(generationsAtLeast: generation)
    state.mediaGenerations = state.mediaGenerations.filter { $0.value >= generation }
    let outcome = PlaybackTerminalOutcome(
      generation: PlaybackGeneration(generation),
      nativeGeneration: NativePlayerGeneration(resolvedNativeHandleGeneration),
      cause: resolvedCause,
      finalTimeline: snapshot.publicValue
    )
    terminalOutcomePublication.withLock { publication in
      publication.pending[generation] = outcome
    }
    return outcome
  }

  /// Drains generation-ordered outcomes with exactly one publisher. Subscriber
  /// callbacks run after the publication mutex is released, so reentrant
  /// Player work can safely enqueue another outcome for this loop to consume.
  private func publishPendingTerminalOutcomes() {
    let ownsPublisher = terminalOutcomePublication.withLock { publication in
      guard !publication.isPublishing else { return false }
      publication.isPublishing = true
      return true
    }
    guard ownsPublisher else { return }

    while true {
      let next = terminalOutcomePublication.withLock { publication -> PlaybackTerminalOutcome? in
        guard let generation = publication.pending.keys.min() else {
          publication.isPublishing = false
          return nil
        }
        return publication.pending.removeValue(forKey: generation)
      }
      guard let next else { return }
      terminalOutcomes.broadcast(next)
    }
  }

  private static func identity(of media: OpaquePointer?) -> UInt? {
    media.map { UInt(bitPattern: $0) }
  }

  private func advanceLifecycleControlEpoch(
    in state: inout PlaybackLifecycleState
  ) {
    precondition(
      state.lifecycleControlEpoch < UInt64.max,
      "Playback lifecycle control epoch exhausted"
    )
    state.lifecycleControlEpoch += 1
  }
}
