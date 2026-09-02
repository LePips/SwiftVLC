import CLibVLC

extension Player {
  // MARK: - Validation

  /// Zero is accepted only by direct DEBUG seams. Every production callback
  /// and wrapper dispatch carries a positive sequence from the shared emission
  /// authority.
  func canCommitNativeTimelineEmission(_ sequence: UInt64) -> Bool {
    sequence == 0 || sequence >= acceptedNativeTimelineEmissionSequence
  }

  func commitNativeTimelineEmission(_ sequence: UInt64) {
    guard sequence > 0 else { return }
    acceptedNativeTimelineEmissionSequence = max(
      acceptedNativeTimelineEmissionSequence,
      sequence
    )
  }

  func checkedSeekMilliseconds(for time: Duration, parameter: String) throws(VLCError) -> Int64 {
    guard nativeHandleRepresentsCurrentMedia else {
      throw .invalidState("current media is awaiting its native playback handle")
    }
    guard isSeekable else {
      throw .invalidState("current media is not seekable")
    }

    let milliseconds = try time.checkedNonnegativeLibVLCTimeMilliseconds(
      parameter: parameter
    )
    if let duration {
      let durationMs = try duration.checkedNonnegativeMilliseconds(parameter: "duration")
      guard milliseconds <= durationMs else {
        throw .invalidInput("\(parameter) must not exceed current media duration")
      }
    }
    return milliseconds
  }

  func checkedMilliseconds(for position: PlaybackPosition, durationMs: Int64) -> Int64 {
    guard position.rawValue > 0 else { return 0 }
    guard position.rawValue < 1 else { return durationMs }

    let scaled = (Double(durationMs) * position.rawValue).rounded()
    guard scaled.isFinite, scaled > 0 else { return 0 }
    guard scaled < Double(Int64.max) else { return durationMs }
    return Swift.min(Int64(scaled), durationMs)
  }

  /// Publishes the fractional position derived from a just-issued seek
  /// target. libVLC emits no `positionChanged` while paused, so without
  /// this the ``position`` shadow would stay stale until playback resumes.
  @discardableResult
  func publishPosition(
    forTargetMilliseconds targetMs: Int64,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Double? {
    guard
      let duration,
      let durationMs = try? duration.checkedNonnegativeMilliseconds(parameter: "duration"),
      durationMs > 0
    else { return nil }
    let fraction = Swift.min(1.0, Swift.max(0.0, Double(targetMs) / Double(durationMs)))
    guard
      performObservableMutation(
        keyPath: \.position,
        ifPlaybackGeneration: expectedPlaybackGeneration,
        nativeHandleGeneration: expectedNativeHandleGeneration,
        timelineRevision: expectedTimelineRevision,
        lifecycleControlEpoch: expectedLifecycleControlEpoch,
        mutation: {
          storePositionWithoutNestedObservation(fraction)
        }
      )
    else { return nil }
    return fraction
  }

  /// Keeps terminal outcomes aligned with synchronous timeline mutations for
  /// which libVLC does not guarantee a corresponding event.
  @discardableResult
  func recordAuthoritativeTimeline(
    position: Double?,
    emissionSequence: UInt64? = nil,
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64? = nil,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64? = nil,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil
  ) -> Bool {
    if let expectedTimelineRevision {
      guard expectedTimelineRevision == acceptedTimelineRevision else { return false }
    }
    if let expectedLifecycleControlEpoch {
      guard expectedLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
        return false
      }
    }
    if let expectedPlaybackGeneration {
      guard
        ownsPlaybackMutation(
          expectedPlaybackGeneration,
          nativeHandleGeneration: expectedNativeHandleGeneration
            ?? eventBridge.currentNativeHandleGeneration
        )
      else { return false }
    } else if let expectedNativeHandleGeneration {
      guard expectedNativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
        return false
      }
    }
    let playbackGeneration = expectedPlaybackGeneration ?? sessionGeneration
    let timelineRevision = expectedTimelineRevision ?? acceptedTimelineRevision
    eventBridge.updateAuthoritativeTimeline(
      time: currentTime,
      position: position,
      playbackGeneration: playbackGeneration,
      timelineRevision: timelineRevision,
      timelineEmissionSequence: emissionSequence
    )
    return true
  }
}
