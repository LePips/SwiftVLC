#if os(iOS) || os(macOS)
import AVKit

extension PiPController {
  func handleSkip(
    by skipInterval: CMTime,
    completion completionHandler: @escaping @Sendable () -> Void
  ) {
    // Cancel any pending transient pause. Skip actions should not drive
    // libVLC through a pause → seek → resume cycle.
    cancelDeferredPause()

    // Reject an interval that cannot be expressed in libVLC's millisecond unit
    // here rather than inside the driver, so no driver — live or injected —
    // is ever handed one. AVKit has no contract preventing it from passing an
    // indefinite or infinite CMTime.
    guard Self.skipOffsetMilliseconds(skipInterval) != nil else {
      completionHandler()
      return
    }

    let request = playbackDriver.skip(skipInterval)
    let tracksPendingSkip = request.initialOutcome == .pending
    if tracksPendingSkip {
      pendingSkipCount += 1
    }
    Task { @MainActor [weak self] in
      let outcome = await request.outcome
      guard let self else {
        completionHandler()
        return
      }
      if tracksPendingSkip {
        pendingSkipCount = Swift.max(0, pendingSkipCount - 1)
      }

      // A refused, timed-out, or superseded skip leaves the timebase alone.
      // Publishing the requested estimate as authoritative before native
      // landing evidence would put AVKit ahead of playback.
      if Self.skipMovedTimeline(outcome) {
        lastSkipTimestamp = CFAbsoluteTimeGetCurrent()

        // Apple docs: "the control timebase should reflect the current
        // playback time and rate when the closure is invoked". Read it back
        // only after the matching native clock event has been applied.
        if let tb = controlTimebase {
          let previousSeconds = CMTimebaseGetTime(tb).seconds
          let correctedSeconds = Double(player.currentTime.milliseconds) / 1000.0
          CMTimebaseSetTime(tb, time: CMTime(
            seconds: correctedSeconds,
            preferredTimescale: 1000
          ))
          recordTimebaseCorrection(
            reason: .skipLanding,
            previousTimebaseSeconds: previousSeconds,
            correctedTimebaseSeconds: correctedSeconds,
            mediaTimeSeconds: correctedSeconds
          )
          setTimebaseRate(
            player.isActive ? Float64(player.rate) : 0.0,
            reason: .skipLanding,
            mediaTimeSeconds: correctedSeconds
          )
        }
      }

      completionHandler()
    }
  }

  /// Starts Picture-in-Picture if possible and media is loaded.
  ///
  /// This compatibility action intentionally ignores the immediate request
  /// result. Use ``requestStart()`` when a refused request should trigger an
  /// application fallback.
  public func start() {
    _ = requestStart()
  }

  /// Requests Picture-in-Picture and reports whether the request was issued.
  ///
  /// The returned ``PiPStartResult`` describes only whether the request was
  /// issued. Asynchronous AVKit failure after an accepted start stays where it
  /// belongs, on ``pipEventEnvelopes`` (or the compatibility ``pipEvents``
  /// stream when generation attribution is not needed).
  public func requestStart() -> PiPStartResult {
    guard player.currentMedia != nil else { return .noMedia }
    #if os(iOS)
    if let nativeBackend {
      // Do not take audio focus for a request the native controller cannot
      // perform. The backend is still asked either way, both for its one-time
      // vout diagnostic and because its answer is the authoritative one —
      // substituting `.notPossible` here would report the controller's guess
      // over the backend's own finding, and would hide a `.noMedia` the
      // backend can see and this layer cannot.
      if nativeBackend.isPossible {
        activateAudioSessionIfNeeded()
      }
      return noteAcceptedPiPStartRequest(nativeBackend.start())
    }
    #endif
    #if os(macOS)
    if let nativeBackend {
      return noteAcceptedPiPStartRequest(nativeBackend.start())
    }
    #endif
    guard callbackRegistration?.isBound == true else { return .backendUnavailable }
    guard let pipController else { return .backendUnavailable }
    guard isPossible else { return .notPossible }
    activateAudioSessionIfNeeded()
    pipController.startPictureInPicture()
    return noteAcceptedPiPStartRequest(.accepted)
  }

  /// Stops Picture-in-Picture.
  ///
  /// A stop initiated through this method remains `.unknown` on the
  /// version-1-compatible ``pipEvents`` stream. The attributed
  /// ``pipEventEnvelopes`` stream reports
  /// ``PiPStopCause/programmatic`` through ``PiPEventEnvelope/stopCause``.
  public func stop() {
    // Recorded unconditionally: between AVKit beginning the start
    // animation and the didStart callback, `isActive` is still false,
    // and a stop issued in that window would otherwise be reported as
    // the user's close tap. If no lifecycle was actually in flight, the next
    // accepted start (or an automatic willStart/didStart) clears it.
    notePendingStopReason(.programmatic)
    #if os(iOS)
    if let nativeBackend {
      nativeBackend.stop()
      return
    }
    #endif
    #if os(macOS)
    if let nativeBackend {
      nativeBackend.stop()
      return
    }
    #endif
    pipController?.stopPictureInPicture()
  }

  /// Toggles Picture-in-Picture on/off.
  ///
  /// This compatibility action intentionally ignores the immediate result of
  /// the start branch. Use ``toggleReportingStartResult()`` when a refused
  /// start should trigger an application fallback.
  public func toggle() {
    _ = toggleReportingStartResult()
  }

  /// Toggles Picture-in-Picture and reports the immediate start result.
  ///
  /// - Returns: The ``PiPStartResult`` when this call took the start branch,
  ///   or `nil` when it stopped an active session.
  public func toggleReportingStartResult() -> PiPStartResult? {
    if isActive {
      stop()
      return nil
    }
    return requestStart()
  }
}
#endif
