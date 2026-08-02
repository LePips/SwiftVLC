import Synchronization

/// The lifecycle state of an authoritative seek request.
///
/// A native seek is asynchronous. ``pending`` means libVLC accepted the
/// command but SwiftVLC has not yet published authoritative native landing
/// evidence. This is normally the first watched timer point after seek end;
/// paused audio-only input instead uses a direct post-end clock read because
/// it may not produce another point until playback resumes. Every request
/// eventually reaches one of the other, terminal cases.
public enum SeekOutcome: Hashable, Sendable {
  /// libVLC accepted the request and it is waiting for native landing evidence.
  case pending
  /// The request was invalid for the current playback session or libVLC
  /// refused it. The observable timeline was not changed.
  case rejected
  /// The accepted seek ended and its authoritative landed clock reached the mirror.
  case settled
  /// No authoritative landed clock arrived within SwiftVLC's bounded settlement window.
  case timedOut
  /// A newer seek, media replacement, terminal playback state, or teardown
  /// made this request no longer authoritative.
  case superseded
}

/// An accepted-or-rejected seek together with its authoritative result.
///
/// Inspect ``initialOutcome`` synchronously to learn whether libVLC accepted
/// the command. If it is ``SeekOutcome/pending``, await ``outcome`` for the
/// eventual landing, timeout, or supersession. Waiting is cancellation-safe:
/// cancelling one waiter does not cancel or reclassify the underlying seek.
public struct SeekRequest: Sendable {
  private enum Resolution: Sendable {
    case resolved(SeekOutcome)
    case pending(SeekOutcomeResolver)
  }

  /// The result known when the native seek call returns.
  ///
  /// This is either ``SeekOutcome/pending`` or ``SeekOutcome/rejected``.
  public let initialOutcome: SeekOutcome

  private let resolution: Resolution

  /// The authoritative terminal result.
  ///
  /// Rejected requests return immediately. Accepted requests suspend until
  /// the matching seek publishes its native landing, the request times out, or
  /// newer work supersedes it.
  public var outcome: SeekOutcome {
    get async {
      switch resolution {
      case .resolved(let outcome): outcome
      case .pending(let resolver): await resolver.outcome()
      }
    }
  }

  init(resolved outcome: SeekOutcome) {
    precondition(outcome != .pending)
    initialOutcome = outcome == .rejected ? .rejected : .pending
    resolution = .resolved(outcome)
  }

  init(resolver: SeekOutcomeResolver) {
    initialOutcome = .pending
    resolution = .pending(resolver)
  }
}

/// Single-assignment promise shared by Player's main-actor state machine and
/// every task awaiting a copied ``SeekRequest``.
///
/// Multiple waiters register under one lock and are resumed with the same
/// value. Cancelling a waiter cannot cancel the seek, and accidental duplicate
/// settlement is harmless.
final class SeekOutcomeResolver: Sendable {
  private struct State: Sendable {
    var outcome: SeekOutcome?
    var waiters: [CheckedContinuation<SeekOutcome, Never>] = []
  }

  private let state = Mutex(State())

  func outcome() async -> SeekOutcome {
    await withCheckedContinuation { continuation in
      let immediate = state.withLock { state -> SeekOutcome? in
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
  func resolve(_ outcome: SeekOutcome) -> Bool {
    precondition(outcome != .pending)
    let waiters = state.withLock { state -> [CheckedContinuation<SeekOutcome, Never>]? in
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

  #if DEBUG
  var resolvedOutcome: SeekOutcome? {
    state.withLock { $0.outcome }
  }
  #endif
}
