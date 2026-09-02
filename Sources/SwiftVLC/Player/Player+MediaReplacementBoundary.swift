/// Public lifecycle normalization for same-handle media replacement.
extension Player {
  /// Publishes the outgoing session's final state before adopting an externally
  /// selected successor media generation.
  ///
  /// libVLC list playback can report `Stopping(A)`, `MediaChanged(B)`, and
  /// `Opening(B)` before the delayed `Stopped(A)` callback. The delayed event
  /// must stay generation-stale or it can regress an already-playing B, but
  /// dropping it without this boundary leaves consumers with no terminal state
  /// for A. This method normalizes that native ordering to
  /// `stopping(A) -> stopped(A) -> opening(B)`.
  ///
  /// This cannot use `publishPlaybackState`: EventBridge has already reserved
  /// the successor at callback entry while `Player` intentionally still owns
  /// the outgoing generation. Every mutation therefore validates that exact
  /// split boundary both before and inside Observation's synchronous callback.
  @discardableResult
  func publishExternalMediaReplacementBoundaryIfNeeded(
    successorPlaybackGeneration: UInt64?,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64?,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64?
  ) -> Bool {
    guard
      let successorPlaybackGeneration,
      successorPlaybackGeneration > sessionGeneration
    else { return true }

    // The first externally installed media has no outgoing session to finish.
    guard currentMediaStorage != nil || sessionGenerationMedia != nil else {
      return true
    }
    switch state {
    case .idle, .stopped:
      return true
    case .opening, .buffering, .playing, .paused, .stopping, .error:
      break
    }

    let outgoingPlaybackGeneration = sessionGeneration
    func stillOwnsBoundary() -> Bool {
      guard
        sessionGeneration == outgoingPlaybackGeneration,
        eventBridge.currentPlaybackGeneration == successorPlaybackGeneration
      else { return false }
      if let expectedNativeHandleGeneration {
        guard
          eventBridge.currentNativeHandleGeneration == expectedNativeHandleGeneration
        else { return false }
      }
      if let expectedLifecycleControlEpoch {
        guard
          eventBridge.currentLifecycleControlEpoch == expectedLifecycleControlEpoch
        else { return false }
      }
      return true
    }

    guard stillOwnsBoundary() else { return false }
    var didStoreState = false
    withMutation(keyPath: \.state) {
      guard stillOwnsBoundary() else { return }
      storeStateWithoutNestedObservation(.stopped)
      didStoreState = true
    }
    guard didStoreState, stillOwnsBoundary() else { return false }

    var didInvalidateActivity = false
    withMutation(keyPath: \.isActive) {
      guard stillOwnsBoundary() else { return }
      didInvalidateActivity = true
    }
    guard didInvalidateActivity, stillOwnsBoundary() else { return false }

    stateTransitionBridge.broadcast(.stopped)
    guard stillOwnsBoundary() else { return false }
    playbackStatusBridge.broadcast(
      PlaybackStatus(
        state: .stopped,
        generation: PlaybackGeneration(outgoingPlaybackGeneration)
      )
    )
    return stillOwnsBoundary()
  }
}
