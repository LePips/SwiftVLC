#if os(iOS)
import Synchronization

/// Thread-safe handoff slot between two libVLC video-output generations.
///
/// The engine closes and opens its PiP module on video-output threads. UIKit
/// and ``PiPController`` remain main-actor isolated, so this slot only moves an
/// opaque Objective-C controller and immutable generation values under a
/// mutex. Event publication hops to the main actor after the lock is released.
final class IOSNativePiPContinuityCoordinator: @unchecked Sendable {
  private final class WeakController: @unchecked Sendable {
    weak var value: AnyObject?

    init(_ value: AnyObject) {
      self.value = value
    }
  }

  enum Transition: Sendable {
    case rebuilding(
      previous: PlaybackGeneration,
      successor: PlaybackGeneration
    )
    case restored(
      previous: PlaybackGeneration,
      successor: PlaybackGeneration,
      elapsed: Duration
    )
    case timedOut(
      previous: PlaybackGeneration,
      successor: PlaybackGeneration,
      elapsed: Duration
    )
  }

  private struct Pending: @unchecked Sendable {
    let controllerIdentity: ObjectIdentifier
    let weakController: WeakController
    var controller: AnyObject?
    let previousMediaGeneration: PlaybackGeneration
    var mediaGeneration: PlaybackGeneration
    let startedAt: ContinuousClock.Instant
  }

  private struct State: @unchecked Sendable {
    var readyMediaGeneration: PlaybackGeneration?
    /// Rejects late readiness from expired handoffs without preventing a
    /// freshly-created controller from serving the same media generation.
    var timedOutThroughGeneration: PlaybackGeneration?
    var lastTimedOutController: WeakController?
    var pending: Pending?
  }

  private let clock = ContinuousClock()
  private let state = Mutex(State())
  private let emit: @Sendable (Transition) -> Void

  init(emit: @escaping @Sendable (Transition) -> Void) {
    self.emit = emit
  }

  /// Holds an active native window controller only when the player has
  /// already advanced to a different media generation.
  func preserve(
    _ controller: AnyObject,
    for mediaGeneration: PlaybackGeneration?
  ) -> Bool {
    guard let mediaGeneration else { return false }
    let startedAt = clock.now
    let result = state.withLock { state -> (accepted: Bool, transition: Transition?) in
      if var pending = state.pending {
        guard
          pending.controllerIdentity == ObjectIdentifier(controller),
          mediaGeneration >= pending.mediaGeneration
        else { return (false, nil) }

        pending.controller = controller
        let transition: Transition?
        if mediaGeneration > pending.mediaGeneration {
          pending.mediaGeneration = mediaGeneration
          transition = .rebuilding(
            previous: pending.previousMediaGeneration,
            successor: mediaGeneration
          )
        } else {
          transition = nil
        }
        state.pending = pending
        return (true, transition)
      }

      guard
        let previous = state.readyMediaGeneration,
        previous != mediaGeneration
      else { return (false, nil) }

      state.pending = Pending(
        controllerIdentity: ObjectIdentifier(controller),
        weakController: WeakController(controller),
        controller: controller,
        previousMediaGeneration: previous,
        mediaGeneration: mediaGeneration,
        startedAt: startedAt
      )
      return (
        true,
        .rebuilding(previous: previous, successor: mediaGeneration)
      )
    }

    if let transition = result.transition {
      emit(transition)
    }
    return result.accepted
  }

  /// Transfers the held controller into the successor engine module while
  /// retaining the pending identity until its new display layer is ready.
  func takePreservedController(
    for mediaGeneration: PlaybackGeneration?
  ) -> AnyObject? {
    guard let mediaGeneration else { return nil }
    let result = state.withLock { state -> (controller: AnyObject?, transition: Transition?) in
      guard
        var pending = state.pending,
        let controller = pending.controller,
        mediaGeneration >= pending.mediaGeneration
      else { return (nil, nil) }

      let transition: Transition?
      if mediaGeneration > pending.mediaGeneration {
        pending.mediaGeneration = mediaGeneration
        transition = .rebuilding(
          previous: pending.previousMediaGeneration,
          successor: mediaGeneration
        )
      } else {
        transition = nil
      }
      pending.controller = nil
      state.pending = pending
      return (controller, transition)
    }
    if let transition = result.transition {
      emit(transition)
    }
    return result.controller
  }

  /// Records an ordinary ready generation or completes a preserved handoff.
  func didBecomeReady(
    _ controller: AnyObject,
    mediaGeneration: PlaybackGeneration?
  ) {
    guard let mediaGeneration else { return }
    let now = clock.now
    let transition = state.withLock { state -> Transition? in
      guard let pending = state.pending else {
        if let ready = state.readyMediaGeneration, mediaGeneration <= ready {
          return nil
        }
        if let timedOut = state.timedOutThroughGeneration {
          if mediaGeneration < timedOut {
            return nil
          }
          if
            mediaGeneration == timedOut,
            state.lastTimedOutController?.value === controller {
            return nil
          }
        }
        state.readyMediaGeneration = mediaGeneration
        if
          let timedOut = state.timedOutThroughGeneration,
          mediaGeneration >= timedOut {
          state.lastTimedOutController = nil
        }
        return nil
      }
      guard
        pending.controllerIdentity == ObjectIdentifier(controller),
        pending.mediaGeneration == mediaGeneration
      else { return nil }

      state.pending = nil
      state.readyMediaGeneration = mediaGeneration
      return .restored(
        previous: pending.previousMediaGeneration,
        successor: pending.mediaGeneration,
        elapsed: pending.startedAt.duration(to: now)
      )
    }
    if let transition {
      emit(transition)
    }
  }

  /// Completes the handoff timeout selected by the native controller. The
  /// Objective-C timer is authoritative so a successful `prepare` and timeout
  /// cannot publish contradictory terminal outcomes.
  func didTimeOut(_ controller: AnyObject) {
    let now = clock.now
    let transition = state.withLock { state -> Transition? in
      guard
        let pending = state.pending,
        pending.controllerIdentity == ObjectIdentifier(controller)
      else { return nil }
      state.pending = nil
      if
        state.timedOutThroughGeneration.map({ pending.mediaGeneration > $0 })
        ?? true {
        state.timedOutThroughGeneration = pending.mediaGeneration
        state.lastTimedOutController = pending.weakController
      }
      return .timedOut(
        previous: pending.previousMediaGeneration,
        successor: pending.mediaGeneration,
        elapsed: pending.startedAt.duration(to: now)
      )
    }
    if let transition {
      emit(transition)
    }
  }
}
#endif
