#if os(iOS)
import Dispatch
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
    struct ExpectedHandoff: @unchecked Sendable {
      let mediaGeneration: PlaybackGeneration
      let signal: DispatchSemaphore
    }

    var readyMediaGeneration: PlaybackGeneration?
    /// Rejects late readiness from expired handoffs without preventing a
    /// freshly-created controller from serving the same media generation.
    var timedOutThroughGeneration: PlaybackGeneration?
    var lastTimedOutController: WeakController?
    var pending: Pending?
    var expectedHandoff: ExpectedHandoff?
  }

  private let clock = ContinuousClock()
  /// The successor vout opens on a different native thread from retirement of
  /// its predecessor. Waiting here is bounded well below the public 5-second
  /// continuity budget and happens only when active PiP has explicitly staged
  /// a replacement handoff.
  private let expectedHandoffWait: DispatchTimeInterval
  private let state = Mutex(State())
  private let emit: @Sendable (Transition) -> Void

  init(
    expectedHandoffWait: DispatchTimeInterval = .milliseconds(750),
    emit: @escaping @Sendable (Transition) -> Void
  ) {
    self.expectedHandoffWait = expectedHandoffWait
    self.emit = emit
  }

  /// Stages the generation whose new output is about to race asynchronous
  /// teardown of the current output.
  ///
  /// This does not transfer the controller early: the retiring native module
  /// still owns the authoritative `closeForVideoOutput` decision. It only
  /// gives the successor's synchronous `take` call a bounded reason to wait
  /// for that decision instead of immediately constructing a second PiP
  /// controller.
  func expectHandoff(for mediaGeneration: PlaybackGeneration) {
    state.withLock { state in
      if
        let expected = state.expectedHandoff,
        expected.mediaGeneration >= mediaGeneration {
        return
      }
      state.expectedHandoff = State.ExpectedHandoff(
        mediaGeneration: mediaGeneration,
        signal: DispatchSemaphore(value: 0)
      )
    }
  }

  /// Holds an active native window controller when the player advanced to a
  /// different media generation, or when the engine consumed explicit proof
  /// that this same-generation close is a seek-driven video-output rebuild.
  func preserve(
    _ controller: AnyObject,
    for mediaGeneration: PlaybackGeneration?,
    allowsSameGenerationRebuild: Bool = false
  ) -> Bool {
    guard let mediaGeneration else { return false }
    let startedAt = clock.now
    let result = state.withLock { state
      -> (accepted: Bool, transition: Transition?, signal: DispatchSemaphore?) in
      let signal = state.expectedHandoff.flatMap { expected in
        mediaGeneration >= expected.mediaGeneration ? expected.signal : nil
      }
      if var pending = state.pending {
        guard
          pending.controllerIdentity == ObjectIdentifier(controller),
          mediaGeneration >= pending.mediaGeneration
        else { return (false, nil, nil) }

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
        return (true, transition, signal)
      }

      guard
        let previous = state.readyMediaGeneration,
        previous != mediaGeneration || allowsSameGenerationRebuild
      else { return (false, nil, nil) }

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
        .rebuilding(previous: previous, successor: mediaGeneration),
        signal
      )
    }

    result.signal?.signal()
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
    if let result = takePreservedControllerIfAvailable(for: mediaGeneration) {
      if let transition = result.transition {
        emit(transition)
      }
      return result.controller
    }

    let expected = state.withLock { state -> State.ExpectedHandoff? in
      guard
        let expected = state.expectedHandoff,
        mediaGeneration >= expected.mediaGeneration
      else { return nil }
      return expected
    }
    guard let expected else { return nil }

    // Called synchronously by libVLC's output-opening thread. Never hold the
    // coordinator mutex while waiting: the retiring output must be able to
    // enter `preserve`, publish the controller, and signal this exact waiter.
    _ = expected.signal.wait(timeout: .now() + expectedHandoffWait)
    if let result = takePreservedControllerIfAvailable(for: mediaGeneration) {
      if let transition = result.transition {
        emit(transition)
      }
      return result.controller
    }
    state.withLock { state in
      if state.expectedHandoff?.signal === expected.signal {
        state.expectedHandoff = nil
      }
    }
    return nil
  }

  private func takePreservedControllerIfAvailable(
    for mediaGeneration: PlaybackGeneration
  ) -> (controller: AnyObject, transition: Transition?)? {
    state.withLock { state in
      guard
        var pending = state.pending,
        let controller = pending.controller,
        mediaGeneration >= pending.mediaGeneration
      else { return nil }

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
      state.expectedHandoff = nil
      return (controller, transition)
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
        if
          let expected = state.expectedHandoff,
          mediaGeneration >= expected.mediaGeneration {
          state.expectedHandoff = nil
        }
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
      state.expectedHandoff = nil
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
      state.expectedHandoff = nil
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
