#if os(iOS) || os(macOS)

import CoreMedia

extension PiPController {
  struct PlaybackStateUpdate: Equatable {
    var invalidatesPlaybackState = false
    var requiresLinearPlayback: Bool?
  }

  /// Event-side snapshot for AVKit's playback UI on either PiP backend.
  ///
  /// `Player` and `PiPController` consume independent streams from the same
  /// native event. Their relative ordering is intentionally unspecified, so
  /// payload-bearing events must update this snapshot from their payload rather
  /// than from `Player`'s potentially stale observable mirror.
  struct PlaybackStateObservationState {
    private(set) var durationMilliseconds: Int64?
    private(set) var isSeekable: Bool
    /// Media generation this observer has adopted from event provenance.
    /// Unlike the capability generation below, this is available even when a
    /// native handle was populated before its event manager was attached and
    /// therefore never emits `MediaChanged`.
    private(set) var playbackGeneration: PlaybackGeneration?
    /// Generation that already received the conservative media-boundary reset.
    /// A different observer lane can adopt and reset a successor before its
    /// queued `MediaChanged` envelope runs; that later envelope is an echo, not
    /// a second boundary that may erase capability already learned for it.
    private var resetPlaybackGeneration: PlaybackGeneration?
    /// The capability generation current when this media was adopted.
    private var generationAtReset: UInt64?
    /// Whether `Player`'s capability values are known to describe *this*
    /// media. False between seeing a media change and seeing evidence that
    /// `Player` has processed the same change.
    private var trustsPolledCapability = true
    /// Set once a payload has reported the value for this media. A payload is
    /// authoritative for its generation; the polled mirror may only fill in
    /// what no payload has covered, never contradict one.
    private var hasDurationPayload = false
    private var hasSeekablePayload = false

    init(
      duration: Duration?,
      isSeekable: Bool,
      playbackGeneration: PlaybackGeneration? = nil
    ) {
      durationMilliseconds = duration?.milliseconds
      self.isSeekable = isSeekable
      self.playbackGeneration = playbackGeneration
    }

    /// Adopts a successor session before consuming its first event.
    ///
    /// Active drawable playback creates a new native player, installs its
    /// media, and only then attaches the event bridge. That ordering is needed
    /// for transactional replacement but means the successor can legitimately
    /// have no native `MediaChanged` callback. Its first `.opening`,
    /// `.playing`, or clock envelope still carries the new playback generation,
    /// so use that provenance as the authoritative reset boundary.
    mutating func adoptPlaybackGeneration(
      _ generation: PlaybackGeneration,
      capability: PlayerCapabilitySnapshot
    ) -> PlaybackStateUpdate? {
      if let playbackGeneration {
        guard generation > playbackGeneration else { return nil }
      }
      playbackGeneration = generation
      return resetForMediaChange(capability: capability)
    }

    mutating func consume(
      _ event: PlayerEvent,
      capability: PlayerCapabilitySnapshot
    ) -> PlaybackStateUpdate {
      switch event {
      case .mediaChanged:
        if
          let playbackGeneration,
          resetPlaybackGeneration == playbackGeneration {
          return PlaybackStateUpdate()
        }
        return resetForMediaChange(capability: capability)

      case .lengthChanged(let duration):
        hasDurationPayload = true
        durationMilliseconds = duration.milliseconds
        return PlaybackStateUpdate(invalidatesPlaybackState: true)

      case .seekableChanged(let seekable):
        hasSeekablePayload = true
        isSeekable = seekable
        return PlaybackStateUpdate(
          invalidatesPlaybackState: true,
          requiresLinearPlayback: !seekable
        )

      case .stateChanged:
        // State transitions are the only payload-free fallback that can
        // affect availability. Invalidate so AVKit re-queries the retained
        // native media snapshot instead of copying a potentially stale mirror.
        //
        // They are also where convergence happens: `Player` polls duration and
        // seekability on every transition precisely because libVLC does not
        // reliably emit the change events. Reacting only to those events left
        // finite seekable VOD pinned to the conservative media-changed reset —
        // linear playback with no skip controls.
        return reconcile(with: capability, invalidates: true)

      case .timeChanged:
        // `Player` polls from its own `.timeChanged` handler too, and does so
        // exactly while duration or seekability are still unknown. Steady
        // playback can run without another state transition, so convergence
        // has to be reachable from a clock tick as well.
        //
        // `invalidates: false` because this fires at the clock rate: it must
        // publish only when a value genuinely changed.
        return reconcile(with: capability, invalidates: false)

      default:
        return PlaybackStateUpdate()
      }
    }

    /// A rate resolution carries no capability payload, but it is still a
    /// reliable wake-up point for adopting Player's polled duration and
    /// seekability once their generation is current.
    mutating func consumeEffectivePlaybackRateResolution(
      capability: PlayerCapabilitySnapshot
    ) -> PlaybackStateUpdate {
      reconcile(with: capability, invalidates: false)
    }

    private mutating func resetForMediaChange(
      capability: PlayerCapabilitySnapshot
    ) -> PlaybackStateUpdate {
      resetPlaybackGeneration = playbackGeneration
      // The new input's duration/seekability have not been reported yet.
      // Reset conservatively even if Player's event consumer still exposes
      // the previous media's values.
      durationMilliseconds = nil
      isSeekable = false
      hasDurationPayload = false
      hasSeekablePayload = false
      generationAtReset = capability.generation
      // Exact playback identity is the strongest proof: the successor may
      // already have finite/seekable capability by the time this observer
      // adopts its first envelope, so requiring reset values would strand it
      // in linear playback until an unrelated later media change. Snapshots
      // without identity exist only in narrow state-machine tests; preserve
      // the older conservative reset proof for those inputs.
      if
        let capabilityPlaybackGeneration = capability.playbackGeneration,
        let playbackGeneration {
        trustsPolledCapability = capabilityPlaybackGeneration == playbackGeneration
      } else {
        trustsPolledCapability = capability.isReset
      }
      var update = PlaybackStateUpdate(
        invalidatesPlaybackState: true,
        requiresLinearPlayback: true
      )
      if trustsPolledCapability {
        // Fold an exact successor snapshot into the same published boundary.
        // A loaded-but-paused input may emit no later state or clock event, so
        // deferring this reconciliation could otherwise leave known seekable
        // VOD linear indefinitely. The final value replaces the conservative
        // reset without exposing an intermediate AVKit state.
        let convergence = reconcile(with: capability, invalidates: true)
        update.invalidatesPlaybackState =
          update.invalidatesPlaybackState || convergence.invalidatesPlaybackState
        if let requiresLinearPlayback = convergence.requiresLinearPlayback {
          update.requiresLinearPlayback = requiresLinearPlayback
        }
      }
      return update
    }

    /// Folds `Player`'s polled capability into this snapshot, when it can be
    /// shown to describe the same media.
    private mutating func reconcile(
      with capability: PlayerCapabilitySnapshot,
      invalidates: Bool
    )
      -> PlaybackStateUpdate {
      var update = PlaybackStateUpdate(invalidatesPlaybackState: invalidates)

      if !trustsPolledCapability {
        if
          let capabilityPlaybackGeneration = capability.playbackGeneration,
          let playbackGeneration {
          // A tagged snapshot is trusted only for the exact adopted session.
          // A newer snapshot can legitimately arrive before this observer's
          // corresponding envelope; adopting it here would leak future-media
          // capability backward into the current AVKit policy.
          guard capabilityPlaybackGeneration == playbackGeneration else {
            return update
          }
        } else {
          // Compatibility path for identity-free state-machine inputs: the
          // capability generation moving past the reset proves publication.
          guard capability.generation != generationAtReset else { return update }
        }
        trustsPolledCapability = true
      }

      if
        !hasDurationPayload,
        let milliseconds = capability.durationMilliseconds,
        milliseconds != durationMilliseconds {
        durationMilliseconds = milliseconds
        update.invalidatesPlaybackState = true
      }

      if !hasSeekablePayload, capability.isSeekable != isSeekable {
        isSeekable = capability.isSeekable
        update.requiresLinearPlayback = !capability.isSeekable
        update.invalidatesPlaybackState = true
      }

      return update
    }
  }

  @MainActor struct PlaybackStateEventSuppression: Equatable {
    private(set) var suppressedLengthEventCount = 0
    private(set) var suppressedSeekableEventCount = 0

    mutating func shouldObserve(
      _ event: PlayerEvent,
      suppressingRawCapabilityEvents: Bool
    ) -> Bool {
      guard
        !PiPController.shouldObservePlaybackStateEvent(
          event,
          suppressingRawCapabilityEvents: suppressingRawCapabilityEvents
        )
      else { return true }

      switch event {
      case .lengthChanged:
        suppressedLengthEventCount += 1
      case .seekableChanged:
        suppressedSeekableEventCount += 1
      default:
        break
      }
      return false
    }
  }

  /// Qualification fault injection must drop raw capability callbacks from
  /// this observer as well as from Player's observable mirror. The two own
  /// independent subscriptions to the same event bridge; suppressing only the
  /// Player consumer would let this controller converge from the callback and
  /// produce a false-positive polling result.
  static func shouldObservePlaybackStateEvent(
    _ event: PlayerEvent,
    suppressingRawCapabilityEvents: Bool
  ) -> Bool {
    guard suppressingRawCapabilityEvents else { return true }
    switch event {
    case .lengthChanged, .seekableChanged:
      return false
    default:
      return true
    }
  }

  /// Whether a sourced event can still describe the player the PiP controller
  /// currently owns.
  ///
  /// The event bridge advances playback ownership synchronously at native
  /// callback entry, before either its Player or PiP main-actor consumer runs.
  /// Comparing with that authority (and the generation this observer has
  /// already adopted) accepts a successor's whole ordered event burst even if
  /// `Player.generation` still lags, while rejecting every superseded session.
  /// Native handle identity is always exact: callbacks from a retired handle
  /// cannot describe the installed player even when they carry a current media
  /// generation.
  nonisolated static func shouldObservePlaybackStateEnvelope(
    _ envelope: PlayerEventEnvelope,
    nativeGeneration: NativePlayerGeneration,
    authoritativePlaybackGeneration: PlaybackGeneration
  ) -> Bool {
    shouldObservePlaybackStateProvenance(
      nativeGeneration: envelope.nativeGeneration,
      playbackGeneration: envelope.playbackGeneration,
      currentNativeGeneration: nativeGeneration,
      authoritativePlaybackGeneration: authoritativePlaybackGeneration
    )
  }

  /// Applies the identical provenance rule to the dedicated rate stream.
  nonisolated static func shouldObserveEffectivePlaybackRateResolution(
    _ resolution: EffectivePlaybackRateResolution,
    nativeGeneration: NativePlayerGeneration,
    authoritativePlaybackGeneration: PlaybackGeneration
  ) -> Bool {
    shouldObservePlaybackStateProvenance(
      nativeGeneration: resolution.nativeGeneration,
      playbackGeneration: resolution.playbackGeneration,
      currentNativeGeneration: nativeGeneration,
      authoritativePlaybackGeneration: authoritativePlaybackGeneration
    )
  }

  private nonisolated static func shouldObservePlaybackStateProvenance(
    nativeGeneration: NativePlayerGeneration,
    playbackGeneration: PlaybackGeneration,
    currentNativeGeneration: NativePlayerGeneration,
    authoritativePlaybackGeneration: PlaybackGeneration
  ) -> Bool {
    guard nativeGeneration == currentNativeGeneration else { return false }
    return playbackGeneration == authoritativePlaybackGeneration
  }

  static func applyPlaybackStateUpdate(
    _ update: PlaybackStateUpdate,
    setRequiresLinearPlayback: (Bool) -> Void,
    invalidatePlaybackState: () -> Void
  ) {
    if let requiresLinearPlayback = update.requiresLinearPlayback {
      setRequiresLinearPlayback(requiresLinearPlayback)
    }
    if update.invalidatesPlaybackState {
      invalidatePlaybackState()
    }
  }

  /// Converts AVKit's interval without using a trapping floating-point-to-
  /// integer conversion for invalid, infinite, or out-of-range `CMTime`s.
  static func skipOffsetMilliseconds(_ interval: CMTime) -> Int64? {
    guard interval.isNumeric else { return nil }
    let milliseconds = CMTimeConvertScale(
      interval,
      timescale: 1000,
      method: .roundTowardZero
    )
    guard
      milliseconds.isNumeric,
      LibVLCTimeMilliseconds.contains(milliseconds.value)
    else { return nil }
    return milliseconds.value
  }

  /// Saturating addition followed by clamping to the playable timeline.
  /// This keeps adversarial or malformed skip intervals from overflowing at
  /// either end while preserving the ordinary truncation-to-milliseconds
  /// behavior.
  static func clampedSkipTargetMilliseconds(
    current: Int64,
    offset: Int64,
    duration: Int64?
  ) -> Int64 {
    let upperBound = max(duration ?? .max, 0)
    let current = max(0, min(current, upperBound))
    let sum = current.addingReportingOverflow(offset)
    if sum.overflow {
      return offset >= 0 ? upperBound : 0
    }
    return max(0, min(sum.partialValue, upperBound))
  }
}

#endif
