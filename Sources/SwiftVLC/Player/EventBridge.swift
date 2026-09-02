import CLibVLC
import os
import Synchronization

struct RecastReplacementExpectation: Sendable {
  let playbackGeneration: UInt64
  let nativeHandleGeneration: UInt64
  let lifecycleControlEpoch: UInt64
  let mediaIdentity: UInt?
  let ownershipEpoch: UInt64
}

struct RecastReplacementLease: Equatable, Sendable {
  let id: UInt64
  let playbackGeneration: UInt64
  let nativeHandleGeneration: UInt64
  let ownershipEpoch: UInt64
  let outgoingTimeline: PlaybackFinalTimeline
}

struct RecastMutationPermit: Equatable, Sendable {
  let id: UInt64
  let lease: RecastReplacementLease
}

enum RecastTransactionInterruption: Equatable, Sendable {
  case superseded
  case terminal(PlaybackTerminalCause)
}

enum RecastReplacementCommitResult: Sendable {
  case committed(RecastReplacementLease)
  case interrupted(RecastTransactionInterruption)
}

enum RecastMutationReservation: Sendable {
  case permitted(RecastMutationPermit)
  case interrupted(RecastTransactionInterruption)
}

/// Bridges libVLC C event callbacks to `AsyncStream<PlayerEvent>`.
///
/// Multi-consumer fan-out built on `Broadcaster<PlayerEvent>`. Each call
/// to `makeStream()` returns an independent `AsyncStream`. The C callback
/// reaches a retained callback context through an `Unmanaged` pointer
/// passed to libVLC's `event_attach`, then calls `broadcast(_:)` which
/// snapshots subscribers under a Mutex and yields outside the lock.
final class EventBridge: Sendable {
  final class PreparedReattachment: @unchecked Sendable {
    private enum State: Equatable {
      case prepared
      case installed
      case activated
      case cancelled
    }

    nonisolated(unsafe) let eventManager: OpaquePointer
    nonisolated(unsafe) let attachmentOpaque: UnsafeMutableRawPointer
    let attachedEventTypes: [Int32]
    let nativeHandleGeneration: UInt64
    private let state = Mutex(State.prepared)

    init(
      eventManager: OpaquePointer,
      attachmentOpaque: UnsafeMutableRawPointer,
      attachedEventTypes: [Int32],
      nativeHandleGeneration: UInt64
    ) {
      self.eventManager = eventManager
      self.attachmentOpaque = attachmentOpaque
      self.attachedEventTypes = attachedEventTypes
      self.nativeHandleGeneration = nativeHandleGeneration
    }

    func cancel() -> Bool {
      state.withLock { state in
        guard state == .prepared else { return false }
        state = .cancelled
        return true
      }
    }

    func install() -> Bool {
      state.withLock { state in
        guard state == .prepared else { return false }
        state = .installed
        return true
      }
    }

    func activate() -> Bool {
      state.withLock { state in
        guard state == .installed else { return false }
        state = .activated
        return true
      }
    }
  }

  private nonisolated(unsafe) var eventManager: OpaquePointer
  private let context: EventBridgeCallbackContext
  private nonisolated(unsafe) var attachmentOpaque: UnsafeMutableRawPointer?
  private nonisolated(unsafe) var attachedEventTypes: [Int32]
  private let nativeHandleGeneration = Mutex<UInt64>(1)
  private let retiredNaturalEndEmissions = Mutex<[RetiredNaturalEndEmission]>([])
  private let invalidated = Mutex(false)
  #if DEBUG
  private let preparedAttachmentFailureIndexForTesting = Mutex<Int?>(nil)
  private let preparedAttachmentRollbackCountForTesting = Mutex(0)
  #endif

  init(
    eventManager: OpaquePointer,
    endCoordinator: PlaybackEndCoordinator,
    nativeSeekEmissionAuthority: NativeSeekEmissionAuthority
  ) {
    self.eventManager = eventManager

    let context = EventBridgeCallbackContext(
      endCoordinator: endCoordinator,
      nativeSeekEmissionAuthority: nativeSeekEmissionAuthority
    )
    self.context = context
    let attachment = EventBridgeCallbackAttachment(
      context: context,
      nativeHandleGeneration: 1
    )
    let opaque = Unmanaged.passRetained(attachment).toOpaque()
    attachmentOpaque = opaque

    guard
      let attachedEventTypes = Self.attachAllEvents(
        to: eventManager,
        opaque: opaque
      ) else {
      Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(opaque).release()
      preconditionFailure("Failed to attach the complete libVLC player event set")
    }
    self.attachedEventTypes = attachedEventTypes
  }

  deinit {
    invalidate()
  }

  /// Detaches all event listeners and finishes all streams.
  /// Safe to call multiple times (idempotent). Must be called while
  /// the event manager's parent (media player) is still alive.
  func invalidate() {
    let shouldCleanUp = invalidated.withLock { alreadyDone -> Bool in
      guard !alreadyDone else { return false }
      alreadyDone = true
      return true
    }
    guard shouldCleanUp else { return }

    retiredNaturalEndEmissions.withLock {
      $0.removeAll(keepingCapacity: false)
    }
    guard let attachmentOpaque else { return }
    Self.detachEvents(attachedEventTypes, from: eventManager, opaque: attachmentOpaque)
    attachedEventTypes = []
    self.attachmentOpaque = nil
    // `libvlc_event_detach` takes the same event-manager lock that surrounds
    // callback execution. Once every detach returns, no callback can still be
    // borrowing this attachment token, so releasing it here is safe.
    Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(attachmentOpaque).release()
    // `terminate()`, not `finishAll()`: invalidation is permanent. The
    // mid-life native handle swap goes through `reattach(to:)` and never
    // lands here, so the only callers are shutdown and deinit — after which
    // the event source is gone for good. `Player.events` is a computed
    // property that subscribes per access, so `finishAll()` would hand a
    // post-shutdown caller a live stream that never finishes.
    context.terminate()
  }

  /// Attaches a complete, inactive callback set to a candidate player.
  /// Failure rolls back every listener before returning, so replacement never
  /// commits with a partially observable successor.
  func prepareReattachment(
    to newEventManager: OpaquePointer
  ) -> PreparedReattachment? {
    let isInvalidated = invalidated.withLock { $0 }
    guard !isInvalidated, attachmentOpaque != nil else { return nil }

    let generation = nativeHandleGeneration.withLock { generation in
      precondition(generation < UInt64.max, "Native handle generation exhausted")
      return generation + 1
    }
    let attachment = EventBridgeCallbackAttachment(
      context: context,
      nativeHandleGeneration: generation,
      active: false
    )
    let opaque = Unmanaged.passRetained(attachment).toOpaque()
    #if DEBUG
    let forcedFailureAfterAttachedCount = preparedAttachmentFailureIndexForTesting
      .withLock { $0 }
    #else
    let forcedFailureAfterAttachedCount: Int? = nil
    #endif
    guard
      let eventTypes = Self.attachAllEvents(
        to: newEventManager,
        opaque: opaque,
        forcedFailureAfterAttachedCount: forcedFailureAfterAttachedCount,
        didRollback: { count in
          #if DEBUG
          self.preparedAttachmentRollbackCountForTesting.withLock { $0 = count }
          #endif
        }
      ) else {
      Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(opaque).release()
      return nil
    }
    return PreparedReattachment(
      eventManager: newEventManager,
      attachmentOpaque: opaque,
      attachedEventTypes: eventTypes,
      nativeHandleGeneration: generation
    )
  }

  /// Abandons a candidate callback set before its native player is released.
  func cancelPreparedReattachment(_ prepared: PreparedReattachment) {
    guard prepared.cancel() else { return }
    Self.detachEvents(
      prepared.attachedEventTypes,
      from: prepared.eventManager,
      opaque: prepared.attachmentOpaque
    )
    Unmanaged<EventBridgeCallbackAttachment>
      .fromOpaque(prepared.attachmentOpaque)
      .release()
  }

  /// Compatibility path for tests and handle swaps which do not need a
  /// conditional playback-generation commit. Production replacement prepares
  /// explicitly so listener completeness is proven before its lifecycle point.
  @discardableResult
  func reattach(to newEventManager: OpaquePointer) -> UInt64 {
    guard let prepared = prepareReattachment(to: newEventManager) else {
      return currentNativeHandleGeneration
    }
    let generation = installPreparedReattachment(prepared)
    activatePreparedReattachment(prepared)
    return generation
  }

  /// Installs an already-fully-attached successor without activating it.
  ///
  /// Keeping the successor token inactive lets `Player` make its pointer,
  /// lifetime, generation, transaction flags, and callback snapshots coherent
  /// before any successor event can enter. The old event-manager lock provides
  /// quiescence; its token remains active until every detach has returned.
  @discardableResult
  func installPreparedReattachment(_ prepared: PreparedReattachment) -> UInt64 {
    guard let oldAttachmentOpaque = attachmentOpaque else {
      preconditionFailure("Cannot commit a native reattachment after invalidation")
    }
    let outgoingNativeHandleGeneration = currentNativeHandleGeneration
    precondition(
      outgoingNativeHandleGeneration < UInt64.max
        && prepared.nativeHandleGeneration == outgoingNativeHandleGeneration + 1,
      "Prepared native handle generation is stale"
    )
    precondition(prepared.install(), "Prepared native attachment was already consumed")

    Self.detachEvents(attachedEventTypes, from: eventManager, opaque: oldAttachmentOpaque)
    Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(oldAttachmentOpaque).release()

    // The retiring handle cannot emit after detach returns. If its
    // authoritative EOS arrived first but Stopped did not, this boundary is
    // the sole remaining place to deliver that exact natural end. Both claims
    // are one-shot, and list-player suppression remains authoritative.
    let pendingNaturalEndEmission = context
      .consumePendingNaturalEndForNativeHandleReplacement()
    let shouldSynthesizePendingNaturalEnd = pendingNaturalEndEmission.map {
      context.endCoordinator.consumeHandleReplacementShouldSynthesizeEnd(
        playbackGeneration: $0.playbackGeneration
      )
    } ?? false
    context.endCoordinator.clearForHandleReplacement()
    if
      shouldSynthesizePendingNaturalEnd,
      let pendingNaturalEndEmission {
      retiredNaturalEndEmissions.withLock {
        $0.append(pendingNaturalEndEmission)
      }
    }

    context.completeNativeHandleReplacement(
      nativeHandleGeneration: prepared.nativeHandleGeneration
    )
    eventManager = prepared.eventManager
    attachmentOpaque = prepared.attachmentOpaque
    attachedEventTypes = prepared.attachedEventTypes
    nativeHandleGeneration.withLock { generation in
      precondition(generation + 1 == prepared.nativeHandleGeneration)
      generation = prepared.nativeHandleGeneration
    }
    return prepared.nativeHandleGeneration
  }

  /// Makes a previously installed successor observable to native callbacks.
  /// This is deliberately separate from listener installation: callers must
  /// establish every Swift/native identity field before crossing this final
  /// boundary.
  func activatePreparedReattachment(_ prepared: PreparedReattachment) {
    precondition(
      attachmentOpaque == prepared.attachmentOpaque
        && eventManager == prepared.eventManager
        && currentNativeHandleGeneration == prepared.nativeHandleGeneration,
      "Only the installed native attachment can be activated"
    )
    precondition(prepared.activate(), "Prepared native attachment cannot be activated twice")
    Unmanaged<EventBridgeCallbackAttachment>
      .fromOpaque(prepared.attachmentOpaque)
      .takeUnretainedValue()
      .activate()
  }

  /// Compatibility spelling for direct callers which do not need a delayed
  /// activation transaction.
  @discardableResult
  func commitPreparedReattachment(_ prepared: PreparedReattachment) -> UInt64 {
    let generation = installPreparedReattachment(prepared)
    activatePreparedReattachment(prepared)
    return generation
  }

  /// Publishes natural ends retired by `reattach(to:)` only after Player's
  /// replacement transaction has committed its public pointer, lifetime,
  /// generation, flags, and old-handle release. Public filters are
  /// synchronous and may reenter Player, so publishing inside `reattach`
  /// would expose a half-committed replacement.
  @discardableResult
  func publishRetiredNaturalEndsAfterHandleReplacement() -> Int {
    let emissions = retiredNaturalEndEmissions.withLock { emissions in
      let result = emissions
      emissions.removeAll(keepingCapacity: true)
      return result
    }
    for emission in emissions {
      context.broadcast(
        .endReached,
        nativeHandleGeneration: emission.nativeHandleGeneration,
        playbackGeneration: emission.playbackGeneration,
        emittedTimelineRevision: emission.timelineRevision,
        nativeSeekEmissionStamp: emission.nativeSeekEmissionStamp,
        lifecycleControlEpoch: emission.lifecycleControlEpoch
      )
    }
    return emissions.count
  }

  /// Monotonic identity of the native player currently feeding this bridge.
  /// Unlike a pointer address, it cannot alias a retired A handle after an
  /// allocator reuses that address for a later C handle.
  var currentNativeHandleGeneration: UInt64 {
    nativeHandleGeneration.withLock { $0 }
  }

  var currentNativePlayerGeneration: NativePlayerGeneration {
    NativePlayerGeneration(currentNativeHandleGeneration)
  }

  /// Playback generation already accepted by the callback lane, which can be
  /// ahead of the main actor while a native media-change event is queued.
  var currentPlaybackGeneration: UInt64 {
    context.currentPlaybackGeneration
  }

  var currentNativeHandleHasStartedPlayback: Bool {
    context.currentNativeHandleHasStartedPlayback
  }

  var currentPlaybackGenerationHasStartedPlayback: Bool {
    context.currentPlaybackGenerationHasStartedPlayback
  }

  /// Playback-control boundary already accepted by the callback lane.
  var currentLifecycleControlEpoch: UInt64 {
    context.currentLifecycleControlEpoch
  }

  func ownsNonterminalPlayback(
    playbackGeneration: UInt64,
    nativeHandleGeneration: UInt64,
    lifecycleControlEpoch: UInt64
  ) -> Bool {
    context.ownsNonterminalPlayback(
      playbackGeneration: playbackGeneration,
      nativeHandleGeneration: nativeHandleGeneration,
      lifecycleControlEpoch: lifecycleControlEpoch
    )
  }

  func hasExplicitStopBarrier(playbackGeneration: UInt64) -> Bool {
    context.hasExplicitStopBarrier(playbackGeneration: playbackGeneration)
  }

  /// Runs a main-actor mutation only if the callback lane is still on the
  /// expected playback generation. The comparison and mutation share the
  /// callback lane's lifecycle lock, giving callers a real linearization point
  /// against a concurrent native media-change callback.
  @MainActor
  func performIfCurrentPlaybackGeneration(
    _ expectedGeneration: UInt64,
    _ mutation: () -> Void
  ) -> Bool {
    context.performIfCurrentPlaybackGeneration(expectedGeneration, mutation)
  }

  /// Creates a new independent `AsyncStream` for consuming player events.
  /// Each stream is offered events broadcast after creation that pass its
  /// filter. Delivery under consumer lag follows `policy`.
  func makeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEvent) -> Bool)?
  ) -> AsyncStream<PlayerEvent> {
    context.makeStream(policy: policy, filter: filter)
  }

  func makeSourcedStream(policy: EventBufferingPolicy) -> AsyncStream<SourcedPlayerEvent> {
    context.makeSourcedStream(policy: policy)
  }

  func makeSourcedPlayerSignalStream(
    policy: EventBufferingPolicy
  ) -> AsyncStream<SourcedPlayerSignal> {
    context.makeSourcedPlayerSignalStream(policy: policy)
  }

  func makeEffectivePlaybackRateResolutionStream()
    -> AsyncStream<EffectivePlaybackRateResolution> {
    context.makeEffectivePlaybackRateResolutionStream()
  }

  func makeEnvelopeStream(
    policy: EventBufferingPolicy?,
    filter: (@Sendable (PlayerEventEnvelope) -> Bool)?
  ) -> AsyncStream<PlayerEventEnvelope> {
    context.makeEnvelopeStream(policy: policy, filter: filter)
  }

  func makeTerminalOutcomeStream() -> AsyncStream<PlaybackTerminalOutcome> {
    context.makeTerminalOutcomeStream()
  }

  /// Returns the frozen terminal cause for one exact media generation.
  /// Unlike `Player.state`, this cannot carry an outgoing error across a
  /// synchronous media replacement.
  func terminalCause(for playbackGeneration: UInt64) -> PlaybackTerminalCause? {
    context.terminalCause(for: playbackGeneration)
  }

  /// Aligns the event bridge with a wrapper-initiated media generation.
  /// The outgoing generation is frozen as a replacement before the new
  /// timeline becomes current.
  @discardableResult
  func synchronizePlaybackGeneration(
    _ generation: UInt64,
    media: OpaquePointer?,
    outgoingNativeHandleGeneration: UInt64? = nil,
    expectRetiringHandleStopped: Bool = false
  ) -> UInt64 {
    precondition(
      !expectRetiringHandleStopped || outgoingNativeHandleGeneration != nil,
      "A retiring-handle stop expectation requires the outgoing handle generation"
    )
    return context.synchronizePlaybackGeneration(
      generation,
      media: media,
      nativeHandleGeneration: outgoingNativeHandleGeneration
        ?? currentNativeHandleGeneration,
      retiringNativeHandle: outgoingNativeHandleGeneration != nil,
      expectRetiringHandleStopped: expectRetiringHandleStopped
    )
  }

  /// Starts a new playback episode for the media already installed on this
  /// handle. Unlike `synchronizePlaybackGeneration`, no `MediaChanged` echo is
  /// expected. Cold replay uses this boundary so already-sourced retiring
  /// callbacks remain generation-stale.
  @discardableResult
  func beginPlaybackGeneration(
    _ generation: UInt64,
    media: OpaquePointer?
  ) -> UInt64 {
    context.beginPlaybackGeneration(
      generation,
      media: media,
      nativeHandleGeneration: currentNativeHandleGeneration
    )
  }

  /// Records that the current generation is expected to stop because the
  /// wrapper issued an explicit stop request.
  func markRequestedStop(playbackGeneration: UInt64) {
    context.markRequestedStop(playbackGeneration: playbackGeneration)
  }

  func beginRequestedStopBarrier(playbackGeneration: UInt64) {
    context.beginRequestedStopBarrier(playbackGeneration: playbackGeneration)
  }

  func beginExplicitStopBarrier(playbackGeneration: UInt64) {
    context.beginExplicitStopBarrier(playbackGeneration: playbackGeneration)
  }

  func beginPlaybackStartAttempt(
    playbackGeneration: UInt64
  ) -> EventBridgeCallbackContext.PlaybackStartAttempt? {
    context.beginPlaybackStartAttempt(playbackGeneration: playbackGeneration)
  }

  func finishPlaybackStartAttempt(
    _ attempt: EventBridgeCallbackContext.PlaybackStartAttempt?,
    accepted: Bool
  ) {
    context.finishPlaybackStartAttempt(attempt, accepted: accepted)
  }

  func acceptExternalPlaybackActivation(playbackGeneration: UInt64) {
    context.acceptExternalPlaybackActivation(
      playbackGeneration: playbackGeneration
    )
  }

  func recordAcceptedPlaybackStart(playbackGeneration: UInt64) {
    context.recordAcceptedPlaybackStart(
      playbackGeneration: playbackGeneration,
      nativeHandleGeneration: currentNativeHandleGeneration
    )
  }

  func commitRecastReplacementIfCurrent(
    expectation: RecastReplacementExpectation,
    successorPlaybackGeneration: UInt64,
    preparedReattachment: PreparedReattachment
  ) -> RecastReplacementCommitResult {
    guard
      expectation.nativeHandleGeneration < UInt64.max,
      expectation.nativeHandleGeneration == currentNativeHandleGeneration,
      preparedReattachment.nativeHandleGeneration
      == expectation.nativeHandleGeneration + 1
    else { return .interrupted(.superseded) }
    return context.commitRecastReplacementIfCurrent(
      expectation: expectation,
      successorPlaybackGeneration: successorPlaybackGeneration,
      successorNativeHandleGeneration: preparedReattachment.nativeHandleGeneration
    )
  }

  func reserveRecastMutation(
    for lease: RecastReplacementLease
  ) -> RecastMutationReservation {
    context.reserveRecastMutation(for: lease)
  }

  func currentRecastInterruption(
    for lease: RecastReplacementLease
  ) -> RecastTransactionInterruption? {
    context.currentRecastInterruption(for: lease)
  }

  func finishRecastMutation(
    _ permit: RecastMutationPermit
  ) -> RecastTransactionInterruption? {
    context.finishRecastMutation(permit)
  }

  func settleRecast(
    _ lease: RecastReplacementLease
  ) -> RecastTransactionInterruption? {
    context.settleRecast(lease)
  }

  func abandonRecast(_ lease: RecastReplacementLease) {
    context.abandonRecast(lease)
  }

  /// Records timeline facts learned synchronously by the wrapper rather than
  /// through a native player event.
  func updateKnownDuration(_ duration: Duration?, playbackGeneration: UInt64) {
    context.updateKnownDuration(duration, playbackGeneration: playbackGeneration)
  }

  /// Records an accepted seek or frame step immediately, including while the
  /// native event thread is quiescent because playback is paused.
  func updateAuthoritativeTimeline(
    time: Duration,
    position: Double?,
    playbackGeneration: UInt64,
    timelineRevision: UInt64,
    timelineEmissionSequence: UInt64? = nil
  ) {
    context.updateAuthoritativeTimeline(
      time: time,
      position: position,
      playbackGeneration: playbackGeneration,
      timelineRevision: timelineRevision,
      timelineEmissionSequence: timelineEmissionSequence
    )
  }

  /// Ends the current generation without waiting for another native event.
  /// Used when shutdown or native-handle retirement makes future callbacks
  /// unobservable by construction.
  func finishCurrentPlaybackGeneration(
    cause: PlaybackTerminalCause,
    playbackGeneration: UInt64
  ) {
    context.finishPlaybackGeneration(
      playbackGeneration,
      cause: cause,
      nativeHandleGeneration: currentNativeHandleGeneration
    )
  }

  /// Marks a new authoritative timeline after native dispatch accepts.
  /// Clock samples stamped before this lock-linearized point carry a lower
  /// revision and are discarded by the consumer.
  @discardableResult
  func advanceTimelineRevision() -> UInt64 {
    context.advanceTimelineRevision()
  }

  @discardableResult
  func advanceNativeTimelineEmissionSequence() -> UInt64 {
    context.advanceNativeTimelineEmissionSequence()
  }

  /// Pushes an event through the same fan-out path the C callback uses,
  /// including subscription buffering — unlike
  /// `Player._handleEventForTesting`, which bypasses the bridge entirely.
  func _broadcastForTesting(
    _ event: PlayerEvent,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64? = nil,
    emittedTimelineRevision: UInt64? = nil,
    nativeSeekEmissionStamp: NativeSeekEmissionStamp? = nil,
    lifecycleControlEpoch: UInt64? = nil
  ) {
    context.broadcast(
      event,
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration,
      emittedTimelineRevision: emittedTimelineRevision,
      nativeSeekEmissionStamp: nativeSeekEmissionStamp,
      lifecycleControlEpoch: lifecycleControlEpoch
    )
  }

  func _broadcastEffectivePlaybackRateResolutionForTesting(
    _ effectiveRate: Float,
    nativeHandleGeneration: UInt64,
    playbackGeneration: UInt64? = nil
  ) {
    context.broadcastEffectivePlaybackRateResolution(
      effectiveRate,
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration ?? currentPlaybackGeneration
    )
  }

  /// Exercises the complete native callback ordering with a synthetic event.
  func _emitNativeEventForTesting(_ event: libvlc_event_t) {
    guard let attachmentOpaque else { return }
    withUnsafePointer(to: event) { event in
      playerEventCallback(event: event, opaque: attachmentOpaque)
    }
  }

  #if DEBUG
  /// Forces candidate preparation to fail after exactly `count` successful
  /// listener attachments. This exercises the all-or-nothing rollback without
  /// depending on a platform-specific libVLC allocation failure.
  func _forcePreparedAttachmentFailureForTesting(
    afterAttachedCount count: Int?
  ) {
    precondition(count.map { (0...Self.playerEventTypes.count).contains($0) } ?? true)
    preparedAttachmentFailureIndexForTesting.withLock { $0 = count }
    preparedAttachmentRollbackCountForTesting.withLock { $0 = 0 }
  }

  var _preparedAttachmentRollbackCountForTesting: Int {
    preparedAttachmentRollbackCountForTesting.withLock { $0 }
  }

  /// Pauses a synthetic native callback after a terminal has atomically
  /// reserved playback ownership, cause, and timeline. MainActor mutations
  /// made from this hook are therefore strictly post-entry.
  func _setNativeEventCallbackBeforePlaybackClaimHookForTesting(
    _ hook: (@Sendable () -> Void)?
  ) {
    context.setNativeEventCallbackBeforePlaybackClaimHookForTesting(hook)
  }

  /// Signals after native ordering is reserved but before a terminal attempts
  /// the playback-lifecycle lock. Hooks installed here must not wait for work
  /// that needs native emission; this seam exists only to release a deliberately
  /// contended lifecycle lock in deterministic tests.
  func _setNativeEventCallbackAfterNativeReservationHookForTesting(
    _ hook: (@Sendable () -> Void)?
  ) {
    context.setNativeEventCallbackAfterNativeReservationHookForTesting(hook)
  }

  /// Deterministic entry to the external `MediaChanged` finalizer. The pointer
  /// is identity-only and must remain valid for the duration of the test.
  @discardableResult
  func _noteExternalMediaChangedForTesting(_ media: OpaquePointer?) -> UInt64 {
    context.noteExternalMediaChanged(
      media,
      nativeHandleGeneration: currentNativeHandleGeneration
    )
  }

  /// Pauses a synthetic native callback after immutable entry attribution but
  /// before mapping/lifecycle completion. This is intentionally below the
  /// causal linearization point so tests can advance playback concurrently
  /// without fabricating a sourced generation.
  func _setNativeEventCallbackEntryHookForTesting(
    _ hook: (@Sendable () -> Void)?
  ) {
    context.setNativeEventCallbackEntryHookForTesting(hook)
  }
  #endif

  static func makePlayerEventTypes(
    effectiveRateChangedEventAvailable: Bool
  ) -> [Int32] {
    var eventTypes: [Int32] = [
      libvlc_MediaPlayerMediaChanged,
      libvlc_MediaPlayerNothingSpecial,
      libvlc_MediaPlayerOpening,
      libvlc_MediaPlayerBuffering,
      libvlc_MediaPlayerPlaying,
      libvlc_MediaPlayerPaused,
      libvlc_MediaPlayerStopped,
      libvlc_MediaPlayerStopping,
      libvlc_MediaPlayerMediaStopping,
      libvlc_MediaPlayerEncounteredError,
      libvlc_MediaPlayerTimeChanged,
      libvlc_MediaPlayerPositionChanged,
      libvlc_MediaPlayerSeekableChanged,
      libvlc_MediaPlayerPausableChanged,
      libvlc_MediaPlayerLengthChanged,
      libvlc_MediaPlayerVout,
      libvlc_MediaPlayerESAdded,
      libvlc_MediaPlayerESDeleted,
      libvlc_MediaPlayerESSelected,
      libvlc_MediaPlayerESUpdated,
      libvlc_MediaPlayerCorked,
      libvlc_MediaPlayerUncorked,
      libvlc_MediaPlayerMuted,
      libvlc_MediaPlayerUnmuted,
      libvlc_MediaPlayerAudioVolume,
      libvlc_MediaPlayerAudioDevice,
      libvlc_MediaPlayerChapterChanged,
      libvlc_MediaPlayerRecordChanged,
      libvlc_MediaPlayerTitleListChanged,
      libvlc_MediaPlayerTitleSelectionChanged,
      libvlc_MediaPlayerSnapshotTaken,
      libvlc_MediaPlayerProgramAdded,
      libvlc_MediaPlayerProgramDeleted,
      libvlc_MediaPlayerProgramSelected,
      libvlc_MediaPlayerProgramUpdated
    ].map { Int32($0.rawValue) }
    if effectiveRateChangedEventAvailable {
      eventTypes.append(Int32(libvlc_MediaPlayerRateChanged.rawValue))
    }
    return eventTypes
  }

  static var playerEventTypes: [Int32] {
    makePlayerEventTypes(
      effectiveRateChangedEventAvailable:
      swiftvlc_media_player_rate_changed_event_available()
    )
  }

  private static func attachAllEvents(
    to eventManager: OpaquePointer,
    opaque: UnsafeMutableRawPointer,
    forcedFailureAfterAttachedCount: Int? = nil,
    didRollback: (Int) -> Void = { _ in }
  ) -> [Int32]? {
    var attachedEventTypes: [Int32] = []
    for eventType in playerEventTypes {
      if attachedEventTypes.count == forcedFailureAfterAttachedCount {
        detachEvents(attachedEventTypes, from: eventManager, opaque: opaque)
        didRollback(attachedEventTypes.count)
        return nil
      }
      guard libvlc_event_attach(eventManager, eventType, playerEventCallback, opaque) == 0 else {
        detachEvents(attachedEventTypes, from: eventManager, opaque: opaque)
        didRollback(attachedEventTypes.count)
        return nil
      }
      attachedEventTypes.append(eventType)
    }
    if attachedEventTypes.count == forcedFailureAfterAttachedCount {
      detachEvents(attachedEventTypes, from: eventManager, opaque: opaque)
      didRollback(attachedEventTypes.count)
      return nil
    }
    return attachedEventTypes
  }

  private static func detachEvents(
    _ eventTypes: [Int32],
    from eventManager: OpaquePointer,
    opaque: UnsafeMutableRawPointer
  ) {
    for eventType in eventTypes {
      libvlc_event_detach(eventManager, eventType, playerEventCallback, opaque)
    }
  }
}
