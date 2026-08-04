#if os(iOS)
import Synchronization

/// One-shot proof that a same-media video-output close belongs to a recently
/// accepted seek rather than to stop, teardown, or navigation.
///
/// libVLC can rebuild its video output asynchronously after the seek API
/// returns. The permit therefore outlives the call, but expires quickly and is
/// consumed by the first matching close. This keeps native PiP continuity
/// narrow: an unrelated teardown cannot inherit a stale seek decision.
final class IOSNativePiPVideoOutputRebuildPermit: Sendable {
  private struct Permit: Sendable {
    let token: UInt64
    let mediaGeneration: PlaybackGeneration
    let expiresAt: ContinuousClock.Instant
  }

  private struct State: Sendable {
    var nextToken: UInt64 = 0
    var isPiPActive = false
    var permit: Permit?
  }

  private let clock = ContinuousClock()
  private let state = Mutex(State())

  func stage(
    for mediaGeneration: PlaybackGeneration,
    validity: Duration = .seconds(3)
  ) -> UInt64? {
    let expiresAt = clock.now.advanced(by: validity)
    return state.withLock { state in
      guard state.isPiPActive else { return nil }
      precondition(state.nextToken < UInt64.max, "PiP rebuild permit token exhausted")
      state.nextToken += 1
      state.permit = Permit(
        token: state.nextToken,
        mediaGeneration: mediaGeneration,
        expiresAt: expiresAt
      )
      return state.nextToken
    }
  }

  /// Changes the native-PiP activity boundary and invalidates any decision
  /// made on the other side of it. A seek issued before PiP starts can never
  /// authorize a later, unrelated close.
  func setPiPActive(_ isActive: Bool) {
    state.withLock { state in
      guard state.isPiPActive != isActive else { return }
      state.isPiPActive = isActive
      state.permit = nil
    }
  }

  func cancel(_ token: UInt64) {
    state.withLock { state in
      guard state.permit?.token == token else { return }
      state.permit = nil
    }
  }

  func consume(for mediaGeneration: PlaybackGeneration) -> Bool {
    let now = clock.now
    return state.withLock { state in
      guard state.isPiPActive, let permit = state.permit else { return false }
      guard permit.expiresAt > now else {
        state.permit = nil
        return false
      }
      guard permit.mediaGeneration == mediaGeneration else { return false }
      state.permit = nil
      return true
    }
  }

  func invalidate() {
    state.withLock { $0.permit = nil }
  }
}
#endif
