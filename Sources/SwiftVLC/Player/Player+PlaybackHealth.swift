import Foundation

struct PlaybackRendererHealthSample: Sendable, Equatable {
  var playbackGeneration: UInt64?
  var voutGeneration: UInt64?
  var decodedFrames: UInt64 = 0
  var enqueuedFrames: UInt64 = 0
  var presentedFrames: UInt64 = 0
  var droppedFrames: UInt64 = 0
  var rebuilds: UInt64 = 0
  var flushes: UInt64 = 0
  var backpressureDrops: UInt64 = 0
  var replacements: UInt64 = 0
  var recoveryRetries: UInt64 = 0
  var recoveryFailures: UInt64 = 0
  var lastDecodedAt: ContinuousClock.Instant?
  var lastEnqueuedAt: ContinuousClock.Instant?
  var lastPresentedAt: ContinuousClock.Instant?
  var status: PlaybackRendererStatus = .unavailable
}

struct PlaybackHealthMonitoringState {
  var generation: UInt64 = 0
  var startedAt = ContinuousClock.now
  var rendererBaseline: PlaybackRendererHealthSample?
  var previousCounters = PlaybackHealthCounters()
  var lastSourceProgressAt = ContinuousClock.now
  var lastDecodedProgressAt = ContinuousClock.now
  var lastAudioDecodedProgressAt = ContinuousClock.now
  var lastPresentedProgressAt = ContinuousClock.now
  var lastAudioProgressAt = ContinuousClock.now
  var activePlaybackBeganAt = ContinuousClock.now
  var firstDecodedEmitted = false
  var firstPresentedEmitted = false
  var pendingWaitingReason: PlaybackWaitingReason?
  var pendingWaitingBeganAt: ContinuousClock.Instant?
  var pendingPresentedBaseline: UInt64 = 0
  var pendingAudioBaseline: UInt64 = 0
  var lastStallReason: PlaybackStallReason?
  var activeStallReason: PlaybackStallReason?
  var lastStalledAt: Duration?
  var lastRecoveredAt: Duration?
  var observedRendererFlushes: UInt64 = 0

  mutating func reset(
    generation: UInt64,
    rendererBaseline: PlaybackRendererHealthSample?
  ) {
    let now = ContinuousClock.now
    self.generation = generation
    startedAt = now
    self.rendererBaseline = rendererBaseline
    previousCounters = PlaybackHealthCounters()
    lastSourceProgressAt = now
    lastDecodedProgressAt = now
    lastAudioDecodedProgressAt = now
    lastPresentedProgressAt = now
    lastAudioProgressAt = now
    activePlaybackBeganAt = now
    firstDecodedEmitted = false
    firstPresentedEmitted = false
    pendingWaitingReason = nil
    pendingWaitingBeganAt = nil
    pendingPresentedBaseline = 0
    pendingAudioBaseline = 0
    lastStallReason = nil
    activeStallReason = nil
    lastStalledAt = nil
    lastRecoveredAt = nil
    observedRendererFlushes = 0
  }
}

private struct PlaybackHealthMutationIdentity {
  let playbackGeneration: UInt64
  let nativeHandleGeneration: UInt64
  let timelineRevision: UInt64
  let lifecycleControlEpoch: UInt64
}

/// Playback-health publication and the low-rate classifier that drives it.
extension Player {
  /// How often cumulative pipeline counters are sampled.
  ///
  /// This is deliberately independent of source cadence: 24, 60, and 120 fps
  /// all cost four public samples per second.
  public nonisolated static var playbackHealthSamplingInterval: Duration {
    .milliseconds(250)
  }

  /// A pipeline stage becomes stalled only after this much time without the
  /// progress expected from the stages before it.
  public nonisolated static var playbackHealthStallThreshold: Duration {
    .seconds(2)
  }

  /// Current playback-health snapshots, replaying the latest value to a late
  /// subscriber. The stream is bounded because each value supersedes the prior
  /// point-in-time sample.
  public nonisolated var playbackHealthSnapshots: AsyncStream<PlaybackHealthSnapshot> {
    playbackHealthSnapshotBridge.subscribeReplayingLatest(policy: .newest(1))
  }

  /// Semantic playback-health transitions.
  ///
  /// The latest transition is replayed. The attached snapshot retains the last
  /// stall reason and both stall/recovery timestamps, so a subscriber arriving
  /// after recovery can still reconstruct the pair. The live buffer is
  /// unbounded because first-frame, stall, recovery, and terminal transitions
  /// must never be evicted by consumer lag.
  public nonisolated var playbackHealthEvents: AsyncStream<PlaybackHealthEvent> {
    playbackHealthEventBridge.subscribeReplayingLatest(policy: .unbounded)
  }

  @discardableResult
  func resetPlaybackHealth(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    guard
      let identity = playbackHealthMutationIdentity(
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: expectedTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      )
    else { return false }
    playbackHealthEventBridge.clearReplay()
    #if os(iOS) || os(macOS)
    directPiPVideoCallbackRegistration?.beginPlaybackGeneration(identity.playbackGeneration)
    #endif
    let renderer = capturePlaybackRendererHealth()
    var monitoringState = playbackHealthMonitoringState
    monitoringState.reset(
      generation: identity.playbackGeneration,
      rendererBaseline: renderer
    )
    return publishPlaybackHealth(
      state: .idle,
      counters: PlaybackHealthCounters(),
      renderer: renderer,
      now: ContinuousClock.now,
      monitoringState: monitoringState,
      identity: identity
    )
  }

  @discardableResult
  func markPlaybackHealthSeek(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    markPlaybackHealthWaiting(
      .seeking,
      ifPlaybackGeneration: expectedPlaybackGeneration,
      nativeHandleGeneration: expectedNativeHandleGeneration,
      timelineRevision: expectedTimelineRevision,
      lifecycleControlEpoch: expectedLifecycleControlEpoch
    )
  }

  @discardableResult
  func markPlaybackHealthAdaptiveSwitch(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    guard state == .playing, playbackHealthMonitoringState.firstPresentedEmitted else {
      return true
    }
    return markPlaybackHealthWaiting(
      .adaptiveSwitch,
      ifPlaybackGeneration: expectedPlaybackGeneration,
      nativeHandleGeneration: expectedNativeHandleGeneration,
      timelineRevision: expectedTimelineRevision,
      lifecycleControlEpoch: expectedLifecycleControlEpoch
    )
  }

  @discardableResult
  private func markPlaybackHealthWaiting(
    _ reason: PlaybackWaitingReason,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    guard
      let identity = playbackHealthMutationIdentity(
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: expectedTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      )
    else { return false }
    let now = ContinuousClock.now
    let renderer = capturePlaybackRendererHealth()
    var monitoringState = playbackHealthMonitoringState
    let counters = makePlaybackHealthCounters(
      renderer: renderer,
      monitoringState: monitoringState
    )
    updatePlaybackHealthProgress(
      counters: counters,
      renderer: renderer,
      now: now,
      monitoringState: &monitoringState
    )
    guard counters.rendererRecoveryFailures == 0 else {
      clearPlaybackHealthWaiting(monitoringState: &monitoringState)
      let didPublish = publishPlaybackHealth(
        state: .failed(.renderer),
        counters: counters,
        renderer: renderer,
        now: now,
        monitoringState: monitoringState,
        identity: identity
      )
      guard didPublish else { return false }
      reconcilePlaybackHealthSamplingTask()
      return true
    }
    monitoringState.pendingWaitingReason = reason
    monitoringState.pendingWaitingBeganAt = now
    monitoringState.pendingPresentedBaseline = counters.presentedVideoFrames
    monitoringState.pendingAudioBaseline = counters.playedAudioBuffers
    // Publish from the exact counters used as the baseline. Sampling again
    // here would let progress that predates the command clear the wait before
    // any subscriber can observe it.
    guard
      publishPlaybackHealth(
        state: .waiting(reason),
        counters: counters,
        renderer: renderer,
        now: now,
        monitoringState: monitoringState,
        identity: identity
      )
    else { return false }
    reconcilePlaybackHealthSamplingTask()
    return true
  }

  /// Grants a fresh progress window when intentional inactivity ends.
  /// Generation clocks remain generation-relative for event timestamps; only
  /// the stall clocks are rearmed.
  func rearmPlaybackHealthAfterEnteringPlaying() {
    let now = ContinuousClock.now
    playbackHealthMonitoringState.lastSourceProgressAt = now
    playbackHealthMonitoringState.lastDecodedProgressAt = now
    playbackHealthMonitoringState.lastAudioDecodedProgressAt = now
    playbackHealthMonitoringState.lastPresentedProgressAt = now
    playbackHealthMonitoringState.lastAudioProgressAt = now
    playbackHealthMonitoringState.activePlaybackBeganAt = now
  }

  func reconcilePlaybackHealthSamplingTask() {
    let needsSampling = state.isActive
      || playbackHealthMonitoringState.pendingWaitingReason != nil
    if !needsSampling {
      playbackHealthSamplingTask?.cancel()
      playbackHealthSamplingTask = nil
      return
    }
    guard playbackHealthSamplingTask == nil else { return }
    playbackHealthSamplingTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: Self.playbackHealthSamplingInterval)
        } catch {
          return
        }
        guard let self else { return }
        samplePlaybackHealth()
        let keepSampling = state.isActive
          || playbackHealthMonitoringState.pendingWaitingReason != nil
        guard keepSampling else {
          playbackHealthSamplingTask = nil
          return
        }
      }
    }
  }

  @discardableResult
  func samplePlaybackHealth(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    // Sampling is timer-driven as well as event-driven. Resolve every optional
    // source identity before touching native counters so a timer sample from A
    // cannot publish after synchronous Observation replaces it with B.
    guard
      let identity = playbackHealthMutationIdentity(
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: expectedTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch
      )
    else { return false }
    if playbackHealthMonitoringState.generation != identity.playbackGeneration {
      // Recast and externally adopted generations can advance without a media
      // reset. Use the full boundary operation so replay and direct-renderer
      // telemetry cannot remain stamped with the predecessor generation.
      guard
        resetPlaybackHealth(
          ifPlaybackGeneration: identity.playbackGeneration,
          nativeHandleGeneration: identity.nativeHandleGeneration,
          timelineRevision: identity.timelineRevision,
          lifecycleControlEpoch: identity.lifecycleControlEpoch
        ) else { return false }
    }

    let now = ContinuousClock.now
    let renderer = capturePlaybackRendererHealth()
    var monitoringState = playbackHealthMonitoringState
    let counters = makePlaybackHealthCounters(
      renderer: renderer,
      monitoringState: monitoringState
    )
    updatePlaybackHealthProgress(
      counters: counters,
      renderer: renderer,
      now: now,
      monitoringState: &monitoringState
    )
    let classified = classifyPlaybackHealth(
      counters: counters,
      renderer: renderer,
      now: now,
      monitoringState: &monitoringState
    )
    return publishPlaybackHealth(
      state: classified,
      counters: counters,
      renderer: renderer,
      now: now,
      monitoringState: monitoringState,
      identity: identity
    )
  }

  private func classifyPlaybackHealth(
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample?,
    now: ContinuousClock.Instant,
    monitoringState: inout PlaybackHealthMonitoringState
  ) -> PlaybackHealthState {
    switch state {
    case .idle, .stopped, .stopping:
      clearPlaybackHealthWaiting(monitoringState: &monitoringState)
      return .idle
    case .paused:
      if counters.rendererRecoveryFailures > 0 {
        clearPlaybackHealthWaiting(monitoringState: &monitoringState)
        return .failed(.renderer)
      }
      if renderer?.status == .recovering {
        return .stalled(.rendererRecovery)
      }
      clearPlaybackHealthWaiting(monitoringState: &monitoringState)
      return .paused
    case .error:
      clearPlaybackHealthWaiting(monitoringState: &monitoringState)
      return .failed(.player)
    case .opening:
      return .waiting(.opening)
    case .buffering:
      return .waiting(.buffering)
    case .playing:
      break
    }

    if counters.rendererRecoveryFailures > 0 {
      return .failed(.renderer)
    }
    if renderer?.status == .recovering {
      return .stalled(.rendererRecovery)
    }

    let hasVideo = activeVideoOutputs > 0
      || videoTracks.contains(where: \.isSelected)
      || counters.decodedVideoFrames > 0
      || counters.presentedVideoFrames > 0
    let hasAudio = audioTracks.contains(where: \.isSelected)
      || counters.decodedAudioFrames > 0
      || counters.playedAudioBuffers > 0

    if let waiting = monitoringState.pendingWaitingReason {
      let progressed = if hasVideo {
        counters.presentedVideoFrames
          > monitoringState.pendingPresentedBaseline
      } else {
        counters.playedAudioBuffers > monitoringState.pendingAudioBaseline
      }
      if progressed {
        clearPlaybackHealthWaiting(monitoringState: &monitoringState)
      } else if
        let began = monitoringState.pendingWaitingBeganAt,
        began.duration(to: now) < Self.playbackHealthStallThreshold {
        return .waiting(waiting)
      }
    }

    if hasVideo {
      if
        counters.presentedVideoFrames == 0,
        monitoringState.activePlaybackBeganAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .waiting(.firstFrame)
      }
      let videoIsProgressing = monitoringState.lastPresentedProgressAt
        .duration(to: now) < Self.playbackHealthStallThreshold
      let audioIsProgressing = monitoringState.lastAudioProgressAt
        .duration(to: now) < Self.playbackHealthStallThreshold
      if
        hasAudio,
        counters.playedAudioBuffers == 0,
        monitoringState.activePlaybackBeganAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .waiting(.firstFrame)
      }
      if videoIsProgressing, !hasAudio || audioIsProgressing {
        return .healthy(contentKind(hasVideo: true, hasAudio: hasAudio))
      }
      if videoIsProgressing, hasAudio {
        if
          monitoringState.lastAudioDecodedProgressAt.duration(to: now)
          < Self.playbackHealthStallThreshold {
          return .stalled(.audioOutput)
        }
        // Video presentation proves the shared source is still progressing;
        // the missing audio progress is therefore downstream of the source.
        return .stalled(.decoder)
      }
      if
        monitoringState.lastDecodedProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.display)
      }
      if
        monitoringState.lastSourceProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.decoder)
      }
      return .stalled(.source)
    }

    if hasAudio {
      if
        counters.playedAudioBuffers == 0,
        monitoringState.activePlaybackBeganAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .waiting(.firstFrame)
      }
      if
        monitoringState.lastAudioProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .healthy(.audioOnly)
      }
      if
        monitoringState.lastAudioDecodedProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.audioOutput)
      }
      if
        monitoringState.lastSourceProgressAt.duration(to: now)
        < Self.playbackHealthStallThreshold {
        return .stalled(.decoder)
      }
      return .stalled(.source)
    }

    if
      monitoringState.activePlaybackBeganAt.duration(to: now)
      < Self.playbackHealthStallThreshold {
      return .waiting(.firstFrame)
    }
    return .stalled(.source)
  }

  private func clearPlaybackHealthWaiting(
    monitoringState: inout PlaybackHealthMonitoringState
  ) {
    monitoringState.pendingWaitingReason = nil
    monitoringState.pendingWaitingBeganAt = nil
    monitoringState.pendingPresentedBaseline = 0
    monitoringState.pendingAudioBaseline = 0
  }

  private func contentKind(hasVideo: Bool, hasAudio: Bool) -> PlaybackContentKind {
    switch (hasVideo, hasAudio) {
    case (true, true): .audiovisual
    case (true, false): .videoOnly
    case (false, true), (false, false): .audioOnly
    }
  }

  private func updatePlaybackHealthProgress(
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample?,
    now: ContinuousClock.Instant,
    monitoringState: inout PlaybackHealthMonitoringState
  ) {
    let previous = monitoringState.previousCounters
    if
      counters.sourceReadBytes > previous.sourceReadBytes
      || counters.demuxReadBytes > previous.demuxReadBytes {
      monitoringState.lastSourceProgressAt = now
    }
    if counters.decodedVideoFrames > previous.decodedVideoFrames {
      monitoringState.lastDecodedProgressAt = renderer?.lastDecodedAt ?? now
    }
    if counters.decodedAudioFrames > previous.decodedAudioFrames {
      monitoringState.lastAudioDecodedProgressAt = now
    }
    if counters.presentedVideoFrames > previous.presentedVideoFrames {
      monitoringState.lastPresentedProgressAt = renderer?.lastPresentedAt ?? now
    }
    if counters.playedAudioBuffers > previous.playedAudioBuffers {
      monitoringState.lastAudioProgressAt = now
    }
    monitoringState.previousCounters = counters
  }

  private func makePlaybackHealthCounters(
    renderer: PlaybackRendererHealthSample?,
    monitoringState: PlaybackHealthMonitoringState
  ) -> PlaybackHealthCounters {
    let stats = statistics
    let direct = renderer.map {
      rendererDelta($0, monitoringState: monitoringState)
    } ?? PlaybackRendererHealthSample()
    return PlaybackHealthCounters(
      sourceReadBytes: stats?.readBytes ?? 0,
      demuxReadBytes: stats?.demuxReadBytes ?? 0,
      decodedVideoFrames: max(stats?.decodedVideo ?? 0, direct.decodedFrames),
      decodedAudioFrames: stats?.decodedAudio ?? 0,
      enqueuedVideoFrames: direct.enqueuedFrames,
      presentedVideoFrames: max(stats?.displayedPictures ?? 0, direct.presentedFrames),
      playedAudioBuffers: stats?.playedAudioBuffers ?? 0,
      droppedVideoFrames: addingWithoutOverflow(stats?.lostPictures ?? 0, direct.droppedFrames),
      lateVideoFrames: stats?.latePictures ?? 0,
      rendererRebuilds: direct.rebuilds,
      rendererFlushes: direct.flushes,
      rendererBackpressureDrops: direct.backpressureDrops,
      rendererFrameReplacements: direct.replacements,
      rendererRecoveryRetries: direct.recoveryRetries,
      rendererRecoveryFailures: direct.recoveryFailures
    )
  }

  private func rendererDelta(
    _ current: PlaybackRendererHealthSample,
    monitoringState: PlaybackHealthMonitoringState
  ) -> PlaybackRendererHealthSample {
    guard let baseline = monitoringState.rendererBaseline else {
      return current
    }
    var delta = current
    delta.decodedFrames = subtractingWithoutUnderflow(current.decodedFrames, baseline.decodedFrames)
    delta.enqueuedFrames = subtractingWithoutUnderflow(current.enqueuedFrames, baseline.enqueuedFrames)
    delta.presentedFrames = subtractingWithoutUnderflow(current.presentedFrames, baseline.presentedFrames)
    delta.droppedFrames = subtractingWithoutUnderflow(current.droppedFrames, baseline.droppedFrames)
    delta.rebuilds = subtractingWithoutUnderflow(current.rebuilds, baseline.rebuilds)
    delta.flushes = subtractingWithoutUnderflow(current.flushes, baseline.flushes)
    delta.backpressureDrops = subtractingWithoutUnderflow(
      current.backpressureDrops,
      baseline.backpressureDrops
    )
    delta.replacements = subtractingWithoutUnderflow(current.replacements, baseline.replacements)
    delta.recoveryRetries = subtractingWithoutUnderflow(
      current.recoveryRetries,
      baseline.recoveryRetries
    )
    delta.recoveryFailures = subtractingWithoutUnderflow(
      current.recoveryFailures,
      baseline.recoveryFailures
    )
    return delta
  }

  @discardableResult
  private func publishPlaybackHealth(
    state newState: PlaybackHealthState,
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample?,
    now: ContinuousClock.Instant,
    monitoringState initialMonitoringState: PlaybackHealthMonitoringState,
    identity: PlaybackHealthMutationIdentity
  ) -> Bool {
    guard playbackHealthPublicationRevision < UInt64.max else {
      assertionFailure("Playback-health publication revision exhausted")
      return false
    }
    playbackHealthPublicationRevision += 1
    let publicationRevision = playbackHealthPublicationRevision
    var monitoringState = initialMonitoringState
    let previousState = playbackHealth.state
    var eventKinds: [PlaybackHealthEventKind] = []

    let completedUnobservedRendererRecovery = counters.rendererFlushes
      > monitoringState.observedRendererFlushes
      && renderer?.status == .rendering
      && counters.rendererRecoveryFailures == 0
    if completedUnobservedRendererRecovery {
      monitoringState.lastStallReason = .rendererRecovery
      monitoringState.lastStalledAt = elapsed(
        to: renderer?.lastEnqueuedAt,
        monitoringState: monitoringState
      ) ?? elapsed(to: now, monitoringState: monitoringState)
      monitoringState.lastRecoveredAt = elapsed(
        to: renderer?.lastPresentedAt,
        monitoringState: monitoringState
      ) ?? elapsed(to: now, monitoringState: monitoringState)
      eventKinds.append(.stalled(.rendererRecovery))
      eventKinds.append(.recovered(from: .rendererRecovery))
    }
    monitoringState.observedRendererFlushes = counters.rendererFlushes

    if
      !monitoringState.firstDecodedEmitted,
      counters.decodedVideoFrames > 0 {
      monitoringState.firstDecodedEmitted = true
      eventKinds.append(.firstDecodedFrame)
    }
    if
      !monitoringState.firstPresentedEmitted,
      counters.presentedVideoFrames > 0 {
      monitoringState.firstPresentedEmitted = true
      eventKinds.append(.firstPresentedFrame)
    }

    if
      case .stalled(let reason) = newState,
      previousState != newState {
      monitoringState.lastStallReason = reason
      monitoringState.activeStallReason = reason
      monitoringState.lastStalledAt = elapsed(to: now, monitoringState: monitoringState)
      eventKinds.append(.stalled(reason))
    } else if
      case .waiting(let reason) = newState,
      previousState != newState {
      eventKinds.append(.waiting(reason))
    }

    if
      let reason = monitoringState.activeStallReason,
      case .healthy = newState {
      monitoringState.lastRecoveredAt = elapsed(to: now, monitoringState: monitoringState)
      monitoringState.activeStallReason = nil
      eventKinds.append(.recovered(from: reason))
    } else if
      !completedUnobservedRendererRecovery,
      previousState == .stalled(.rendererRecovery),
      renderer?.status == .rendering {
      monitoringState.lastRecoveredAt = elapsed(
        to: renderer?.lastPresentedAt,
        monitoringState: monitoringState
      ) ?? elapsed(to: now, monitoringState: monitoringState)
      monitoringState.activeStallReason = nil
      eventKinds.append(.recovered(from: .rendererRecovery))
    }
    if
      case .failed(let failure) = newState,
      previousState != newState {
      eventKinds.append(.terminalFailure(failure))
    }

    let snapshot = PlaybackHealthSnapshot(
      generation: PlaybackGeneration(identity.playbackGeneration),
      state: newState,
      revision: playbackHealth.revision &+ 1,
      lastDecodedAt: elapsed(to: renderer?.lastDecodedAt, monitoringState: monitoringState)
        ?? (counters.decodedVideoFrames > 0
          ? elapsed(to: monitoringState.lastDecodedProgressAt, monitoringState: monitoringState)
          : nil),
      lastEnqueuedAt: elapsed(
        to: renderer?.lastEnqueuedAt,
        monitoringState: monitoringState
      ),
      lastPresentedAt: elapsed(
        to: renderer?.lastPresentedAt,
        monitoringState: monitoringState
      ) ?? (counters.presentedVideoFrames > 0
        ? elapsed(to: monitoringState.lastPresentedProgressAt, monitoringState: monitoringState)
        : nil),
      rendererStatus: renderer?.status ?? .unavailable,
      voutGeneration: renderer?.voutGeneration,
      counters: counters,
      lastStallReason: monitoringState.lastStallReason,
      lastStalledAt: monitoringState.lastStalledAt,
      lastRecoveredAt: monitoringState.lastRecoveredAt
    )
    var didCommit = false
    let mutationIdentityRemainedCurrent = performObservableMutation(
      keyPath: \.playbackHealth,
      ifPlaybackGeneration: identity.playbackGeneration,
      nativeHandleGeneration: identity.nativeHandleGeneration,
      timelineRevision: identity.timelineRevision,
      lifecycleControlEpoch: identity.lifecycleControlEpoch,
      mutation: {
        guard playbackHealthPublicationRevision == publicationRevision else { return }
        playbackHealthMonitoringState = monitoringState
        storePlaybackHealthWithoutNestedObservation(snapshot)
        didCommit = true
      }
    )
    guard
      mutationIdentityRemainedCurrent,
      didCommit,
      playbackHealthPublicationRevision == publicationRevision
    else { return false }
    playbackHealthSnapshotBridge.broadcast(snapshot)
    for kind in eventKinds {
      playbackHealthEventBridge.broadcast(PlaybackHealthEvent(kind: kind, snapshot: snapshot))
    }
    return true
  }

  /// Resolves timer/test convenience calls onto the same exact identity used
  /// by sourced native events. Optional expectations must never mean
  /// "generation agnostic": Observation can synchronously run a newer load,
  /// seek, stop, or handle replacement before the mutation body executes.
  private func playbackHealthMutationIdentity(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64?,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64?,
    timelineRevision expectedTimelineRevision: UInt64?,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64?
  ) -> PlaybackHealthMutationIdentity? {
    let identity = PlaybackHealthMutationIdentity(
      playbackGeneration: expectedPlaybackGeneration ?? sessionGeneration,
      nativeHandleGeneration: expectedNativeHandleGeneration
        ?? eventBridge.currentNativeHandleGeneration,
      timelineRevision: expectedTimelineRevision ?? acceptedTimelineRevision,
      lifecycleControlEpoch: expectedLifecycleControlEpoch
        ?? eventBridge.currentLifecycleControlEpoch
    )
    guard
      identity.timelineRevision == acceptedTimelineRevision,
      identity.lifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch,
      ownsPlaybackMutation(
        identity.playbackGeneration,
        nativeHandleGeneration: identity.nativeHandleGeneration
      )
    else { return nil }
    return identity
  }

  private func elapsed(
    to instant: ContinuousClock.Instant?,
    monitoringState: PlaybackHealthMonitoringState
  ) -> Duration? {
    guard let instant, instant >= monitoringState.startedAt else { return nil }
    return monitoringState.startedAt.duration(to: instant)
  }

  private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    return result.overflow ? .max : result.partialValue
  }

  private func subtractingWithoutUnderflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
    lhs >= rhs ? lhs - rhs : 0
  }

  /// `Track` identity intentionally compares only IDs. Health needs to notice
  /// adaptive metadata changes that retain an ES ID, so compare the complete
  /// video description in a stable ID order instead.
  static func playbackHealthVideoTracksDiffer(_ lhs: [Track], _ rhs: [Track]) -> Bool {
    guard lhs.count == rhs.count else { return true }
    let left = lhs.sorted { $0.id < $1.id }
    let right = rhs.sorted { $0.id < $1.id }
    return zip(left, right).contains { left, right in
      left.id != right.id
        || left.type != right.type
        || left.name != right.name
        || left.codec != right.codec
        || left.language != right.language
        || left.trackDescription != right.trackDescription
        || left.isSelected != right.isSelected
        || left.bitrate != right.bitrate
        || left.width != right.width
        || left.height != right.height
        || left.frameRate != right.frameRate
        || left.frameRateRatio != right.frameRateRatio
    }
  }

  private func capturePlaybackRendererHealth() -> PlaybackRendererHealthSample? {
    #if os(iOS) || os(macOS)
    guard let telemetry = directPiPVideoCallbackRegistration?.telemetrySnapshot else {
      return nil
    }
    guard telemetry.playbackGeneration == sessionGeneration else { return nil }
    let rendererStatus: PlaybackRendererStatus = switch telemetry.status {
    case .idle: .idle
    case .rendering: .rendering
    case .backpressured: .backpressured
    case .recovering: .recovering
    case .failed: .failed
    }
    return PlaybackRendererHealthSample(
      playbackGeneration: telemetry.playbackGeneration,
      voutGeneration: telemetry.voutGeneration,
      decodedFrames: telemetry.decodedFrameCount,
      enqueuedFrames: telemetry.enqueuedFrameCount,
      presentedFrames: telemetry.presentedFrameCount,
      droppedFrames: telemetry.droppedFrameCount,
      rebuilds: telemetry.voutTransitionCount,
      flushes: telemetry.flushCount,
      backpressureDrops: telemetry.backpressureDropCount,
      replacements: telemetry.replacementCount,
      recoveryRetries: telemetry.flushRecoveryRetryCount,
      recoveryFailures: telemetry.flushRecoveryFailureCount,
      lastDecodedAt: telemetry.lastDecodedAt,
      lastEnqueuedAt: telemetry.lastEnqueuedAt,
      lastPresentedAt: telemetry.lastPresentedAt,
      status: rendererStatus
    )
    #else
    return nil
    #endif
  }

  #if DEBUG
  @discardableResult
  func _applyPlaybackHealthSampleForTesting(
    counters: PlaybackHealthCounters,
    renderer: PlaybackRendererHealthSample? = nil,
    now: ContinuousClock.Instant = .now
  ) -> Bool {
    guard
      let identity = playbackHealthMutationIdentity(
        ifPlaybackGeneration: nil,
        nativeHandleGeneration: nil,
        timelineRevision: nil,
        lifecycleControlEpoch: nil
      )
    else { return false }
    var monitoringState = playbackHealthMonitoringState
    updatePlaybackHealthProgress(
      counters: counters,
      renderer: renderer,
      now: now,
      monitoringState: &monitoringState
    )
    let classified = classifyPlaybackHealth(
      counters: counters,
      renderer: renderer,
      now: now,
      monitoringState: &monitoringState
    )
    return publishPlaybackHealth(
      state: classified,
      counters: counters,
      renderer: renderer,
      now: now,
      monitoringState: monitoringState,
      identity: identity
    )
  }
  #endif
}
