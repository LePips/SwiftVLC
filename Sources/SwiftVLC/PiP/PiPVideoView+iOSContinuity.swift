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

  static let defaultRebuildTimeout: Duration = .seconds(3)

  private struct Pending: @unchecked Sendable {
    let token: UInt64
    let controllerIdentity: ObjectIdentifier
    let weakController: WeakController
    var controller: AnyObject?
    let previousMediaGeneration: PlaybackGeneration
    let mediaGeneration: PlaybackGeneration
    let startedAt: ContinuousClock.Instant
  }

  private struct State: @unchecked Sendable {
    var nextToken: UInt64 = 0
    var readyMediaGeneration: PlaybackGeneration?
    /// Rejects late readiness from expired handoffs without preventing a
    /// freshly-created controller from serving the same media generation.
    var timedOutThroughGeneration: PlaybackGeneration?
    var lastTimedOutController: WeakController?
    var pending: Pending?
  }

  private let clock = ContinuousClock()
  private let state = Mutex(State())
  private let rebuildTimeout: Duration
  private let emit: @Sendable (Transition) -> Void

  init(
    rebuildTimeout: Duration = IOSNativePiPContinuityCoordinator.defaultRebuildTimeout,
    emit: @escaping @Sendable (Transition) -> Void
  ) {
    self.rebuildTimeout = rebuildTimeout
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
    let transition = state.withLock { state -> Transition? in
      guard
        state.pending == nil,
        let previous = state.readyMediaGeneration,
        previous != mediaGeneration
      else { return nil }

      state.nextToken &+= 1
      precondition(state.nextToken != 0, "PiP continuity token exhausted")
      state.pending = Pending(
        token: state.nextToken,
        controllerIdentity: ObjectIdentifier(controller),
        weakController: WeakController(controller),
        controller: controller,
        previousMediaGeneration: previous,
        mediaGeneration: mediaGeneration,
        startedAt: startedAt
      )
      return .rebuilding(previous: previous, successor: mediaGeneration)
    }

    guard let transition else { return false }
    emit(transition)
    let token = state.withLock { $0.pending?.token }
    guard let token else { return false }
    Task { [weak self] in
      guard let self else { return }
      try? await Task.sleep(for: rebuildTimeout)
      timeOut(token: token)
    }
    return true
  }

  /// Transfers the held controller into the successor engine module while
  /// retaining the pending identity until its new display layer is ready.
  func takePreservedController() -> AnyObject? {
    state.withLock { state in
      let controller = state.pending?.controller
      state.pending?.controller = nil
      return controller
    }
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

  private func timeOut(token: UInt64) {
    let now = clock.now
    let transition = state.withLock { state -> Transition? in
      guard let pending = state.pending, pending.token == token else { return nil }
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
