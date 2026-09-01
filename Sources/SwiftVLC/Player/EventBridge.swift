import CLibVLC
import os
import Synchronization

/// Bridges libVLC C event callbacks to `AsyncStream<PlayerEvent>`.
///
/// Multi-consumer fan-out built on `Broadcaster<PlayerEvent>`. Each call
/// to `makeStream()` returns an independent `AsyncStream`. The C callback
/// reaches a retained callback context through an `Unmanaged` pointer
/// passed to libVLC's `event_attach`, then calls `broadcast(_:)` which
/// snapshots subscribers under a Mutex and yields outside the lock.
final class EventBridge: Sendable {
  private nonisolated(unsafe) var eventManager: OpaquePointer
  private let context: EventBridgeCallbackContext
  private nonisolated(unsafe) var attachmentOpaque: UnsafeMutableRawPointer?
  private nonisolated(unsafe) var attachedEventTypes: [Int32]
  private let nativeHandleGeneration = Mutex<UInt64>(1)
  private let invalidated = Mutex(false)

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

    attachedEventTypes = Self.attachEvents(to: eventManager, opaque: opaque)
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

  /// Moves the existing streams to a replacement native media player.
  ///
  /// `Player` recreates its libVLC handle after a stopped drawable-backed
  /// playback because libVLC keeps a "free vout" whose iOS window provider
  /// still points at the previous UIView. The Swift `Player.events` stream must
  /// survive that native-handle swap, so this detaches callbacks from the previous
  /// event manager and attaches the same broadcaster to the new one.
  @discardableResult
  func reattach(to newEventManager: OpaquePointer) -> UInt64 {
    let isInvalidated = invalidated.withLock { $0 }
    guard !isInvalidated, let oldAttachmentOpaque = attachmentOpaque else {
      return nativeHandleGeneration.withLock { $0 }
    }

    Self.detachEvents(attachedEventTypes, from: eventManager, opaque: oldAttachmentOpaque)
    Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(oldAttachmentOpaque).release()

    // The retiring handle cannot emit after detach returns. Clear its pending
    // terminal classification before the successor is attached, so neither an
    // old late callback nor an early successor callback can cross the reset.
    context.endCoordinator.clearForHandleReplacement()
    context.clearPendingStopForNativeHandleReplacement()

    let generation = nativeHandleGeneration.withLock { generation in
      precondition(generation < UInt64.max, "Native handle generation exhausted")
      generation += 1
      return generation
    }
    let attachment = EventBridgeCallbackAttachment(
      context: context,
      nativeHandleGeneration: generation
    )
    let newAttachmentOpaque = Unmanaged.passRetained(attachment).toOpaque()
    eventManager = newEventManager
    attachmentOpaque = newAttachmentOpaque
    attachedEventTypes = Self.attachEvents(to: newEventManager, opaque: newAttachmentOpaque)
    return generation
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

  /// Playback-control boundary already accepted by the callback lane.
  var currentLifecycleControlEpoch: UInt64 {
    context.currentLifecycleControlEpoch
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
    outgoingNativeHandleGeneration: UInt64? = nil
  ) -> UInt64 {
    context.synchronizePlaybackGeneration(
      generation,
      media: media,
      nativeHandleGeneration: outgoingNativeHandleGeneration
        ?? currentNativeHandleGeneration,
      retiringNativeHandle: outgoingNativeHandleGeneration != nil
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

  /// Exercises the complete native callback ordering with a synthetic event.
  func _emitNativeEventForTesting(_ event: libvlc_event_t) {
    guard let attachmentOpaque else { return }
    withUnsafePointer(to: event) { event in
      playerEventCallback(event: event, opaque: attachmentOpaque)
    }
  }

  #if DEBUG
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

  private static func attachEvents(
    to eventManager: OpaquePointer,
    opaque: UnsafeMutableRawPointer
  ) -> [Int32] {
    var attachedEventTypes: [Int32] = []
    for eventType in playerEventTypes
      where libvlc_event_attach(eventManager, eventType, playerEventCallback, opaque) == 0 {
      attachedEventTypes.append(eventType)
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
