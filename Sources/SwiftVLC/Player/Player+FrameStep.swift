import CLibVLC
import Foundation

extension Player {
  // MARK: - Frame Stepping

  /// Pauses playback and requests one video frame.
  ///
  /// Requires the current media to be pausable (see ``isPausable``).
  /// Calling repeatedly queues frame-by-frame steps. Use
  /// ``requestNextFrame()`` when the caller needs request-correlated proof that
  /// the exact picture reached output submission.
  public func nextFrame() {
    _ = requestNextFrame()
  }

  /// Pauses playback and requests one request-correlated video frame.
  ///
  /// The returned value distinguishes native rejection, timeout,
  /// supersession, decoder exhaustion, failure, and exact output submission.
  /// A ``FrameStepOutcome/submitted(time:position:)`` result is emitted only
  /// after the output accepts that request's exact picture and the associated
  /// video-clock update completes. It is not proof of physical display
  /// scan-out. If that native output commit wins before cancellation, a later
  /// seek or playback boundary cannot reclassify the request, but the older
  /// clock snapshot will not overwrite Player's newer timeline.
  ///
  /// - Returns: A request whose initial result is pending or rejected.
  @discardableResult
  public func requestNextFrame() -> FrameStepRequest {
    guard
      !isShutdown,
      nativeHandleRepresentsCurrentMedia
    else { return FrameStepRequest(resolved: .rejected) }
    precondition(nextFrameRequestToken < UInt64.max, "Frame-step request token exhausted")
    nextFrameRequestToken += 1
    let resolver = FrameStepOutcomeResolver()
    let phase: PendingFrameStepPhase = nativePlaybackState == .paused
      ? .awaitingFrame
      : .awaitingPause
    pendingFrameSteps.append(PendingFrameStep(
      requestToken: nextFrameRequestToken,
      playbackGeneration: sessionGeneration,
      nativeHandleGeneration: eventBridge.currentNativeHandleGeneration,
      nativeFrameGeneration: nativeSeekMonitor.frameGeneration,
      resolver: resolver,
      phase: phase,
      didDispatchNativeRequest: false,
      nativeRequestInFlight: false,
      timeoutTask: nil
    ))
    dispatchNextPendingFrameStepIfNeeded()
    return FrameStepRequest(resolver: resolver)
  }

  /// Attempts the front command only. The strict native extension also owns a
  /// single slot, so keeping the wrapper FIFO serialized gives every terminal
  /// callback exactly one logical command to resolve.
  func dispatchNextPendingFrameStepIfNeeded() {
    guard !isShutdown, !pendingFrameSteps.isEmpty else { return }
    guard nativeHandleRepresentsCurrentMedia else {
      // This request was accepted before a media-replacement boundary won. It
      // can no longer target the current media, and must never reach the old
      // handle under the successor's playback generation.
      cancelPendingFrameSteps()
      return
    }
    startFrontFrameStepDeadlineIfNeeded()
    guard
      pendingSeekSettlement == nil,
      activeNativeSeek == nil,
      queuedNativeSeek == nil,
      !nativeSeekMonitor.hasSeekDrainPending,
      let frame = pendingFrameSteps.first
    else { return }
    guard !frame.nativeRequestInFlight else { return }

    let currentFrameGeneration = nativeSeekMonitor.frameGeneration
    guard
      frame.nativeFrameGeneration == currentFrameGeneration,
      ownsPlaybackMutation(
        frame.playbackGeneration,
        nativeHandleGeneration: frame.nativeHandleGeneration
      )
    else {
      cancelPendingFrameSteps(beforeFrameGeneration: currentFrameGeneration)
      if pendingFrameSteps.contains(where: { $0.requestToken == frame.requestToken }) {
        cancelPendingFrameSteps()
      }
      return
    }

    // An initially paused command may make its first request immediately. A
    // playing command that received the explicit native retry status must wait
    // for the event-consumer's authoritative `.paused` transition before
    // reissuing the same ID.
    if
      frame.phase == .awaitingFrame,
      frame.didDispatchNativeRequest,
      state != .paused {
      return
    }

    let disposition = issueNativeNextFrame(frame)
    guard
      let index = pendingFrameSteps.firstIndex(where: {
        $0.requestToken == frame.requestToken
      })
    else { return }
    switch disposition {
    case .accepted:
      pendingFrameSteps[index].didDispatchNativeRequest = true
      pendingFrameSteps[index].nativeRequestInFlight = true
    case .busy:
      // The monitor retains the native ownership/tombstone. Its exact terminal
      // event or a seek/resume/media boundary calls the availability handler.
      break
    case .unavailable:
      // Running against an unpatched or incompatible LibVLC cannot provide the
      // post-submission identity guarantee. Fail closed instead of publishing
      // a synchronous getter as if it proved an exact submitted frame.
      cancelPendingFrameSteps(resolving: .rejected)
    }
  }

  /// Gives each logical command one bounded lifetime from the moment it owns
  /// the FIFO front. The same task spans native busy, seek drain, the initial
  /// playing attempt, and its paused reissue; none can wait forever or reset
  /// the deadline by cycling through native retry responses.
  func startFrontFrameStepDeadlineIfNeeded() {
    guard pendingFrameSteps[0].timeoutTask == nil else { return }
    let requestToken = pendingFrameSteps[0].requestToken
    pendingFrameSteps[0].timeoutTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      self?.expirePendingFrameStep(requestToken: requestToken)
    }
  }

  func issueNativeNextFrame(
    _ frame: PendingFrameStep
  ) -> NativeFrameRequestDispatch {
    guard
      nativeHandleRepresentsCurrentMedia,
      ownsPlaybackMutation(
        frame.playbackGeneration,
        nativeHandleGeneration: frame.nativeHandleGeneration
      )
    else { return .unavailable }
    #if DEBUG
    if let _nativeNextFrameOverrideForTesting {
      return nativeSeekMonitor._requestFrameStepForTesting(
        requestID: frame.requestToken,
        frameGeneration: frame.nativeFrameGeneration
      ) {
        _nativeNextFrameOverrideForTesting(frame.requestToken)
      }
    }
    #endif
    return nativeSeekMonitor.requestFrameStep(
      requestID: frame.requestToken,
      frameGeneration: frame.nativeFrameGeneration
    )
  }

  func nativeFrameStepDidComplete(_ announcedResult: NativeFrameStepResult) {
    /* The handler argument is only a wake-up. The reservation transports an
     * exact native terminal (including an output commit that already won)
     * across arbitrary MainActor task ordering; consuming it atomically makes
     * duplicate tasks harmless without treating Swift callback scheduling as
     * the semantic linearization point. */
    guard
      let result = nativeSeekMonitor.consumeFrameResult(
        requestID: announcedResult.token
      ) else { return }
    _ = resolveConsumedNativeFrameResult(result)
    dispatchNextPendingFrameStepIfNeeded()
  }

  @discardableResult
  func resolveConsumedNativeFrameResult(
    _ result: NativeFrameStepResult
  ) -> Bool {
    let pendingIndex = pendingFrameSteps.firstIndex {
      $0.requestToken == result.token
    }
    let committed = committedFrameStepsAwaitingTerminal[result.token]
    guard pendingIndex != nil || committed != nil else { return false }

    let frame = pendingIndex.map { pendingFrameSteps[$0] } ?? committed!.frame
    let identityIsCurrent = !isShutdown
      && frame.playbackGeneration == sessionGeneration
      && frame.nativeHandleGeneration == eventBridge.currentNativeHandleGeneration
      && frame.nativeFrameGeneration == nativeSeekMonitor.frameGeneration
    let terminalStatus = NativeFrameStepTerminalStatus(rawValue: result.status)

    if terminalStatus == .pausedForRetry {
      if let pendingIndex, identityIsCurrent {
        // This is a nonterminal result for the same exact request ID. Reissue
        // it only after the event consumer observes the paused boundary.
        pendingFrameSteps[pendingIndex].nativeRequestInFlight = false
        pendingFrameSteps[pendingIndex].phase = .awaitingFrame
      } else if let pendingIndex {
        let pending = pendingFrameSteps.remove(at: pendingIndex)
        pending.timeoutTask?.cancel()
        pending.resolver.resolve(.superseded)
      } else if
        let committed = committedFrameStepsAwaitingTerminal
          .removeValue(forKey: result.token) {
        committed.frame.timeoutTask?.cancel()
        committed.frame.resolver.resolve(committed.fallbackOutcome)
      }
      return true
    }

    let allowsTimelineMutation: Bool
    let fallbackOutcome: FrameStepOutcome
    let resolvedFrame: PendingFrameStep
    if let pendingIndex {
      resolvedFrame = pendingFrameSteps.remove(at: pendingIndex)
      allowsTimelineMutation = true
      fallbackOutcome = .superseded
    } else {
      guard
        let committed = committedFrameStepsAwaitingTerminal
          .removeValue(forKey: result.token) else { return false }
      resolvedFrame = committed.frame
      allowsTimelineMutation = committed.allowsTimelineMutation
      fallbackOutcome = committed.fallbackOutcome
    }
    resolvedFrame.timeoutTask?.cancel()

    switch terminalStatus {
    case .pausedForRetry:
      preconditionFailure("Nonterminal frame result escaped its resolution branch")
    case .noFrame:
      resolvedFrame.resolver.resolve(.noFrame)
    case .failed(let code):
      if code == -Int32(POSIXErrorCode.ECANCELED.rawValue) {
        resolvedFrame.resolver.resolve(fallbackOutcome)
      } else {
        resolvedFrame.resolver.resolve(.failed(code: code))
      }
    case .success:
      guard result.timeMicroseconds >= 0 else {
        resolvedFrame.resolver.resolve(.invalidEvidence)
        return true
      }

      let milliseconds = result.timeMicroseconds / 1000
      let eventPosition = result.position.isFinite
        && (0.0...1.0).contains(result.position)
        ? result.position
        : nil
      var outcomePosition = eventPosition

      /* Exact request outcome and mutable Player timeline are separate
       * authorities. A native output commit that beat cancellation still
       * earns `.submitted`, but it must not rewind a newer timeline boundary. */
      if
        allowsTimelineMutation,
        identityIsCurrent,
        canCommitNativeTimelineEmission(result.emissionSequence) {
        commitNativeTimelineEmission(result.emissionSequence)
        let lifecycleControlEpoch = eventBridge.currentLifecycleControlEpoch
        let frameTimelineRevision = eventBridge.advanceTimelineRevision()
        acceptedTimelineRevision = frameTimelineRevision
        var timelineMutationIsCurrent = performObservableMutation(
          keyPath: \.currentTime,
          ifPlaybackGeneration: frame.playbackGeneration,
          nativeHandleGeneration: frame.nativeHandleGeneration,
          timelineRevision: frameTimelineRevision,
          lifecycleControlEpoch: lifecycleControlEpoch,
          mutation: {
            storeCurrentTimeWithoutNestedObservation(.milliseconds(milliseconds))
          }
        )
        if timelineMutationIsCurrent, let eventPosition {
          timelineMutationIsCurrent = performObservableMutation(
            keyPath: \.position,
            ifPlaybackGeneration: frame.playbackGeneration,
            nativeHandleGeneration: frame.nativeHandleGeneration,
            timelineRevision: frameTimelineRevision,
            lifecycleControlEpoch: lifecycleControlEpoch,
            mutation: {
              storePositionWithoutNestedObservation(eventPosition)
            }
          )
        } else if timelineMutationIsCurrent {
          outcomePosition = publishPosition(
            forTargetMilliseconds: milliseconds,
            ifPlaybackGeneration: frame.playbackGeneration,
            nativeHandleGeneration: frame.nativeHandleGeneration,
            timelineRevision: frameTimelineRevision,
            lifecycleControlEpoch: lifecycleControlEpoch
          )
          timelineMutationIsCurrent = acceptedTimelineRevision == frameTimelineRevision
            && lifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch
            && ownsPlaybackMutation(
              frame.playbackGeneration,
              nativeHandleGeneration: frame.nativeHandleGeneration
            )
        }
        if timelineMutationIsCurrent {
          _ = recordAuthoritativeTimeline(
            position: outcomePosition,
            emissionSequence: result.emissionSequence,
            ifPlaybackGeneration: frame.playbackGeneration,
            nativeHandleGeneration: frame.nativeHandleGeneration,
            timelineRevision: frameTimelineRevision,
            lifecycleControlEpoch: lifecycleControlEpoch
          )
        }
      }

      resolvedFrame.resolver.resolve(.submitted(
        time: .milliseconds(milliseconds),
        position: outcomePosition.map { PlaybackPosition($0) }
      ))
    }
    return true
  }

  func expirePendingFrameStep(requestToken: UInt64) {
    cancelPendingFrameStep(
      requestToken: requestToken,
      resolving: .timedOut,
      allowsCommittedTimelineMutation: true
    )
    dispatchNextPendingFrameStepIfNeeded()
  }

  func cancelPendingFrameSteps() {
    cancelPendingFrameSteps(resolving: .superseded) { _ in true }
  }

  func cancelPendingFrameSteps(resolving outcome: FrameStepOutcome) {
    cancelPendingFrameSteps(resolving: outcome) { _ in true }
  }

  func cancelPendingFrameSteps(beforeFrameGeneration generation: UInt64) {
    cancelPendingFrameSteps(resolving: .superseded) {
      $0.nativeFrameGeneration < generation
    }
  }

  func cancelPendingFrameSteps(
    resolving outcome: FrameStepOutcome = .superseded,
    where shouldCancel: (PendingFrameStep) -> Bool
  ) {
    let requestTokens = pendingFrameSteps
      .filter(shouldCancel)
      .map(\.requestToken)
    guard !requestTokens.isEmpty else { return }
    for requestToken in requestTokens {
      cancelPendingFrameStep(
        requestToken: requestToken,
        resolving: outcome,
        allowsCommittedTimelineMutation: false
      )
    }
    dispatchNextPendingFrameStepIfNeeded()
  }

  func cancelPendingFrameStep(
    requestToken: UInt64,
    resolving outcome: FrameStepOutcome,
    allowsCommittedTimelineMutation: Bool
  ) {
    guard
      let initialIndex = pendingFrameSteps.firstIndex(where: {
        $0.requestToken == requestToken
      }) else { return }

    /* A reserved exact result carries native terminal/output-commit authority
     * that already won before this cancellation. Nonterminal retry and native
     * ECANCELED results release the slot but do not override the caller's
     * later cancellation reason. */
    if let reserved = nativeSeekMonitor.consumeFrameResult(requestID: requestToken) {
      if frameResultWinsCancellation(reserved) {
        _ = resolveConsumedNativeFrameResult(reserved)
      } else {
        let frame = pendingFrameSteps.remove(at: initialIndex)
        frame.timeoutTask?.cancel()
        frame.resolver.resolve(outcome)
      }
      return
    }

    let frame = pendingFrameSteps[initialIndex]
    guard frame.nativeRequestInFlight else {
      let removed = pendingFrameSteps.remove(at: initialIndex)
      removed.timeoutTask?.cancel()
      removed.resolver.resolve(outcome)
      return
    }

    let nativeCancelled = cancelNativeFrameRequest(frame)
    if let raced = nativeSeekMonitor.consumeFrameResult(requestID: requestToken) {
      if frameResultWinsCancellation(raced) {
        _ = resolveConsumedNativeFrameResult(raced)
      } else if
        let index = pendingFrameSteps.firstIndex(where: {
          $0.requestToken == requestToken
        }) {
        let removed = pendingFrameSteps.remove(at: index)
        removed.timeoutTask?.cancel()
        removed.resolver.resolve(outcome)
      }
      return
    }

    guard
      let index = pendingFrameSteps.firstIndex(where: {
        $0.requestToken == requestToken
      }) else { return }
    var removed = pendingFrameSteps.remove(at: index)
    removed.timeoutTask?.cancel()
    removed.timeoutTask = nil
    if nativeCancelled {
      removed.resolver.resolve(outcome)
    } else {
      /* Native cancellation lost to, or could not disprove, output commit.
       * Retire the command from the FIFO so successors can make progress, but
       * keep its resolver pending for the sole exact terminal event. */
      committedFrameStepsAwaitingTerminal[requestToken] =
        CommittedFrameStepAwaitingTerminal(
          frame: removed,
          fallbackOutcome: outcome,
          allowsTimelineMutation: allowsCommittedTimelineMutation
        )
    }
  }

  func frameResultWinsCancellation(_ result: NativeFrameStepResult) -> Bool {
    switch NativeFrameStepTerminalStatus(rawValue: result.status) {
    case .success, .noFrame:
      true
    case .pausedForRetry:
      false
    case .failed(let code):
      code != -Int32(POSIXErrorCode.ECANCELED.rawValue)
    }
  }

  /// Reconciles the callback lane after its native attachment has been
  /// detached/reset (or permanently closed). Drained reservations retain the
  /// exact native terminal/output-commit authority they already carry. A
  /// committed waiter with no returned proof can no longer receive its old
  /// event, so it resolves to the fallback captured when cancellation lost
  /// instead of hanging forever.
  func settleFrameStepsAfterAttachmentRetirement(
    drainedResults: [NativeFrameStepResult]
  ) {
    for result in drainedResults {
      if frameResultWinsCancellation(result) {
        _ = resolveConsumedNativeFrameResult(result)
      } else {
        resolveFrameStepFallbackAfterAttachmentRetirement(
          requestToken: result.token
        )
      }
    }

    for requestToken in Array(committedFrameStepsAwaitingTerminal.keys) {
      resolveFrameStepFallbackAfterAttachmentRetirement(
        requestToken: requestToken
      )
    }

    // Every remaining pending command belonged to the detached attachment.
    // Its context ownership was atomically cleared, so cancellation now
    // retires it without manufacturing a new committed waiter.
    cancelPendingFrameSteps()
  }

  func resolveFrameStepFallbackAfterAttachmentRetirement(
    requestToken: UInt64
  ) {
    if
      let index = pendingFrameSteps.firstIndex(where: {
        $0.requestToken == requestToken
      }) {
      let frame = pendingFrameSteps.remove(at: index)
      frame.timeoutTask?.cancel()
      frame.resolver.resolve(.superseded)
      return
    }
    if
      let committed = committedFrameStepsAwaitingTerminal
        .removeValue(forKey: requestToken) {
      committed.frame.timeoutTask?.cancel()
      committed.frame.resolver.resolve(committed.fallbackOutcome)
    }
  }

  func closeNativeFrameResultLaneForTeardown() {
    let drainedResults = nativeSeekMonitor.closeFrameResultLane()
    settleFrameStepsAfterAttachmentRetirement(
      drainedResults: drainedResults
    )
  }

  func cancelNativeFrameRequest(_ frame: PendingFrameStep) -> Bool {
    #if DEBUG
    if let _nativeCancelNextFrameOverrideForTesting {
      return nativeSeekMonitor._cancelFrameStepForTesting(
        requestID: frame.requestToken
      ) {
        _nativeCancelNextFrameOverrideForTesting(frame.requestToken)
      }
    }
    #endif
    return nativeSeekMonitor.cancelFrameRequest(requestID: frame.requestToken)
  }
}
