import CLibVLC

extension Player {
  func submitNativeSeek(
    operation: NativeSeekOperation,
    evidence: SeekSettlementEvidence,
    publication: SeekOptimisticPublication
  ) -> SeekRequest? {
    let nativeSeekToken = nativeSeekMonitor.reserveCommand()
    let resolver = SeekOutcomeResolver()
    let command = NativeSeekCommand(
      nativeSeekToken: nativeSeekToken,
      playbackGeneration: sessionGeneration,
      externalEpoch: nativeSeekMonitor.externalSeekEpoch,
      timelineRevision: nil,
      dispatchEmissionSequence: nil,
      operation: operation,
      evidence: evidence,
      publication: publication,
      resolver: resolver
    )

    if activeNativeSeek == nil, queuedNativeSeek == nil {
      // Native baseline/duration getters can synchronously pump a tokenless
      // seek callback. Collect every dispatch fact before exposing B in the
      // watcher FIFO, then reject the reservation if that getter advanced the
      // external epoch.
      var dispatchedCommand = finalizeSeekCommandForDispatch(command)
      let finalizedExternalEpoch = nativeSeekMonitor.externalSeekEpoch
      guard finalizedExternalEpoch == command.externalEpoch else {
        nativeSeekMonitor.cancelReservedCommand(nativeSeekToken)
        resolver.resolve(.superseded)
        return SeekRequest(resolver: resolver)
      }
      guard
        nativeSeekMonitor.stageReservedCommandIfIdle(
          nativeSeekToken,
          expectedExternalEpoch: command.externalEpoch
        ) else {
        return queueNativeSeek(command, resolver: resolver)
      }
      dispatchedCommand.timelineRevision = eventBridge.advanceTimelineRevision()
      dispatchedCommand.dispatchEmissionSequence = eventBridge
        .advanceNativeTimelineEmissionSequence()
      activeNativeSeek = makeActiveNativeSeek(for: dispatchedCommand)
      let pipRebuildPermit = stageNativePiPVideoOutputRebuildPermit()
      guard issueNativeSeekCommand(dispatchedCommand) == 0 else {
        activeNativeSeek = nil
        nativeSeekMonitor.cancelCommand(nativeSeekToken)
        nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
        cancelNativePiPVideoOutputRebuildPermit(pipRebuildPermit)
        resolver.resolve(.rejected)
        return nil
      }
      guard
        nativeSeekMonitor.consumeValidDispatchOwnership(
          nativeSeekToken,
          expectedExternalEpoch: dispatchedCommand.externalEpoch
        ) else {
        // The setter returned, but its staged token was not claimed by an
        // exact synchronous callback, or a tokenless episode interleaved and
        // changed/overlapped ownership. The native request may still drain as
        // a tombstone, but B must never publish or settle from it.
        activeNativeSeek = nil
        nativeSeekMonitor.cancelCommand(nativeSeekToken)
        nativeSeekMonitor.cancelStagedCommand(nativeSeekToken)
        cancelNativePiPVideoOutputRebuildPermit(pipRebuildPermit)
        resolver.resolve(.superseded)
        return SeekRequest(resolver: resolver)
      }
      latestWrapperDispatchExternalSeekEpoch = max(
        latestWrapperDispatchExternalSeekEpoch,
        dispatchedCommand.externalEpoch
      )
      startActiveNativeSeekDeadline(dispatchedCommand)
      acceptPublicSeekCommand(
        dispatchedCommand,
        allowsPausedFallback: true,
        deadlinePhase: .dispatched
      )
      return SeekRequest(resolver: resolver)
    }

    return queueNativeSeek(command, resolver: resolver)
  }

  func queueNativeSeek(
    _ command: NativeSeekCommand,
    resolver: SeekOutcomeResolver
  ) -> SeekRequest {
    var queuedCommand = rebaseRelativeSeekIfSafe(
      command,
      after: activeNativeSeek?.command
    )
    if let previousQueued = queuedNativeSeek {
      queuedCommand = mergeQueuedSeekReplacement(
        queuedCommand,
        replacing: previousQueued
      )
    }
    supersedePublicSeekForNewCommand()
    queuedNativeSeek = queuedCommand
    acceptPublicSeekCommand(
      queuedCommand,
      allowsPausedFallback: false,
      deadlinePhase: .queued
    )
    return SeekRequest(resolver: resolver)
  }

  func makeActiveNativeSeek(for command: NativeSeekCommand) -> ActiveNativeSeek {
    ActiveNativeSeek(
      command: command,
      firstPostEndTimeMilliseconds: nil,
      firstPostEndPosition: nil,
      allowsPausedFallback: nativeSeekMonitor.commandAllowsPausedFallback(
        command.nativeSeekToken
      ),
      isTombstoned: false,
      deadlineTask: nil,
      pollingTask: nil
    )
  }

  /// Bounds a dispatched native owner independently from whichever public
  /// resolver is newest. Superseding A with B cancels A's public deadline, but
  /// A must still be tombstoned if its native episode never terminates. The
  /// tombstone retains the single-flight lease until watched drain evidence or
  /// a true timeline-replacement boundary arrives.
  func startActiveNativeSeekDeadline(_ command: NativeSeekCommand) {
    let nativeSeekToken = command.nativeSeekToken
    let playbackGeneration = command.playbackGeneration
    let deadlineTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      self?.expireActiveNativeSeek(
        nativeSeekToken: nativeSeekToken,
        playbackGeneration: playbackGeneration
      )
    }
    guard
      activeNativeSeek?.command.nativeSeekToken == nativeSeekToken,
      activeNativeSeek?.command.playbackGeneration == playbackGeneration
    else {
      deadlineTask.cancel()
      return
    }
    activeNativeSeek?.deadlineTask = deadlineTask
  }

  func acceptPublicSeekCommand(
    _ command: NativeSeekCommand,
    allowsPausedFallback: Bool,
    deadlinePhase: SeekSettlementDeadlinePhase
  ) {
    supersedePublicSeekForNewCommand()
    cancelPendingFrameSteps()
    pendingSeekSettlement = PendingSeekSettlement(
      playbackGeneration: command.playbackGeneration,
      timelineRevision: command.timelineRevision,
      nativeSeekToken: command.nativeSeekToken,
      resolver: command.resolver,
      baselineTimeMilliseconds: command.evidence.baselineTimeMilliseconds,
      baselinePosition: command.evidence.baselinePosition,
      requestedTimeMilliseconds: command.evidence.requestedTimeMilliseconds,
      requestedPosition: command.evidence.requestedPosition,
      firstPostEndTimeMilliseconds: nil,
      firstPostEndPosition: nil,
      allowsPausedFallback: allowsPausedFallback,
      deadlinePhase: deadlinePhase,
      timeoutTask: nil,
      pollingTask: nil
    )
    if deadlinePhase == .dispatched {
      publishDispatchedSeekCommand(command)
      beginRawTimelineQuarantine(for: command)
    }
    startPendingSeekTimeout(command, phase: deadlinePhase)
  }

  /// Starts or restarts the current public deadline. A queued request has a
  /// bounded wait, but native dispatch transitions it to `.dispatched` and
  /// grants a fresh landing window. The captured phase also rejects a queued
  /// timer whose main-actor resumption races that transition after cancellation.
  func startPendingSeekTimeout(
    _ command: NativeSeekCommand,
    phase: SeekSettlementDeadlinePhase
  ) {
    let nativeSeekToken = command.nativeSeekToken
    let resolver = command.resolver
    guard
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === resolver
    else { return }
    pendingSeekSettlement?.timeoutTask?.cancel()
    pendingSeekSettlement?.deadlinePhase = phase
    let timeoutTask = Task { @MainActor [weak self, weak resolver] in
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      guard let resolver else { return }
      self?.expirePendingSeek(
        nativeSeekToken: nativeSeekToken,
        resolver: resolver,
        deadlinePhase: phase
      )
    }
    guard
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === resolver
    else {
      timeoutTask.cancel()
      return
    }
    pendingSeekSettlement?.timeoutTask = timeoutTask
  }

  func publishDispatchedSeekCommand(_ command: NativeSeekCommand) {
    guard
      let timelineRevision = command.timelineRevision,
      let dispatchEmissionSequence = command.dispatchEmissionSequence
    else {
      assertionFailure("A queued seek cannot publish before native dispatch")
      return
    }
    commitNativeTimelineEmission(dispatchEmissionSequence)
    switch command.publication {
    case .time(let milliseconds):
      commitSeekTarget(
        milliseconds: milliseconds,
        revision: timelineRevision,
        emissionSequence: dispatchEmissionSequence
      )
    case .position(let position, let timeMilliseconds):
      acceptedTimelineRevision = timelineRevision
      withMutation(keyPath: \.position) {
        _position = position
      }
      if let timeMilliseconds {
        currentTime = .milliseconds(timeMilliseconds)
      }
      recordAuthoritativeTimeline(
        position: position,
        emissionSequence: dispatchEmissionSequence
      )
      markPlaybackHealthSeek()
    case .revisionOnly:
      acceptedTimelineRevision = timelineRevision
      recordAuthoritativeTimeline(
        position: position,
        emissionSequence: dispatchEmissionSequence
      )
      markPlaybackHealthSeek()
    }
  }

  func beginRawTimelineQuarantine(for command: NativeSeekCommand) {
    guard command.timelineRevision != nil else {
      assertionFailure("A queued seek cannot quarantine the native clock")
      return
    }
    quarantinedSeekTimeline = QuarantinedSeekTimeline(
      nativeSeekToken: command.nativeSeekToken,
      playbackGeneration: command.playbackGeneration,
      time: nil,
      timeEmissionSequence: nil,
      position: nil,
      positionEmissionSequence: nil
    )
  }

  /// Retains native clock samples while the request-ID-less watcher belongs
  /// to one dispatched wrapper seek. A command queued behind that owner has
  /// not yet established timeline authority, so callbacks from the active
  /// episode must not make its optimistic/native in-flight clock observable.
  func quarantineSeekTimelineSampleIfNeeded(_ sourcedEvent: SourcedPlayerEvent) -> Bool {
    guard
      let activeNativeSeek,
      activeNativeSeek.command.timelineRevision != nil,
      activeNativeSeek.command.playbackGeneration == sourcedEvent.playbackGeneration,
      quarantinedSeekTimeline?.nativeSeekToken
      == activeNativeSeek.command.nativeSeekToken
    else { return false }

    switch sourcedEvent.event {
    case .timeChanged(let time):
      let sequence = sourcedEvent.nativeSeekEmissionStamp?.timelineEmissionSequence
      let shouldReplace = sequence.map {
        $0 >= (quarantinedSeekTimeline?.timeEmissionSequence ?? 0)
      } ?? true
      if shouldReplace {
        quarantinedSeekTimeline?.time = time
        quarantinedSeekTimeline?.timeEmissionSequence = sequence ?? 0
      }
      return true
    case .positionChanged(let position):
      let sequence = sourcedEvent.nativeSeekEmissionStamp?.timelineEmissionSequence
      let shouldReplace = sequence.map {
        $0 >= (quarantinedSeekTimeline?.positionEmissionSequence ?? 0)
      } ?? true
      if shouldReplace {
        quarantinedSeekTimeline?.position = position
        quarantinedSeekTimeline?.positionEmissionSequence = sequence ?? 0
      }
      return true
    default:
      return false
    }
  }

  func discardQuarantinedSeekTimeline(nativeSeekToken: UInt64) {
    guard quarantinedSeekTimeline?.nativeSeekToken == nativeSeekToken else { return }
    quarantinedSeekTimeline = nil
  }

  func takeQuarantinedSeekTimeline(
    nativeSeekToken: UInt64
  ) -> QuarantinedSeekTimeline? {
    guard quarantinedSeekTimeline?.nativeSeekToken == nativeSeekToken else { return nil }
    defer { quarantinedSeekTimeline = nil }
    return quarantinedSeekTimeline
  }

  /// Replays only samples which entered the shared emission authority after a
  /// committed landing. This handles executor inversion without weakening the
  /// in-flight quarantine: pre-landing samples stay discarded.
  func applyQuarantinedSeekTimeline(
    _ timeline: QuarantinedSeekTimeline,
    afterEmissionSequence minimumSequence: UInt64 = 0
  ) {
    var samples: [(sequence: UInt64, event: PlayerEvent)] = []
    if
      let time = timeline.time,
      let sequence = timeline.timeEmissionSequence,
      sequence == 0 || sequence > minimumSequence {
      samples.append((sequence, .timeChanged(time)))
    }
    if
      let position = timeline.position,
      let sequence = timeline.positionEmissionSequence,
      sequence == 0 || sequence > minimumSequence {
      samples.append((sequence, .positionChanged(position)))
    }
    samples.sort { lhs, rhs in lhs.sequence < rhs.sequence }
    for sample in samples where canCommitNativeTimelineEmission(sample.sequence) {
      commitNativeTimelineEmission(sample.sequence)
      handleEvent(sample.event)
      recordAuthoritativeTimeline(
        position: position,
        emissionSequence: sample.sequence
      )
    }
  }

  /// Once no newer public command can still dispatch, a timed-out wrapper
  /// request no longer has permission to hide the engine's latest raw clock.
  /// Releasing it updates observable truth without changing the request's
  /// already terminal `.timedOut` outcome.
  func releaseQuarantinedSeekTimelineIfNoSuccessor() {
    guard queuedNativeSeek == nil, let quarantinedSeekTimeline else { return }
    self.quarantinedSeekTimeline = nil
    applyQuarantinedSeekTimeline(quarantinedSeekTimeline)
  }

  func issueNativeSeekCommand(_ command: NativeSeekCommand) -> Int32 {
    nativeSeekMonitor.withCausalSeekInvocation(token: command.nativeSeekToken) {
      let result: Int32 = switch command.operation {
      case .time(let milliseconds, let fast):
        issueNativeSeek(toMilliseconds: milliseconds, fast: fast)
      case .position(let position, let fast):
        issueNativeSeek(toPosition: position, fast: fast)
      case .relative(let milliseconds):
        issueNativeJump(byMilliseconds: milliseconds)
      case .strictRelative, .composed:
        // A composition which could not be represented at dispatch (for
        // example, fractional intent after duration became unknown) fails closed.
        -1
      }
      #if DEBUG
      let overrideBypassesNativeStart = switch command.operation {
      case .time: _nativeSetTimeOverrideForTesting != nil
      case .position: _nativeSetPositionOverrideForTesting != nil
      case .relative: _nativeJumpTimeOverrideForTesting != nil
      case .strictRelative, .composed: false
      }
      if result == 0, overrideBypassesNativeStart {
        // Test overrides bypass the real setter's synchronous watcher start.
        // Supply only this exact causal start; an override which already sent
        // the full callback sequence leaves no staged token and this is a no-op.
        nativeSeekMonitor._noteSeekStartedForTesting(
          ifStagedToken: command.nativeSeekToken
        )
      }
      #endif
      return result
    }
  }

  /// Rebases the first queued relative request on the active command's intended
  /// target so later relative aggregation describes the user's command chain,
  /// not the optimistic clock value captured before A was accepted.
  func rebaseRelativeSeekIfSafe(
    _ command: NativeSeekCommand,
    after active: NativeSeekCommand?
  ) -> NativeSeekCommand {
    guard
      let active,
      command.playbackGeneration == active.playbackGeneration,
      command.externalEpoch == active.externalEpoch,
      case .relative(let offset) = command.operation,
      let activeTarget = active.evidence.requestedTimeMilliseconds,
      let target = clampedRelativeTarget(
        baselineMilliseconds: activeTarget,
        offsetMilliseconds: offset
      )
    else { return command }

    var rebased = command
    rebased.evidence = makeComposedSeekEvidence(
      baseline: command.evidence,
      requestedTimeMilliseconds: target
    )
    if case .time = command.publication {
      rebased.publication = .time(milliseconds: target)
    }
    return rebased
  }

  /// Merges a queued replacement without applying enqueue-time duration to a
  /// target which will only enter VLC later. Pure relative chains retain native
  /// jump semantics. Absolute/fractional intent followed by relative commands
  /// retains its base plus every offset and resolves them once, immediately
  /// before dispatch, against the then-current duration.
  func mergeQueuedSeekReplacement(
    _ replacement: NativeSeekCommand,
    replacing previous: NativeSeekCommand
  ) -> NativeSeekCommand {
    guard
      replacement.playbackGeneration == previous.playbackGeneration,
      replacement.externalEpoch == previous.externalEpoch
    else { return replacement }

    if
      case .strictRelative(let replacementIntent) = replacement.operation,
      case .strictRelative(var previousIntent) = previous.operation {
      previousIntent.offsetsMilliseconds.append(
        contentsOf: replacementIntent.offsetsMilliseconds
      )
      // The newest strict request owns the public resolver and therefore its
      // precision policy controls the one aggregate native dispatch.
      previousIntent.fast = replacementIntent.fast
      var aggregate = replacement
      aggregate.operation = .strictRelative(previousIntent)
      let target = resolveStrictRelativeSeekIntent(previousIntent)
      aggregate.evidence = makeComposedSeekEvidence(
        baseline: previous.evidence,
        requestedTimeMilliseconds: target
      )
      aggregate.publication = target.map {
        .time(milliseconds: $0)
      } ?? .revisionOnly
      return aggregate
    }

    guard case .relative(let replacementOffset) = replacement.operation else {
      return replacement
    }

    switch previous.operation {
    case .relative(let previousOffset):
      let aggregate = previousOffset.addingReportingOverflow(replacementOffset)
      guard !aggregate.overflow else {
        var rejected = replacement
        rejected.operation = .composed(DeferredSeekComposition(
          base: .invalid,
          relativeOffsetsMilliseconds: []
        ))
        return rejected
      }

      var composed = replacement
      composed.operation = .relative(milliseconds: aggregate.partialValue)
      let targetMilliseconds: Int64? = if
        let previousTarget = previous.evidence.requestedTimeMilliseconds {
        clampedRelativeTarget(
          baselineMilliseconds: previousTarget,
          offsetMilliseconds: replacementOffset
        )
      } else {
        nil
      }
      composed.evidence = makeComposedSeekEvidence(
        baseline: previous.evidence,
        requestedTimeMilliseconds: targetMilliseconds
      )
      if case .time = replacement.publication, let targetMilliseconds {
        composed.publication = .time(milliseconds: targetMilliseconds)
      }
      return composed

    case .time(let milliseconds, _):
      return makeDeferredSeekComposition(
        base: .absoluteMilliseconds(milliseconds),
        previous: previous,
        replacement: replacement,
        offsetMilliseconds: replacementOffset
      )

    case .position(let position, _):
      return makeDeferredSeekComposition(
        base: .position(position),
        previous: previous,
        replacement: replacement,
        offsetMilliseconds: replacementOffset
      )

    case .composed(var composition):
      composition.relativeOffsetsMilliseconds.append(replacementOffset)
      return makeDeferredSeekComposition(
        composition: composition,
        previous: previous,
        replacement: replacement
      )

    case .strictRelative:
      // A lenient native jump replacing strict VOD intent remains the latest
      // command. Its raw relative semantics are intentionally preserved.
      return replacement
    }
  }

  /// Applies every accepted strict relative offset before clamping once to the
  /// playable timeline visible at actual native dispatch. Overflow rejects the
  /// aggregate instead of silently dropping an earlier button press.
  func resolveStrictRelativeSeekIntent(
    _ intent: StrictRelativeSeekIntent
  ) -> Int64? {
    var target = intent.baseMilliseconds
    for offset in intent.offsetsMilliseconds {
      let addition = target.addingReportingOverflow(offset)
      guard !addition.overflow else { return nil }
      target = addition.partialValue
    }
    target = max(0, target)
    if let durationMilliseconds = currentDurationMilliseconds {
      target = min(target, durationMilliseconds)
    }
    return target
  }

  func makeDeferredSeekComposition(
    base: DeferredSeekCompositionBase,
    previous: NativeSeekCommand,
    replacement: NativeSeekCommand,
    offsetMilliseconds: Int64
  ) -> NativeSeekCommand {
    makeDeferredSeekComposition(
      composition: DeferredSeekComposition(
        base: base,
        relativeOffsetsMilliseconds: [offsetMilliseconds]
      ),
      previous: previous,
      replacement: replacement
    )
  }

  func makeDeferredSeekComposition(
    composition: DeferredSeekComposition,
    previous: NativeSeekCommand,
    replacement: NativeSeekCommand
  ) -> NativeSeekCommand {
    var composed = replacement
    composed.operation = .composed(composition)
    let estimatedTarget = resolveDeferredSeekComposition(composition)
    composed.evidence = makeComposedSeekEvidence(
      baseline: previous.evidence,
      requestedTimeMilliseconds: estimatedTarget
    )
    if case .time = replacement.publication, let estimatedTarget {
      composed.publication = .time(milliseconds: estimatedTarget)
    }
    return composed
  }

  /// Resolves a composition using one duration snapshot and clamps only after
  /// every offset is applied. Any arithmetic overflow is rejected rather than
  /// silently dropping earlier user intent.
  func resolveDeferredSeekComposition(
    _ composition: DeferredSeekComposition
  ) -> Int64? {
    let baseMilliseconds: Int64
    switch composition.base {
    case .absoluteMilliseconds(let milliseconds):
      baseMilliseconds = milliseconds
    case .position(let position):
      guard let durationMilliseconds = currentDurationMilliseconds else { return nil }
      baseMilliseconds = checkedMilliseconds(
        for: PlaybackPosition(position),
        durationMs: durationMilliseconds
      )
    case .invalid:
      return nil
    }

    var target = baseMilliseconds
    for offset in composition.relativeOffsetsMilliseconds {
      let result = target.addingReportingOverflow(offset)
      guard !result.overflow else { return nil }
      target = result.partialValue
    }
    target = max(0, target)
    if let durationMilliseconds = currentDurationMilliseconds {
      target = min(target, durationMilliseconds)
    }
    return target
  }

  func clampedRelativeTarget(
    baselineMilliseconds: Int64,
    offsetMilliseconds: Int64
  ) -> Int64? {
    let target = baselineMilliseconds.addingReportingOverflow(offsetMilliseconds)
    guard !target.overflow else { return nil }
    var clamped = max(0, target.partialValue)
    if
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ) {
      clamped = min(clamped, durationMilliseconds)
    }
    return clamped
  }

  func makeComposedSeekEvidence(
    baseline: SeekSettlementEvidence,
    requestedTimeMilliseconds: Int64?
  ) -> SeekSettlementEvidence {
    let requestedPosition: Double? = if
      let requestedTimeMilliseconds,
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ),
      durationMilliseconds > 0 {
      min(1, max(0, Double(requestedTimeMilliseconds) / Double(durationMilliseconds)))
    } else {
      nil
    }
    return SeekSettlementEvidence(
      baselineTimeMilliseconds: baseline.baselineTimeMilliseconds,
      baselinePosition: baseline.baselinePosition,
      requestedTimeMilliseconds: requestedTimeMilliseconds,
      requestedPosition: requestedPosition
    )
  }

  /// Re-reads native evidence at the actual dispatch boundary. A queued
  /// command can wait behind a keyframe-adjusted landing for nearly its full
  /// queue deadline; enqueue-time getters then describe the previous episode
  /// and can make that landing look like stable evidence for the successor.
  func finalizeSeekCommandForDispatch(
    _ command: NativeSeekCommand
  ) -> NativeSeekCommand {
    var finalized = command
    let baseline = nativeSeekClockPointForEvidence()

    switch command.operation {
    case .time(let milliseconds, _):
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: milliseconds
      )
      if case .time = command.publication {
        finalized.publication = .time(milliseconds: milliseconds)
      }

    case .position(let position, _):
      let requestedTimeMilliseconds = currentDurationMilliseconds.map {
        checkedMilliseconds(for: PlaybackPosition(position), durationMs: $0)
      }
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds,
        requestedPosition: position
      )
      finalized.publication = .position(
        position,
        timeMilliseconds: requestedTimeMilliseconds
      )

    case .relative(let milliseconds):
      let requestedTimeMilliseconds = baseline.timeMilliseconds.flatMap {
        clampedRelativeTarget(
          baselineMilliseconds: $0,
          offsetMilliseconds: milliseconds
        )
      }
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds
      )
      if case .time = command.publication {
        finalized.publication = requestedTimeMilliseconds.map {
          .time(milliseconds: $0)
        } ?? .revisionOnly
      }

    case .strictRelative(let intent):
      guard let requestedTimeMilliseconds = resolveStrictRelativeSeekIntent(intent) else {
        finalized.evidence = makeSeekSettlementEvidence(
          baseline: baseline,
          requestedTimeMilliseconds: nil
        )
        return finalized
      }
      finalized.operation = .time(
        milliseconds: requestedTimeMilliseconds,
        fast: intent.fast
      )
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds
      )
      finalized.publication = .time(milliseconds: requestedTimeMilliseconds)

    case .composed(let composition):
      guard let requestedTimeMilliseconds = resolveDeferredSeekComposition(composition) else {
        finalized.evidence = makeSeekSettlementEvidence(
          baseline: baseline,
          requestedTimeMilliseconds: nil
        )
        return finalized
      }
      finalized.operation = .time(
        milliseconds: requestedTimeMilliseconds,
        fast: false
      )
      finalized.evidence = makeSeekSettlementEvidence(
        baseline: baseline,
        requestedTimeMilliseconds: requestedTimeMilliseconds
      )
      if case .time = command.publication {
        finalized.publication = .time(milliseconds: requestedTimeMilliseconds)
      }
    }
    return finalized
  }

  var currentDurationMilliseconds: Int64? {
    guard let duration else { return nil }
    return try? duration.checkedNonnegativeMilliseconds(parameter: "duration")
  }

  func dispatchQueuedNativeSeekIfPossible() {
    guard
      !isShutdown,
      activeNativeSeek == nil,
      let queuedCommand = queuedNativeSeek,
      queuedCommand.playbackGeneration == sessionGeneration
    else { return }

    let currentExternalEpoch = nativeSeekMonitor.externalSeekEpoch
    guard queuedCommand.externalEpoch == currentExternalEpoch else {
      // A native external start advances this epoch on the callback thread.
      // Do not wait for its independently scheduled MainActor notification:
      // stale queued work must never cross into the watcher FIFO.
      quarantineSeekWork(beforeExternalEpoch: currentExternalEpoch)
      return
    }
    var command = finalizeSeekCommandForDispatch(queuedCommand)
    let finalizedExternalEpoch = nativeSeekMonitor.externalSeekEpoch
    guard queuedCommand.externalEpoch == finalizedExternalEpoch else {
      quarantineSeekWork(beforeExternalEpoch: finalizedExternalEpoch)
      return
    }
    guard
      nativeSeekMonitor.stageReservedCommandIfIdle(
        queuedCommand.nativeSeekToken,
        expectedExternalEpoch: queuedCommand.externalEpoch
      ) else { return }

    command.timelineRevision = eventBridge.advanceTimelineRevision()
    command.dispatchEmissionSequence = eventBridge
      .advanceNativeTimelineEmissionSequence()
    queuedNativeSeek = nil
    activeNativeSeek = makeActiveNativeSeek(for: command)
    let pipRebuildPermit = stageNativePiPVideoOutputRebuildPermit()
    guard issueNativeSeekCommand(command) == 0 else {
      activeNativeSeek = nil
      nativeSeekMonitor.cancelCommand(command.nativeSeekToken)
      nativeSeekMonitor.cancelStagedCommand(command.nativeSeekToken)
      cancelNativePiPVideoOutputRebuildPermit(pipRebuildPermit)
      finishCurrentPublicSeek(
        nativeSeekToken: command.nativeSeekToken,
        resolver: command.resolver,
        outcome: .rejected
      )
      return
    }
    guard
      nativeSeekMonitor.consumeValidDispatchOwnership(
        command.nativeSeekToken,
        expectedExternalEpoch: command.externalEpoch
      ) else {
      activeNativeSeek = nil
      nativeSeekMonitor.cancelCommand(command.nativeSeekToken)
      nativeSeekMonitor.cancelStagedCommand(command.nativeSeekToken)
      cancelNativePiPVideoOutputRebuildPermit(pipRebuildPermit)
      finishCurrentPublicSeek(
        nativeSeekToken: command.nativeSeekToken,
        resolver: command.resolver,
        outcome: .superseded
      )
      return
    }
    latestWrapperDispatchExternalSeekEpoch = max(
      latestWrapperDispatchExternalSeekEpoch,
      command.externalEpoch
    )
    if
      pendingSeekSettlement?.nativeSeekToken == command.nativeSeekToken,
      pendingSeekSettlement?.resolver === command.resolver {
      pendingSeekSettlement?.timelineRevision = command.timelineRevision
      pendingSeekSettlement?.allowsPausedFallback = activeNativeSeek?.allowsPausedFallback ?? false
      pendingSeekSettlement?.baselineTimeMilliseconds =
        command.evidence.baselineTimeMilliseconds
      pendingSeekSettlement?.baselinePosition = command.evidence.baselinePosition
      pendingSeekSettlement?.requestedTimeMilliseconds =
        command.evidence.requestedTimeMilliseconds
      pendingSeekSettlement?.requestedPosition = command.evidence.requestedPosition
    }
    publishDispatchedSeekCommand(command)
    beginRawTimelineQuarantine(for: command)
    startActiveNativeSeekDeadline(command)
    startPendingSeekTimeout(command, phase: .dispatched)
  }

  func supersedePublicSeekForNewCommand() {
    guard let pendingSeekSettlement else { return }
    self.pendingSeekSettlement = nil
    pendingSeekSettlement.timeoutTask?.cancel()
    pendingSeekSettlement.pollingTask?.cancel()
    if queuedNativeSeek?.nativeSeekToken == pendingSeekSettlement.nativeSeekToken {
      nativeSeekMonitor.cancelReservedCommand(pendingSeekSettlement.nativeSeekToken)
      queuedNativeSeek = nil
    }
    pendingSeekSettlement.resolver.resolve(.superseded)
  }

  func expirePendingSeek(
    nativeSeekToken: UInt64,
    resolver: SeekOutcomeResolver,
    deadlinePhase: SeekSettlementDeadlinePhase
  ) {
    reconcileCommittedNativeSeekProgress()
    guard
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === resolver,
      pendingSeekSettlement?.deadlinePhase == deadlinePhase
    else { return }
    if activeNativeSeek?.command.nativeSeekToken == nativeSeekToken {
      expireActiveNativeSeek(
        nativeSeekToken: nativeSeekToken,
        playbackGeneration: activeNativeSeek?.command.playbackGeneration
      )
      return
    }
    finishCurrentPublicSeek(
      nativeSeekToken: nativeSeekToken,
      resolver: resolver,
      outcome: .timedOut
    )
  }

  func expireActiveNativeSeek(
    nativeSeekToken: UInt64,
    playbackGeneration: UInt64?
  ) {
    reconcileCommittedNativeSeekProgress()
    guard
      var activeNativeSeek,
      activeNativeSeek.command.nativeSeekToken == nativeSeekToken,
      playbackGeneration == nil
      || activeNativeSeek.command.playbackGeneration == playbackGeneration,
      !activeNativeSeek.isTombstoned
    else { return }

    activeNativeSeek.deadlineTask?.cancel()
    activeNativeSeek.deadlineTask = nil
    activeNativeSeek.pollingTask?.cancel()
    activeNativeSeek.pollingTask = nil
    activeNativeSeek.allowsPausedFallback = false
    activeNativeSeek.isTombstoned = true
    self.activeNativeSeek = activeNativeSeek
    nativeSeekMonitor.cancelCommand(nativeSeekToken)

    if
      pendingSeekSettlement?.nativeSeekToken == nativeSeekToken,
      pendingSeekSettlement?.resolver === activeNativeSeek.command.resolver {
      finishCurrentPublicSeek(
        nativeSeekToken: nativeSeekToken,
        resolver: activeNativeSeek.command.resolver,
        outcome: .timedOut
      )
    }
    dispatchNextPendingFrameStepIfNeeded()
  }

  var seekBaselineTimeMilliseconds: Int64? {
    guard
      let milliseconds = try? currentTime.checkedMilliseconds(parameter: "currentTime"),
      milliseconds >= 0
    else { return nil }
    return milliseconds
  }

  /// Reads the native clock before dispatch. The observable timeline can
  /// already contain an optimistic target from an earlier seek, so it cannot
  /// prove whether a later post-end getter changed for this command.
  func nativeSeekClockPointForEvidence()
    -> (timeMilliseconds: Int64?, position: Double?) {
    let point: (timeMilliseconds: Int64, position: Double)
    #if DEBUG
    if let override = _nativeSeekBaselineOverrideForTesting {
      point = override()
    } else {
      point = (
        libvlc_media_player_get_time(pointer),
        libvlc_media_player_get_position(pointer)
      )
    }
    #else
    point = (
      libvlc_media_player_get_time(pointer),
      libvlc_media_player_get_position(pointer)
    )
    #endif
    let time = point.timeMilliseconds >= 0 ? point.timeMilliseconds : nil
    let position = point.position.isFinite && (0.0...1.0).contains(point.position)
      ? point.position
      : nil
    return (time, position)
  }

  func makeSeekSettlementEvidence(
    requestedTimeMilliseconds: Int64?,
    requestedPosition: Double? = nil
  ) -> SeekSettlementEvidence {
    makeSeekSettlementEvidence(
      baseline: nativeSeekClockPointForEvidence(),
      requestedTimeMilliseconds: requestedTimeMilliseconds,
      requestedPosition: requestedPosition
    )
  }

  func makeSeekSettlementEvidence(
    baseline nativeBaseline: (timeMilliseconds: Int64?, position: Double?),
    requestedTimeMilliseconds: Int64?,
    requestedPosition: Double? = nil
  ) -> SeekSettlementEvidence {
    let derivedRequestedPosition: Double? = if let requestedPosition {
      requestedPosition
    } else if
      let requestedTimeMilliseconds,
      let duration,
      let durationMilliseconds = try? duration.checkedNonnegativeMilliseconds(
        parameter: "duration"
      ),
      durationMilliseconds > 0 {
      min(
        1,
        max(0, Double(requestedTimeMilliseconds) / Double(durationMilliseconds))
      )
    } else {
      nil
    }
    return SeekSettlementEvidence(
      baselineTimeMilliseconds: nativeBaseline.timeMilliseconds,
      baselinePosition: nativeBaseline.position,
      requestedTimeMilliseconds: requestedTimeMilliseconds,
      requestedPosition: derivedRequestedPosition
    )
  }

  // Applies the authoritative landed point attributed to the sole serialized
  // native seek episode. Ordinary pre-seek and in-flight time callbacks cannot
  // produce this wrapper token.
}
