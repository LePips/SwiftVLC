import CLibVLC
import os
import Synchronization

extension Player {
  // MARK: - Playback state + intent publication

  @discardableResult
  func publishPlaybackState(
    _ newState: PlayerState,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    func stillOwnsPublication() -> Bool {
      if let expectedLifecycleControlEpoch {
        guard expectedLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
          return false
        }
      }
      if let expectedNativeHandleGeneration {
        guard expectedNativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
          return false
        }
      }
      guard let expectedPlaybackGeneration else { return true }
      return ownsPlaybackMutation(expectedPlaybackGeneration)
    }

    guard stillOwnsPublication() else { return false }
    let shouldRearmPlaybackHealth = newState == .playing && state != .playing
    guard
      performObservableMutation(
        keyPath: \.state,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storeStateWithoutNestedObservation(newState)
        }
      ) else { return false }
    guard
      performObservableMutation(
        keyPath: \.isActive,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {}
      ) else { return false }
    guard stillOwnsPublication() else { return false }
    if shouldRearmPlaybackHealth {
      rearmPlaybackHealthAfterEnteringPlaying()
    }
    // The single funnel for `state`, and therefore the only place that can
    // see *every* lifecycle transition. Broadcasting from here rather than
    // from the raw `.stateChanged` event is what puts `.error` and
    // `.buffering` on the stream at all: libVLC reports those as
    // `.encounteredError` and `.bufferingProgress`, so neither has ever
    // produced a `.stateChanged` to forward.
    stateTransitionBridge.broadcast(newState)
    publishPlaybackStatus()
    guard
      samplePlaybackHealth(
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      ) else { return false }
    reconcilePlaybackHealthSamplingTask()
    return stillOwnsPublication()
  }

  /// Republishes the current state paired with the session it belongs to.
  ///
  /// Called from both funnels rather than one: a state change keeps the same
  /// generation, and a media change keeps the same state, so either alone
  /// leaves ``Player/playbackStatus`` describing a pair that was never true.
  func publishPlaybackStatus() {
    playbackStatusBridge.broadcast(
      PlaybackStatus(state: state, generation: PlaybackGeneration(sessionGeneration))
    )
  }

  @discardableResult
  func publishPlaybackIntent(
    _ active: Bool,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil,
    requiresNonterminalPlaybackAuthority: Bool = false
  ) -> Bool {
    playbackIntentPublicationRevision &+= 1
    let publicationRevision = playbackIntentPublicationRevision
    let effectiveActive = active && !requiresFreshPlaybackIntentAfterMediaServicesReset

    func stillOwnsPublication() -> Bool {
      guard playbackIntentPublicationRevision == publicationRevision else { return false }
      if let expectedLifecycleControlEpoch {
        guard expectedLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
          return false
        }
      }
      if let expectedNativeHandleGeneration {
        guard expectedNativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
          return false
        }
      }
      if requiresNonterminalPlaybackAuthority {
        guard
          let expectedPlaybackGeneration,
          let expectedNativeHandleGeneration,
          let expectedLifecycleControlEpoch,
          eventBridge.ownsNonterminalPlayback(
            playbackGeneration: expectedPlaybackGeneration,
            nativeHandleGeneration: expectedNativeHandleGeneration,
            lifecycleControlEpoch: expectedLifecycleControlEpoch
          )
        else { return false }
      }
      guard let expectedPlaybackGeneration else { return true }
      return ownsPlaybackMutation(expectedPlaybackGeneration)
    }

    guard stillOwnsPublication() else { return false }
    guard isPlaybackRequestedActive != effectiveActive else { return true }
    var didCommitIntent = false
    withMutation(keyPath: \.isPlaybackRequestedActive) {
      guard stillOwnsPublication() else { return }
      storePlaybackIntentWithoutNestedObservation(effectiveActive)
      nonisolatedPlaybackIntent.store(effectiveActive, ordering: .releasing)
      playbackIntentBridge.broadcast(effectiveActive)
      didCommitIntent = true
    }
    guard didCommitIntent, stillOwnsPublication() else { return false }
    var didPublishDerivedIntent = false
    withMutation(keyPath: \.isPlaying) {
      guard stillOwnsPublication() else { return }
      didPublishDerivedIntent = true
    }
    // Mirrored synchronously so off-main callers — AVKit and AppKit PiP
    // callbacks, which must answer immediately — can read the current intent
    // without hopping to the main actor.
    return didPublishDerivedIntent && stillOwnsPublication()
  }

  func setPlaybackIntentFromExternalControl(_ active: Bool) {
    publishPlaybackIntent(active)
  }

  /// Exact Player-side authority for a conditional external-intent repair.
  ///
  /// PiP can discover that a requested pause was impossible and need to restore
  /// the truthful active intent. Publishing that result is observable, though:
  /// an app callback can synchronously issue a newer Pause, Stop, load, or
  /// lifecycle command before PiP resumes. Keeping this lease on Player makes
  /// the check cover the authoritative transport revision as well as the
  /// playback/native/lifecycle identities.
  struct ExternalPlaybackIntentRestorationLease {
    let playbackControlRevision: UInt64
    let playbackGeneration: UInt64
    let nativeHandleGeneration: UInt64
    let lifecycleControlEpoch: UInt64
  }

  func makeExternalPlaybackIntentRestorationLease()
    -> ExternalPlaybackIntentRestorationLease? {
    let playbackGeneration = sessionGeneration
    let nativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let lifecycleControlEpoch = eventBridge.currentLifecycleControlEpoch
    guard
      state.isActive,
      nativeHandleRepresentsCurrentMedia,
      playbackControlIntent != .pause,
      playbackGeneration == eventBridge.currentPlaybackGeneration,
      eventBridge.ownsNonterminalPlayback(
        playbackGeneration: playbackGeneration,
        nativeHandleGeneration: nativeHandleGeneration,
        lifecycleControlEpoch: lifecycleControlEpoch
      )
    else { return nil }
    return ExternalPlaybackIntentRestorationLease(
      playbackControlRevision: playbackControlIntentRevision,
      playbackGeneration: playbackGeneration,
      nativeHandleGeneration: nativeHandleGeneration,
      lifecycleControlEpoch: lifecycleControlEpoch
    )
  }

  func ownsExternalPlaybackIntentRestoration(
    _ lease: ExternalPlaybackIntentRestorationLease
  ) -> Bool {
    state.isActive
      && nativeHandleRepresentsCurrentMedia
      && playbackControlIntent != .pause
      && playbackControlIntentRevision == lease.playbackControlRevision
      && ownsPlaybackMutation(
        lease.playbackGeneration,
        nativeHandleGeneration: lease.nativeHandleGeneration
      )
      && eventBridge.ownsNonterminalPlayback(
        playbackGeneration: lease.playbackGeneration,
        nativeHandleGeneration: lease.nativeHandleGeneration,
        lifecycleControlEpoch: lease.lifecycleControlEpoch
      )
  }

  @discardableResult
  func restorePlaybackIntentFromExternalControl(
    _ active: Bool,
    ifCurrent lease: ExternalPlaybackIntentRestorationLease
  ) -> Bool {
    guard ownsExternalPlaybackIntentRestoration(lease) else { return false }
    guard
      publishPlaybackIntent(
        active,
        ifPlaybackGeneration: lease.playbackGeneration,
        nativeHandleGeneration: lease.nativeHandleGeneration,
        lifecycleControlEpoch: lease.lifecycleControlEpoch,
        requiresNonterminalPlaybackAuthority: true
      ),
      ownsExternalPlaybackIntentRestoration(lease),
      isPlaybackRequestedActive == active
    else { return false }
    return true
  }

  @discardableResult
  func setPlaybackControlIntent(
    _ command: DeferredPauseCommand,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil
  ) -> Bool {
    if let expectedNativeHandleGeneration {
      guard expectedNativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
        return false
      }
    }
    if let expectedPlaybackGeneration {
      guard ownsPlaybackMutation(expectedPlaybackGeneration) else { return false }
    }
    if command == .resume {
      eventBridge.acceptExternalPlaybackActivation(
        playbackGeneration: eventBridge.currentPlaybackGeneration
      )
    }
    playbackControlIntent = command
    return publishPlaybackIntent(
      command == .resume,
      ifPlaybackGeneration: expectedPlaybackGeneration,
      nativeHandleGeneration: expectedNativeHandleGeneration
    )
  }

  /// Reconciles the published playback intent with libVLC's reported
  /// state, *unless* a user-initiated transition is in flight. While
  /// pausing or resuming, the intent published by `pause()`/`resume()`
  /// wins until the matching state arrives.
  @discardableResult
  func reconcilePlaybackIntent(
    for state: PlayerState,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    switch state {
    case .opening, .buffering, .playing:
      guard pauseTransition != .pausing, deferredPauseCommand != .pause else { return true }
      return publishPlaybackIntent(
        true,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      )

    case .paused:
      guard pauseTransition != .resuming, deferredPauseCommand != .resume else { return true }
      guard !preservesPlaybackIntentForManagedAudioSuspension else {
        return publishPlaybackIntent(
          true,
          ifPlaybackGeneration: expectedPlaybackGeneration,
          nativeHandleGeneration: expectedNativeHandleGeneration,
          lifecycleControlEpoch: expectedLifecycleControlEpoch
        )
      }
      return publishPlaybackIntent(
        false,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      )

    case .idle, .stopped, .stopping, .error:
      guard !hasPauseControl(after: sessionGeneration) else { return true }
      clearManagedAudioSuspensionForExplicitControl()
      return publishPlaybackIntent(
        false,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      )
    }
  }

  // MARK: - Pause transition + deferred command

  /// Closes out a pause/resume transition once libVLC reports the
  /// matching state, or clears any pending state on terminal states.
  func updatePauseTransition(for newState: PlayerState) {
    switch (pauseTransition, newState) {
    case (.pausing, .paused), (.resuming, .playing):
      guard pauseTransitionPlaybackGeneration == sessionGeneration else { return }
      pauseTransition = nil
      performDeferredPauseCommandIfNeeded()
    case (_, .idle), (_, .stopped), (_, .stopping), (_, .error):
      clearPauseControlState(for: sessionGeneration)
    default:
      break
    }
  }

  /// Clears only pause work owned by `playbackGeneration`. A queued event for
  /// an outgoing playlist item must not erase work already accepted for its
  /// successor on the callback lane.
  func clearPauseControlState(for playbackGeneration: UInt64) {
    if pauseTransitionPlaybackGeneration == playbackGeneration {
      pauseTransition = nil
    }
    if deferredPauseCommandPlaybackGeneration == playbackGeneration {
      deferredPauseCommand = nil
    }
  }

  /// Whether the callback lane has already accepted pause/resume work for a
  /// media generation that the main actor has not adopted yet.
  func hasPauseControl(after playbackGeneration: UInt64) -> Bool {
    (pauseTransitionPlaybackGeneration ?? 0) > playbackGeneration
      || (deferredPauseCommandPlaybackGeneration ?? 0) > playbackGeneration
  }

  /// If a pause/resume command was deferred (because the player wasn't
  /// in a stable state at the time), retry it now.
  func performDeferredPauseCommandIfNeeded() {
    guard
      pauseTransition == nil,
      let command = deferredPauseCommand,
      let playbackGeneration = deferredPauseCommandPlaybackGeneration,
      playbackGeneration == sessionGeneration
    else {
      return
    }
    guard playbackGeneration == eventBridge.currentPlaybackGeneration else {
      // The callback lane has already adopted a successor. Retrying this
      // outgoing command would act on the shared native handle's new media.
      deferredPauseCommand = nil
      return
    }
    deferredPauseCommand = nil
    switch command {
    case .pause:
      _ = issuePause(
        playbackGeneration: playbackGeneration,
        recordsPlaybackControlIntent: false
      )
    case .resume:
      _ = issueResume(playbackGeneration: playbackGeneration)
    }
  }
}
