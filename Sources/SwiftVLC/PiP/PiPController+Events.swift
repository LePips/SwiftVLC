#if os(iOS) || os(macOS)

/// The reason a Picture-in-Picture window stopped (or is stopping).
///
/// Reason fidelity depends on which PiP backend is driving the window —
/// see ``PiPController/pipEvents`` for the per-backend guarantees and
/// the resolution rules.
public enum PiPStopReason: Sendable, Equatable {
  /// The user dismissed the PiP window with its close (X) affordance.
  ///
  /// Reported when SwiftVLC owns or successfully bridges the full
  /// `AVPictureInPictureController` delegate and no restore request, failure,
  /// end-of-media, or compatibility fallback explains the stop.
  case userClosed

  /// The user tapped the PiP window's restore ("return to app")
  /// affordance. Fires alongside ``PiPController/onRestoreUserInterface``.
  case restoreRequested

  /// The stop follows a failed PiP start (see
  /// ``PiPEvent/failedToStart(_:)``) or a terminal playback/rendering error.
  case failure

  /// Playback reached the end of the media while PiP was up.
  case mediaEnded

  /// No version-1-compatible reason describes the stop. This includes an
  /// explicit ``PiPController/stop()`` call, native-controller replacement,
  /// and unsupported native libVLC delegate revisions. The attributed
  /// ``PiPController/pipEventEnvelopes`` stream exposes the more precise
  /// ``PiPEventEnvelope/stopCause`` when it is known.
  case unknown
}

/// An extensible cause for a Picture-in-Picture stop.
///
/// ``PiPStopReason`` is a version-1 compatibility enum: adding cases would
/// break exhaustive client switches. The attributed event stream therefore
/// carries this raw-representable value alongside its compatibility event.
/// Applications should compare against the known static values and retain a
/// fallback for values introduced by a future SwiftVLC release.
public struct PiPStopCause: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
  /// Stable textual identity for the cause.
  public let rawValue: String

  /// Creates a stop cause from its textual identity.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// The user dismissed the PiP window with its close affordance.
  public static let userClosed = Self(rawValue: "userClosed")
  /// The user requested restoration of the application's playback UI.
  public static let restoreRequested = Self(rawValue: "restoreRequested")
  /// PiP start, playback, or rendering failed.
  public static let failure = Self(rawValue: "failure")
  /// Playback reached the natural end of the media.
  public static let mediaEnded = Self(rawValue: "mediaEnded")
  /// The application explicitly called ``PiPController/stop()``.
  public static let programmatic = Self(rawValue: "programmatic")
  /// libVLC replaced the native AVKit controller while PiP was active.
  public static let controllerReplaced = Self(rawValue: "controllerReplaced")
  /// No discriminating signal was available.
  public static let unknown = Self(rawValue: "unknown")

  public var description: String {
    rawValue
  }
}

extension PiPStopCause {
  var compatibilityReason: PiPStopReason {
    switch self {
    case .userClosed: .userClosed
    case .restoreRequested: .restoreRequested
    case .failure: .failure
    case .mediaEnded: .mediaEnded
    case .programmatic, .controllerReplaced, .unknown: .unknown
    default: .unknown
    }
  }

  init(compatibilityReason: PiPStopReason) {
    self = switch compatibilityReason {
    case .userClosed: .userClosed
    case .restoreRequested: .restoreRequested
    case .failure: .failure
    case .mediaEnded: .mediaEnded
    case .unknown: .unknown
    }
  }
}

/// A Picture-in-Picture lifecycle transition, delivered on
/// ``PiPController/pipEvents``.
public enum PiPEvent: Sendable {
  /// AVKit is about to present the PiP window.
  case willStart

  /// The PiP window is up.
  case didStart

  /// The PiP window is about to close. `reason` is the best-known
  /// reason *at this instant*; AVKit does not document whether the
  /// restore callback precedes this event, so prefer the reason
  /// attached to the subsequent ``didStop(reason:)``, which is
  /// authoritative.
  case willStop(reason: PiPStopReason)

  /// The PiP window closed.
  case didStop(reason: PiPStopReason)

  /// AVKit failed to start PiP. Carries the underlying AVKit error.
  case failedToStart(any Error)
}

extension PiPEvent {
  var compatibilityStopCause: PiPStopCause? {
    switch self {
    case .willStop(let reason), .didStop(let reason):
      PiPStopCause(compatibilityReason: reason)
    case .willStart, .didStart, .failedToStart:
      nil
    }
  }
}

/// A Picture-in-Picture lifecycle transition paired with the controller and
/// media generations that own it.
///
/// AVKit callbacks are asynchronous. A start failure or stop can arrive after
/// the player has adopted another media or the direct backend has replaced its
/// AVKit controller. These identities let queued consumers reject a transition
/// that no longer belongs to their current session.
///
/// Controller-generation ordering is meaningful only within the owning
/// ``PiPController``. Its streams finish when that owner deinits, so a view
/// reconstruction must replace the subscription along with the controller.
public struct PiPEventEnvelope: Sendable {
  /// The lifecycle transition reported by AVKit or the native backend.
  public let event: PiPEvent
  /// The precise stop cause for a `willStop` or `didStop` event.
  ///
  /// This is `nil` for start and start-failure events. It can be more specific
  /// than the version-1-compatible reason carried by ``event``; for example,
  /// programmatic and controller-replacement stops use `.unknown` there while
  /// this property reports ``PiPStopCause/programmatic`` or
  /// ``PiPStopCause/controllerReplaced``.
  public let stopCause: PiPStopCause?
  /// Media session active when the PiP lifecycle began.
  public let mediaGeneration: PlaybackGeneration
  /// AVKit controller or native-backend generation that emitted the event.
  /// Ordering is meaningful only within the owning ``PiPController``.
  public let controllerGeneration: UInt64
}

// MARK: - Lifecycle event stream

extension PiPController {
  struct PiPLifecycleAttribution {
    let mediaGeneration: PlaybackGeneration
    let controllerGeneration: UInt64
    let sequence: UInt64
  }

  struct FailedPiPLifecycle {
    let attribution: PiPLifecycleAttribution
    let stopReason: PiPStopCause
    var willStopObserved = false
  }

  enum PiPLifecycleAttributionPhase: Equatable {
    case idle
    case awaitingStart
    case started
    case stopping
  }

  /// A stream of Picture-in-Picture lifecycle events.
  ///
  /// Each access returns an independent, unbounded stream — lifecycle
  /// events are one-shot and low-rate, so no event is ever dropped for
  /// a live subscriber. Streams finish when the controller deinits.
  ///
  /// ## Backend fidelity
  ///
  /// On the **sample-buffer path** (a directly constructed
  /// `PiPController`), SwiftVLC owns the `AVPictureInPictureController`
  /// delegate and every case is delivered, including
  /// ``PiPEvent/willStart``, ``PiPEvent/willStop(reason:)`` and
  /// ``PiPEvent/failedToStart(_:)`` with the underlying AVKit error.
  ///
  /// On the **native drawable path** (``PiPVideoView``), SwiftVLC installs a
  /// forwarding bridge in front of libVLC's AVKit delegate. The original
  /// delegate still receives every callback, while this stream receives the
  /// complete ordered lifecycle, underlying start failure, restore request,
  /// and authoritative stop cause. If a future libVLC revision exposes no
  /// delegate to bridge, SwiftVLC logs the incompatibility and retains the
  /// active-state fallback with ``PiPStopCause/unknown``.
  ///
  /// ## Stop-reason resolution
  ///
  /// ``PiPEventEnvelope/stopCause`` is resolved in this order:
  ///
  /// 1. The **first discriminating signal** observed for the in-flight
  ///    stop wins and is never overwritten: the restore callback
  ///    records ``PiPStopCause/restoreRequested``, a start or playback failure
  ///    records ``PiPStopCause/failure``, a programmatic ``stop()`` records
  ///    ``PiPStopCause/programmatic``, and native replacement records
  ///    ``PiPStopCause/controllerReplaced``. In practice these
  ///    signals are mutually exclusive, which yields the effective
  ///    precedence `restoreRequested` > `failure` over the fallbacks
  ///    below.
  /// 2. Otherwise, if the player reported a natural end of media
  ///    (``Player/didReachEnd``), the stop is ``PiPStopCause/mediaEnded``.
  /// 3. Otherwise ``PiPStopCause/userClosed`` — on the sample-buffer
  ///    path the close (X) button is the only remaining cause.
  ///
  /// ``PiPEventEnvelope/stopCause`` carries the best-known cause at
  /// emission time. AVKit guarantees the restore callback completes
  /// before the stop finishes (so `didStop` always sees it) but does
  /// not document its order relative to `willStop`; treat the `didStop`
  /// envelope's cause as authoritative. The compatibility ``PiPEvent`` maps
  /// programmatic, controller-replacement, and future causes to
  /// ``PiPStopReason/unknown``.
  public var pipEvents: AsyncStream<PiPEvent> {
    pipEventBroadcaster.subscribe(policy: .unbounded)
  }

  /// Lossless PiP lifecycle events carrying controller and media identity.
  ///
  /// Prefer this stream when work can remain queued across a player media
  /// change or an AVKit backend-controller replacement, or when the precise
  /// extensible ``PiPEventEnvelope/stopCause`` matters. Each access returns an
  /// independent unbounded stream, and streams finish when this controller
  /// deinits, matching ``pipEvents``.
  public var pipEventEnvelopes: AsyncStream<PiPEventEnvelope> {
    pipEventEnvelopeBroadcaster.subscribe(policy: .unbounded)
  }

  /// Broadcasts one transition onto the compatibility and attributed streams.
  /// The lifecycle's media generation is captured by an accepted explicit
  /// start, or by the first callback for a system-initiated start.
  func publishPiPEvent(
    _ event: PiPEvent,
    stopCause: PiPStopCause? = nil,
    mediaGeneration mediaGenerationOverride: PlaybackGeneration? = nil
  ) {
    let attribution: PiPLifecycleAttribution
    var consumedFailedLifecycle = false
    switch event {
    case .willStart:
      // A failed attempt's trailing stop can arrive after its retry reaches
      // willStart. Keep the failed identity until that stop is consumed or the
      // retry reaches didStart, which is the boundary that retires a failure
      // with no trailing terminal callback.
      // Preserve an accepted request's identity even if the player adopted
      // successor media before AVKit replied. An auto-start has no accepted
      // request, so it begins a fresh lifecycle here.
      if
        pipLifecycleAttribution == nil
        || pipLifecycleAttribution?.controllerGeneration != pipControllerGeneration {
        capturePiPLifecycleAttribution(mediaGeneration: mediaGenerationOverride)
      }
      pipLifecycleAttributionPhase = .awaitingStart
      attribution = currentPiPLifecycleAttribution(mediaGeneration: mediaGenerationOverride)
    case .didStart:
      // Defensive counterpart to `willStart`: the native path synthesizes
      // didStart directly, and a backend callback should still promote the
      // accepted successor if no willStart was observable.
      if
        pipLifecycleAttribution == nil
        || pipLifecycleAttribution?.controllerGeneration != pipControllerGeneration {
        capturePiPLifecycleAttribution(mediaGeneration: mediaGenerationOverride)
      }
      pipLifecycleAttributionPhase = .started
      attribution = currentPiPLifecycleAttribution(mediaGeneration: mediaGenerationOverride)
      // A successful newer start is a terminal progress boundary for an
      // older failed attempt whose optional stop never arrived. Do not retire
      // a newer queued failure when AVKit repeats didStart for the older
      // lifecycle that is still stopping.
      failedPiPLifecycles.removeAll {
        $0.attribution.sequence < attribution.sequence && !$0.willStopObserved
      }
    case .willStop:
      if let failedIndex = failedLifecycleIndexOwningNextWillStop {
        let failedPiPLifecycle = failedPiPLifecycles[failedIndex]
        attribution = failedPiPLifecycle.attribution
        // Once AVKit has promised a terminal callback for this failed
        // lifecycle, a newer didStart must not retire it as an omitted stop.
        // Keep it until the matching didStop consumes the slot.
        failedPiPLifecycles[failedIndex].willStopObserved = true
      } else {
        pipLifecycleAttributionPhase = .stopping
        attribution = currentPiPLifecycleAttribution(mediaGeneration: mediaGenerationOverride)
      }
    case .didStop:
      if failedLifecycleOwnsNextStop, let failedPiPLifecycle = failedPiPLifecycles.first {
        attribution = failedPiPLifecycle.attribution
        failedPiPLifecycles.removeFirst()
        consumedFailedLifecycle = true
      } else {
        attribution = currentPiPLifecycleAttribution(mediaGeneration: mediaGenerationOverride)
      }
    case .failedToStart:
      if
        pipLifecycleAttributionPhase == .started
        || pipLifecycleAttributionPhase == .stopping,
        let queuedPiPStartAttribution {
        // An already-started lifecycle cannot own a later start-failure
        // callback. The failure belongs to the accepted retry, while the
        // older lifecycle remains current until its own didStop arrives.
        attribution = queuedPiPStartAttribution
        self.queuedPiPStartAttribution = nil
        recordFailedPiPLifecycle(
          attribution: attribution,
          stopReason: .failure
        )
      } else {
        attribution = currentPiPLifecycleAttribution(mediaGeneration: mediaGenerationOverride)
        // A failed start is terminal even when an earlier discriminating
        // signal already won the stop reason. Preserve that winning reason
        // alongside the retired lifecycle instead of leaving a dead awaiting
        // start in the current slot forever.
        recordFailedPiPLifecycle(
          attribution: attribution,
          stopReason: pendingStopReason ?? .failure
        )
        pendingStopReason = nil
        clearCurrentPiPLifecycleAttribution()
        promoteQueuedPiPStartAttributionIfNeeded()
      }
    }

    let envelope = PiPEventEnvelope(
      event: event,
      stopCause: stopCause ?? event.compatibilityStopCause,
      mediaGeneration: attribution.mediaGeneration,
      controllerGeneration: attribution.controllerGeneration
    )
    pipEventBroadcaster.broadcast(event)
    pipEventEnvelopeBroadcaster.broadcast(envelope)

    if case .didStop = event {
      if !consumedFailedLifecycle {
        pendingStopReason = nil
        clearCurrentPiPLifecycleAttribution()
      }
      // A failed-to-start callback clears the failed lifecycle before its
      // optional trailing stop arrives. That stop still releases a retry
      // accepted while the old lifecycle was stopping. Conversely, when an
      // independently accepted retry is already current, promotion must not
      // overwrite it.
      promoteQueuedPiPStartAttributionIfNeeded()
    }
  }

  /// Publishes a native transition that crossed a controller handoff without
  /// consuming lifecycle state the successor may already have created. The
  /// backend supplies the media identity captured at signal time; only the
  /// public envelope/compatibility streams need to inherit the new owner's
  /// controller generation.
  func publishTransferredNativePiPEvent(
    _ event: PiPEvent,
    stopCause: PiPStopCause? = nil,
    mediaGeneration: PlaybackGeneration?
  ) {
    let attribution = makePiPLifecycleAttribution(mediaGeneration: mediaGeneration)
    pipEventBroadcaster.broadcast(event)
    pipEventEnvelopeBroadcaster.broadcast(PiPEventEnvelope(
      event: event,
      stopCause: stopCause ?? event.compatibilityStopCause,
      mediaGeneration: attribution.mediaGeneration,
      controllerGeneration: attribution.controllerGeneration
    ))
  }

  private func currentPiPLifecycleAttribution(
    mediaGeneration: PlaybackGeneration?
  ) -> PiPLifecycleAttribution {
    if
      let pipLifecycleAttribution,
      pipLifecycleAttribution.controllerGeneration == pipControllerGeneration {
      return pipLifecycleAttribution
    }
    return capturePiPLifecycleAttribution(mediaGeneration: mediaGeneration)
  }

  private func clearCurrentPiPLifecycleAttribution() {
    pipLifecycleAttribution = nil
    pipLifecycleAttributionPhase = .idle
  }

  /// Clears a stop reason recorded while no lifecycle existed. A reason tied
  /// to an accepted or already-signalled lifecycle must survive `willStart`:
  /// an application may stop an accepted retry before AVKit reports its start.
  func clearUnownedStopReasonBeforeStart() {
    guard
      pipLifecycleAttributionPhase == .idle,
      pipLifecycleAttribution == nil
    else { return }
    pendingStopReason = nil
  }

  /// Captures attribution only when the backend confirms that it actually
  /// issued the request. Refused starts cannot later own a lifecycle callback.
  func noteAcceptedPiPStartRequest(_ result: PiPStartResult) -> PiPStartResult {
    guard result == .accepted else { return result }
    // `stop()` records a reason even while idle so it cannot miss a start
    // animation that AVKit has not reported yet. If there is demonstrably no
    // lifecycle (including no failed attribution awaiting its trailing stop),
    // that reason belongs to nothing and must not make this new request look
    // like an overlapping retry.
    if
      pipLifecycleAttributionPhase == .idle,
      pipLifecycleAttribution == nil {
      pendingStopReason = nil
    }
    let currentLifecycleIsStopping = pipLifecycleAttributionPhase == .stopping
      || (pendingStopReason != nil && failedPiPLifecycles.isEmpty)
    if pipLifecycleAttribution != nil, currentLifecycleIsStopping {
      if queuedPiPStartAttribution == nil {
        queuedPiPStartAttribution = makePiPLifecycleAttribution()
      }
      return result
    }
    switch pipLifecycleAttributionPhase {
    case .idle, .stopping:
      capturePiPLifecycleAttribution()
      pipLifecycleAttributionPhase = .awaitingStart
    case .awaitingStart:
      #if os(iOS)
      if let nativeBackend, !nativeBackend.isActive, !isActive {
        // The native backend cannot observe AVKit's failed-to-start callback.
        // A later accepted request while still inactive therefore supersedes
        // the unobservable attempt instead of preserving it forever.
        capturePiPLifecycleAttribution()
      }
      #else
      return result
      #endif
    case .started:
      // Repeating start while AVKit is active still issues the backend method,
      // but it does not begin a new PiP lifecycle.
      break
    }
    return result
  }

  @discardableResult
  func capturePiPLifecycleAttribution(
    mediaGeneration: PlaybackGeneration? = nil
  ) -> PiPLifecycleAttribution {
    let attribution = makePiPLifecycleAttribution(mediaGeneration: mediaGeneration)
    pipLifecycleAttribution = attribution
    return attribution
  }

  private func makePiPLifecycleAttribution(
    mediaGeneration: PlaybackGeneration? = nil
  ) -> PiPLifecycleAttribution {
    pipLifecycleSequence &+= 1
    return PiPLifecycleAttribution(
      mediaGeneration: mediaGeneration ?? player.generation,
      controllerGeneration: pipControllerGeneration,
      sequence: pipLifecycleSequence
    )
  }

  private func promoteQueuedPiPStartAttributionIfNeeded() {
    guard
      pipLifecycleAttribution == nil,
      let queuedPiPStartAttribution
    else { return }
    pipLifecycleAttribution = queuedPiPStartAttribution
    self.queuedPiPStartAttribution = nil
    pipLifecycleAttributionPhase = .awaitingStart
  }

  /// Saves a failed start in accepted-request order. Reaching a newer failed
  /// start proves that any older failure without `willStop` omitted its
  /// optional terminal callback. A failure for which AVKit already emitted
  /// `willStop` remains queued until its matching `didStop` arrives.
  private func recordFailedPiPLifecycle(
    attribution: PiPLifecycleAttribution,
    stopReason: PiPStopCause
  ) {
    failedPiPLifecycles.removeAll {
      $0.attribution.sequence < attribution.sequence && !$0.willStopObserved
    }
    if
      let existingIndex = failedPiPLifecycles.firstIndex(where: {
        $0.attribution.sequence == attribution.sequence
      }) {
      guard !failedPiPLifecycles[existingIndex].willStopObserved else { return }
      failedPiPLifecycles[existingIndex] = FailedPiPLifecycle(
        attribution: attribution,
        stopReason: stopReason
      )
      return
    }
    failedPiPLifecycles.append(FailedPiPLifecycle(
      attribution: attribution,
      stopReason: stopReason
    ))
  }

  /// Resolves the media identity a native backend must persist while active.
  /// An accepted explicit request owns the lifecycle even when the native
  /// active signal arrives after the player has adopted successor media. An
  /// activation from a replacement native window controller cannot have been
  /// caused by a request issued to the previous controller, so it begins a
  /// system-initiated lifecycle at signal time instead.
  func attributedNativePiPStartMediaGeneration(
    signaledMediaGeneration: PlaybackGeneration?,
    preservesAcceptedRequest: Bool
  ) -> PlaybackGeneration {
    if !preservesAcceptedRequest {
      return capturePiPLifecycleAttribution(
        mediaGeneration: signaledMediaGeneration
      ).mediaGeneration
    }
    return currentPiPLifecycleAttribution(
      mediaGeneration: signaledMediaGeneration
    ).mediaGeneration
  }

  /// Resolves an iOS native active signal against the exact accepted request
  /// snapshotted when that signal arrived. The request generation is passed by
  /// value so another accepted start during the callback's main-actor hop
  /// cannot replace its provenance.
  func attributedNativePiPStartMediaGeneration(
    signaledMediaGeneration: PlaybackGeneration?,
    acceptedRequestMediaGeneration: PlaybackGeneration?
  ) -> PlaybackGeneration {
    capturePiPLifecycleAttribution(
      mediaGeneration: acceptedRequestMediaGeneration ?? signaledMediaGeneration
    ).mediaGeneration
  }

  func adoptActivePiPLifecycleAttribution(
    mediaGeneration: PlaybackGeneration?
  ) {
    capturePiPLifecycleAttribution(mediaGeneration: mediaGeneration)
    pipLifecycleAttributionPhase = .started
  }

  func clearPiPLifecycleAttribution() {
    clearCurrentPiPLifecycleAttribution()
    failedPiPLifecycles.removeAll(keepingCapacity: true)
    queuedPiPStartAttribution = nil
  }

  /// The current Picture in Picture state, followed by every subsequent
  /// change.
  ///
  /// ``pipEvents`` carries transitions only, so a subscriber that attaches
  /// after PiP has started learns nothing until it stops. Auto-start makes that
  /// the common case rather than an edge one: the system can begin PiP before
  /// any application code has subscribed, and that start is simply missed.
  ///
  /// This stream opens with the current ``PiPSnapshot`` instead. Late
  /// subscribers converge on the same ``PiPSnapshot/revision`` without waiting
  /// for another transition, and because the flags travel as one value a
  /// subscriber never sees a combination that was not simultaneously true.
  ///
  /// Unbounded, like ``pipEvents``: a stalled consumer must not silently drop a
  /// state it will never be told about again.
  public var pipSnapshots: AsyncStream<PiPSnapshot> {
    pipSnapshotBroadcaster.subscribeReplayingLatest(policy: .unbounded)
  }

  /// Records the best-known reason for the in-flight stop. First
  /// discriminating signal wins; later signals never overwrite it (see
  /// ``pipEvents`` for the resulting precedence).
  func notePendingStopReason(_ reason: PiPStopCause) {
    guard pendingStopReason == nil else { return }
    pendingStopReason = reason
  }

  /// Resolves the stop reason for the in-flight stop without clearing it. A
  /// failed attempt awaiting its optional trailing stop wins before the
  /// independently current lifecycle's reason; otherwise use that current
  /// reason, natural end of media, or the user's close affordance.
  func resolveStopReason(
    mediaGeneration: PlaybackGeneration? = nil
  ) -> PiPStopCause {
    if failedLifecycleOwnsNextStop, let failedPiPLifecycle = failedPiPLifecycles.first {
      return failedPiPLifecycle.stopReason
    }
    if let pendingStopReason {
      return pendingStopReason
    }
    if let terminalReason = terminalStopReason(for: mediaGeneration) {
      return terminalReason
    }
    return .userClosed
  }

  /// Resolves a `willStop` against the oldest lifecycle that has not already
  /// observed that callback. A failed lifecycle remains first for `didStop`
  /// after its own `willStop`, but must not steal a distinct `willStop` from
  /// an active retry during that delay.
  func resolveWillStopReason(
    mediaGeneration: PlaybackGeneration? = nil
  ) -> PiPStopCause {
    if let failedIndex = failedLifecycleIndexOwningNextWillStop {
      return failedPiPLifecycles[failedIndex].stopReason
    }
    if let pendingStopReason {
      return pendingStopReason
    }
    if let terminalReason = terminalStopReason(for: mediaGeneration) {
      return terminalReason
    }
    return .userClosed
  }

  /// Maps only a terminal fact frozen against the lifecycle's own media
  /// generation. `Player.state` is intentionally not a fallback: `load(_:)`
  /// adopts a successor generation synchronously while the observable state
  /// can remain `.error` until libVLC publishes its next transition.
  private func terminalStopReason(
    for mediaGeneration: PlaybackGeneration?
  ) -> PiPStopCause? {
    let generation = mediaGeneration
      ?? pipLifecycleAttribution?.mediaGeneration
      ?? player.generation
    return switch player.terminalCause(for: generation) {
    case .naturalEnd: .mediaEnded
    case .failure: .failure
    case .requestedStop, .replacement, .cancellation,
         .unknownNativeStop: nil
    case nil:
      // `_handleEventForTesting(.endReached)` deliberately bypasses the
      // native terminal-outcome bridge. The observable is still safe as a
      // natural-end fallback because `load(_:)` clears it synchronously,
      // unlike the deliberately retained playback state.
      generation == player.generation && player.didReachEnd
        ? .mediaEnded
        : nil
    }
  }

  /// The failed lifecycle that owns the next `willStop`, if any. Unlike
  /// `didStop`, this skips failed entries for which `willStop` was already
  /// observed and compares the next unobserved entry with the current
  /// lifecycle's accepted-start sequence.
  private var failedLifecycleIndexOwningNextWillStop: Int? {
    guard
      let failedIndex = failedPiPLifecycles.firstIndex(where: {
        !$0.willStopObserved
      }) else { return nil }
    guard let pipLifecycleAttribution else { return failedIndex }
    if pipLifecycleAttributionPhase == .stopping {
      return failedIndex
    }
    return failedPiPLifecycles[failedIndex].attribution.sequence
      < pipLifecycleAttribution.sequence
      ? failedIndex
      : nil
  }

  /// Whether the oldest lifecycle still awaiting a terminal stop is the
  /// failed slot rather than the current slot. AVKit does not attach identity
  /// to didStop, so accepted-start sequence is the only reliable discriminator
  /// when a retry fails while an older session is still stopping.
  private var failedLifecycleOwnsNextStop: Bool {
    guard let failedPiPLifecycle = failedPiPLifecycles.first else { return false }
    guard let pipLifecycleAttribution else { return true }
    return failedPiPLifecycle.attribution.sequence < pipLifecycleAttribution.sequence
  }
}

#endif
