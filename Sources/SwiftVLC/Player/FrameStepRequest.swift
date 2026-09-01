import Synchronization

/// The lifecycle state of one request-correlated frame step.
///
/// A successful request is reported as ``submitted(time:position:)`` only
/// after libVLC accepts that request's exact picture for output submission and
/// updates the video clock. It does not claim that the display hardware has
/// physically scanned out the picture. Once that native output commit wins,
/// a later seek or playback boundary cannot reclassify the request, although
/// it can prevent the older clock snapshot from replacing Player's newer
/// timeline.
public enum FrameStepOutcome: Hashable, Sendable {
  /// SwiftVLC accepted the command, but no terminal native result has arrived.
  case pending
  /// The exact requested picture reached output submission and its clock
  /// update completed.
  ///
  /// `position` is `nil` for live or unknown-duration media. A later playback
  /// boundary can make Player's current timeline newer than this
  /// request-correlated snapshot.
  case submitted(time: Duration, position: PlaybackPosition?)
  /// The paused decoder is drained and has no next picture.
  case noFrame
  /// The native frame-step operation failed with an errno-style status.
  case failed(code: Int32)
  /// libVLC reported success without the authoritative request-correlated
  /// timestamp required to identify the submitted picture.
  case invalidEvidence
  /// The request did not reach a terminal native result before its bounded
  /// deadline.
  case timedOut
  /// A seek, media replacement, terminal playback state, or teardown won
  /// before the request's native output commit or another exact native
  /// terminal became authoritative.
  case superseded
  /// The request could not enter the current player's strict frame-step lane.
  case rejected
}

/// An accepted-or-rejected frame step together with its authoritative result.
///
/// Inspect ``initialOutcome`` synchronously to learn whether SwiftVLC accepted
/// the command. If it is ``FrameStepOutcome/pending``, await ``outcome`` for
/// one request-correlated terminal result. Cancelling a task that is awaiting
/// the result does not cancel or reclassify the underlying frame step.
public struct FrameStepRequest: Sendable {
  private enum Resolution: Sendable {
    case resolved(FrameStepOutcome)
    case pending(FrameStepOutcomeResolver)
  }

  /// The result known when SwiftVLC accepts or rejects the command.
  ///
  /// This is either ``FrameStepOutcome/pending`` or
  /// ``FrameStepOutcome/rejected``.
  public let initialOutcome: FrameStepOutcome

  private let resolution: Resolution

  /// The authoritative terminal result.
  public var outcome: FrameStepOutcome {
    get async {
      switch resolution {
      case .resolved(let outcome): outcome
      case .pending(let resolver): await resolver.outcome()
      }
    }
  }

  init(resolved outcome: FrameStepOutcome) {
    precondition(outcome != .pending)
    initialOutcome = outcome == .rejected ? .rejected : .pending
    resolution = .resolved(outcome)
  }

  init(resolver: FrameStepOutcomeResolver) {
    initialOutcome = resolver.resolvedOutcome == .rejected ? .rejected : .pending
    resolution = .pending(resolver)
  }
}

/// Single-assignment promise shared by Player's main-actor state machine and
/// every task awaiting a copied ``FrameStepRequest``.
final class FrameStepOutcomeResolver: Sendable {
  private typealias Waiter = CheckedContinuation<FrameStepOutcome, Never>

  private struct State: Sendable {
    var outcome: FrameStepOutcome?
    var waiters: [Waiter] = []
  }

  private let state = Mutex(State())

  func outcome() async -> FrameStepOutcome {
    await withCheckedContinuation { continuation in
      let immediate = state.withLock { state -> FrameStepOutcome? in
        guard let outcome = state.outcome else {
          state.waiters.append(continuation)
          return nil
        }
        return outcome
      }
      if let immediate {
        continuation.resume(returning: immediate)
      }
    }
  }

  @discardableResult
  func resolve(_ outcome: FrameStepOutcome) -> Bool {
    precondition(outcome != .pending)
    let waiters = state.withLock { state -> [Waiter]? in
      guard state.outcome == nil else { return nil }
      state.outcome = outcome
      defer { state.waiters.removeAll(keepingCapacity: false) }
      return state.waiters
    }
    guard let waiters else { return false }
    for waiter in waiters {
      waiter.resume(returning: outcome)
    }
    return true
  }

  var resolvedOutcome: FrameStepOutcome? {
    state.withLock { $0.outcome }
  }
}
