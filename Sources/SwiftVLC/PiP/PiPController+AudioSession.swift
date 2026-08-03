#if os(iOS) || os(macOS)
import AVFoundation
#if os(iOS)
import UIKit
#endif

// MARK: - Audio-session policy

extension PiPController {
  /// Live operation for deferred managed-session activation. Kept separate
  /// from the one-shot state machine so native-route tests can inject a
  /// deterministic failure/success sequence.
  static func liveAudioSessionActivation() throws {
    #if os(iOS)
    let session = AVAudioSession.sharedInstance()
    // Category setup can fail transiently too. Repeat it inside the same
    // retryable operation so a swallowed init-time failure cannot leave an
    // otherwise successful activation in the wrong audio category.
    try session.setCategory(.playback, mode: .moviePlayback)
    try session.setActive(true)
    #endif
  }

  /// Sets the shared audio session's category for movie playback when
  /// ``managesAudioSession`` is enabled. Activation is intentionally
  /// **not** done here: `setActive(true)` steals audio focus from other
  /// apps, and controllers are constructed at view-lifecycle times the
  /// app does not control. See ``activateAudioSessionIfNeeded()``.
  ///
  /// No-op on macOS, which has no `AVAudioSession`.
  func configureAudioSession() {
    #if os(iOS)
    guard managesAudioSession else { return }
    let session = AVAudioSession.sharedInstance()
    try? session.setCategory(.playback, mode: .moviePlayback)
    #endif
  }

  /// Issues the deferred `AVAudioSession.setActive(true)` the first
  /// time PiP is started or playback becomes actively requested.
  /// No-op when ``managesAudioSession`` is `false`, after the first
  /// activation, and on platforms without `AVAudioSession`.
  func activateAudioSessionIfNeeded() {
    #if os(iOS)
    activateAudioSessionIfNeeded(using: audioSessionActivation)
    #endif
  }

  /// Runs the platform activation operation at most once after it succeeds.
  ///
  /// A failed operation deliberately leaves ``hasActivatedAudioSession`` false
  /// so a later playback/PiP signal can retry. The iOS production path above
  /// uses this same state machine; accepting the operation as an argument keeps
  /// the failure and retry behavior deterministic in platform-neutral tests.
  func activateAudioSessionIfNeeded(using activate: () throws -> Void) {
    guard managesAudioSession, !hasActivatedAudioSession else { return }
    do {
      try activate()
      hasActivatedAudioSession = true
    } catch {
      // Activation can fail transiently (for example during an audio-session
      // interruption). Leave the state unset so the next signal retries.
    }
  }

  // MARK: - Session disruption

  /// A disruption to the shared audio session that the managed path reacts to.
  ///
  /// Modelled as a value rather than read from `Notification` at the decision
  /// point so the policy below can be exercised without an `AVAudioSession` —
  /// there is none on macOS, and CI cannot produce a real interruption on any
  /// platform.
  enum AudioSessionDisruption: Equatable, Sendable {
    /// The system took audio focus away. It has already deactivated our
    /// session; nothing needs deactivating in response.
    case interruptionBegan
    /// Focus was returned. `shouldResume` mirrors AVKit's
    /// `.shouldResume` option, which is the system's opinion — not consent.
    case interruptionEnded(shouldResume: Bool)
    /// The route the audio was playing out of went away, e.g. headphones
    /// unplugged or Bluetooth disconnected.
    case routeLost
    /// The media server restarted. Every session object is invalid and the
    /// category has to be set again from scratch.
    case mediaServicesReset
    /// The media server became unavailable. Playback is suspended while
    /// preserving intent until the subsequent reset notification.
    case mediaServicesLost
    /// UIKit completed backgrounding while no PiP window was active.
    /// `isPictureInPictureActive` is captured after a bounded grace period so
    /// an automatic PiP start is not mistaken for hidden background playback.
    case enteredBackground(isPictureInPictureActive: Bool)
    /// Protected data became unavailable, which is UIKit's device-lock signal.
    case deviceLocked(isPictureInPictureActive: Bool)
    /// UIKit is returning to the foreground.
    case enteringForeground
  }

  /// What a disruption implies for the managed session.
  struct AudioSessionReaction: Equatable, Sendable {
    /// Clear ``hasActivatedAudioSession`` so a later signal can reactivate.
    /// Without this the latch is permanent and audio never returns.
    var clearsActivationLatch = false
    /// Reconfigure the category before reactivating.
    var reconfiguresCategory = false
    /// Reactivate the session now.
    var reactivates = false
    /// Pause playback, because continuing would be wrong rather than merely
    /// silent.
    var pausesPlayback = false
    /// Issue a lifecycle pause without changing the user's active playback
    /// intent, so only SwiftVLC's own pause can be recovered on foreground.
    var preservesPlaybackIntentWhenPausing = false
    /// Resume a pause previously issued by the managed lifecycle path.
    var resumesManagedSuspendedPlayback = false
    /// Record app/device lifecycle as one cause of the managed pause.
    var marksLifecycleSuspension = false
    /// Record lost media services as another independent pause cause.
    var marksMediaServicesSuspension = false
    /// Give up audio focus after hidden playback has been suspended.
    var deactivatesSession = false
    /// Forget a previous lifecycle suspension without resuming it, e.g. after
    /// the user explicitly paused while the app was backgrounded.
    var clearsLifecycleSuspension = false
    /// Clear the media-services cause after a reset.
    var clearsMediaServicesSuspension = false
  }

  /// Decides the response to a session disruption.
  ///
  /// Pure, and separated from the notification plumbing because every input
  /// here originates in an `AVAudioSession` notification that no test on this
  /// host can raise. The rules follow Apple's documented handling rather than
  /// being invented:
  ///
  /// - An interruption deactivates the session on our behalf, so the only
  ///   thing to undo is the latch. Reactivating here would fight whatever took
  ///   focus.
  /// - Resuming afterwards needs *both* the system's `.shouldResume` hint and
  ///   the user's playback intent. The hint alone is not enough: someone who
  ///   paused before the call must not find playback running after it.
  /// - Losing the output route pauses. This is the headphone-unplug rule —
  ///   continuing would move the audio to the speaker, which is the one
  ///   outcome the user certainly did not ask for.
  /// - A media-services reset invalidates everything, so the category must be
  ///   set again before activation, and only if playback was wanted.
  ///
  /// With ``managesAudioSession`` disabled every reaction is empty: a library
  /// that was told not to touch the session must not touch it on the way out
  /// either.
  nonisolated static func reaction(
    to disruption: AudioSessionDisruption,
    isPlaybackIntentActive: Bool,
    managesAudioSession: Bool,
    wasPlaybackSuspendedForLifecycle: Bool = false,
    wasPlaybackSuspendedForMediaServices: Bool = false
  )
    -> AudioSessionReaction {
    guard managesAudioSession else { return AudioSessionReaction() }

    switch disruption {
    case .interruptionBegan:
      return AudioSessionReaction(clearsActivationLatch: true)

    case .interruptionEnded(let shouldResume):
      let resumes = shouldResume
        && isPlaybackIntentActive
        && !wasPlaybackSuspendedForLifecycle
        && !wasPlaybackSuspendedForMediaServices
      return AudioSessionReaction(clearsActivationLatch: !resumes, reactivates: resumes)

    case .routeLost:
      // The session itself is still valid, so the latch stands.
      return AudioSessionReaction(
        pausesPlayback: true,
        clearsLifecycleSuspension: wasPlaybackSuspendedForLifecycle,
        clearsMediaServicesSuspension: wasPlaybackSuspendedForMediaServices
      )

    case .mediaServicesLost:
      let isAlreadySuspended = wasPlaybackSuspendedForLifecycle
        || wasPlaybackSuspendedForMediaServices
      return AudioSessionReaction(
        clearsActivationLatch: true,
        pausesPlayback: isPlaybackIntentActive && !isAlreadySuspended,
        preservesPlaybackIntentWhenPausing: true,
        marksMediaServicesSuspension: isPlaybackIntentActive
      )

    case .mediaServicesReset:
      let resumes = isPlaybackIntentActive
        && wasPlaybackSuspendedForMediaServices
        && !wasPlaybackSuspendedForLifecycle
      return AudioSessionReaction(
        clearsActivationLatch: !isPlaybackIntentActive,
        reconfiguresCategory: true,
        reactivates: isPlaybackIntentActive && !wasPlaybackSuspendedForLifecycle,
        resumesManagedSuspendedPlayback: resumes,
        clearsMediaServicesSuspension: wasPlaybackSuspendedForMediaServices
      )

    case .enteredBackground(let isPictureInPictureActive),
         .deviceLocked(let isPictureInPictureActive):
      guard !isPictureInPictureActive else { return AudioSessionReaction() }
      let isAlreadySuspended = wasPlaybackSuspendedForLifecycle
        || wasPlaybackSuspendedForMediaServices
      return AudioSessionReaction(
        clearsActivationLatch: true,
        pausesPlayback: isPlaybackIntentActive && !isAlreadySuspended,
        preservesPlaybackIntentWhenPausing: true,
        marksLifecycleSuspension: isPlaybackIntentActive,
        deactivatesSession: true
      )

    case .enteringForeground:
      let resumes = isPlaybackIntentActive
        && wasPlaybackSuspendedForLifecycle
        && !wasPlaybackSuspendedForMediaServices
      return AudioSessionReaction(
        reactivates: resumes,
        resumesManagedSuspendedPlayback: resumes,
        clearsLifecycleSuspension: wasPlaybackSuspendedForLifecycle
      )
    }
  }

  /// Applies a decided reaction. Split from ``reaction(to:isPlaybackIntentActive:managesAudioSession:)``
  /// so the rules stay testable and only the effects need a live session.
  func apply(_ reaction: AudioSessionReaction) {
    var pauseAccepted = !reaction.pausesPlayback
    if reaction.pausesPlayback {
      let attempt = playbackDriver.pause(
        nil,
        !reaction.preservesPlaybackIntentWhenPausing
      )
      pauseAccepted = attempt.accepted
    }
    let wasAlreadySuspended = isPlaybackSuspendedForManagedAudioLifecycle
      || isPlaybackSuspendedForMediaServices
    if pauseAccepted || wasAlreadySuspended {
      if reaction.marksLifecycleSuspension {
        isPlaybackSuspendedForManagedAudioLifecycle = true
      }
      if reaction.marksMediaServicesSuspension {
        isPlaybackSuspendedForMediaServices = true
      }
    }
    if reaction.deactivatesSession {
      deactivateAudioSessionIfNeeded()
    }
    if reaction.clearsActivationLatch {
      hasActivatedAudioSession = false
    }
    if reaction.reconfiguresCategory {
      configureAudioSession()
    }
    if reaction.reactivates {
      // Reactivation goes through the same one-shot machine as the first
      // activation, so a failure here leaves the latch clear and the next
      // playback signal retries — rather than latching a session that is not
      // actually active.
      hasActivatedAudioSession = false
      activateAudioSessionIfNeeded()
    }
    var resumedManagedSuspension = false
    if
      reaction.resumesManagedSuspendedPlayback,
      hasActivatedAudioSession,
      isPlaybackSuspendedForManagedAudioLifecycle
      || isPlaybackSuspendedForMediaServices,
      player.isPlaybackRequestedActive,
      playbackDriver.resume() {
      resumedManagedSuspension = true
    }
    if
      reaction.clearsLifecycleSuspension,
      !reaction.resumesManagedSuspendedPlayback || resumedManagedSuspension {
      isPlaybackSuspendedForManagedAudioLifecycle = false
    }
    if
      reaction.clearsMediaServicesSuspension,
      !reaction.resumesManagedSuspendedPlayback || resumedManagedSuspension {
      isPlaybackSuspendedForMediaServices = false
    }
  }

  /// Returns audio focus to other apps after SwiftVLC has suspended hidden
  /// playback. Failures are intentionally non-terminal: the activation latch
  /// is still cleared, and foreground recovery will perform a fresh category
  /// setup and activation rather than trusting stale process state.
  func deactivateAudioSessionIfNeeded() {
    #if os(iOS)
    guard managesAudioSession, hasActivatedAudioSession else { return }
    try? AVAudioSession.sharedInstance().setActive(
      false,
      options: .notifyOthersOnDeactivation
    )
    #endif
  }

  #if os(iOS)
  /// Subscribes to the session disruptions the managed path reacts to.
  ///
  /// Only when ``managesAudioSession`` is set: with it clear the library must
  /// not observe the session either, since reacting would mean mutating a
  /// session the host app owns.
  func startAudioSessionObservers() {
    guard managesAudioSession else { return }
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()

    // A controller can be constructed by a background task after UIKit has
    // already posted didEnterBackground. Seed the current state so that path
    // receives the same bounded hidden-playback policy as a live transition.
    isApplicationInBackground = UIApplication.shared.applicationState == .background
    if isApplicationInBackground {
      scheduleBackgroundPauseIfNeeded(after: .seconds(1))
    }

    audioSessionObservers = [
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        MainActor.assumeIsolated {
          self?.handleInterruption(rawType: raw, rawOptions: options)
        }
      },
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        MainActor.assumeIsolated {
          self?.handleRouteChange(rawReason: raw)
        }
      },
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereLostNotification,
        object: session,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.react(to: .mediaServicesLost)
        }
      },
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: session,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.react(to: .mediaServicesReset)
        }
      },
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.applicationDidEnterBackground()
        }
      },
      center.addObserver(
        forName: UIApplication.willEnterForegroundNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.applicationWillEnterForeground()
        }
      },
      center.addObserver(
        forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
        object: nil,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.react(to: .deviceLocked(isPictureInPictureActive: self.isActive))
        }
      }
    ]
  }

  func stopAudioSessionObservers() {
    for observer in audioSessionObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    audioSessionObservers.removeAll()
  }

  private func handleInterruption(rawType: UInt?, rawOptions: UInt?) {
    guard let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
    switch type {
    case .began:
      react(to: .interruptionBegan)
    case .ended:
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
      react(to: .interruptionEnded(shouldResume: options.contains(.shouldResume)))
    @unknown default:
      break
    }
  }

  private func handleRouteChange(rawReason: UInt?) {
    guard
      let rawReason,
      let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
      reason == .oldDeviceUnavailable
    else { return }
    react(to: .routeLost)
  }
  #endif

  /// Gives automatic PiP a bounded interval to become active before treating
  /// background playback as hidden audio. AVKit's start callbacks can arrive
  /// after UIKit's background notification, so an immediate `isActive` check
  /// races a valid automatic transition.
  func applicationDidEnterBackground(
    pauseGrace: Duration = .seconds(1)
  ) {
    isApplicationInBackground = true
    scheduleBackgroundPauseIfNeeded(after: pauseGrace)
  }

  func applicationWillEnterForeground() {
    isApplicationInBackground = false
    audioSessionBackgroundPauseTask?.cancel()
    audioSessionBackgroundPauseTask = nil
    react(to: .enteringForeground)
  }

  func handlePiPActiveChangedForManagedAudioSession(_ isActive: Bool) {
    guard managesAudioSession else { return }
    if isActive {
      audioSessionBackgroundPauseTask?.cancel()
      audioSessionBackgroundPauseTask = nil
    } else if isApplicationInBackground {
      scheduleBackgroundPauseIfNeeded(after: .zero)
    }
  }

  private func scheduleBackgroundPauseIfNeeded(after grace: Duration) {
    guard managesAudioSession, isApplicationInBackground, !isActive else { return }
    audioSessionBackgroundPauseTask?.cancel()
    audioSessionBackgroundPauseTask = Task { @MainActor [weak self] in
      do {
        try await Task.sleep(for: grace)
      } catch {
        return
      }
      guard
        let self,
        isApplicationInBackground,
        !self.isActive
      else { return }
      audioSessionBackgroundPauseTask = nil
      react(to: .enteredBackground(isPictureInPictureActive: false))
    }
  }

  /// Platform-neutral entry points, so the shared initializers and `deinit`
  /// do not need their own `#if`. macOS has no `AVAudioSession` and nothing to
  /// observe.
  func startAudioSessionObserversIfManaged() {
    #if os(iOS)
    startAudioSessionObservers()
    #endif
  }

  func stopAudioSessionObserversIfManaged() {
    #if os(iOS)
    stopAudioSessionObservers()
    #endif
  }

  /// Resolves and applies the reaction for a disruption.
  func react(to disruption: AudioSessionDisruption) {
    apply(
      Self.reaction(
        to: disruption,
        isPlaybackIntentActive: player.isPlaybackRequestedActive,
        managesAudioSession: managesAudioSession,
        wasPlaybackSuspendedForLifecycle:
        isPlaybackSuspendedForManagedAudioLifecycle,
        wasPlaybackSuspendedForMediaServices:
        isPlaybackSuspendedForMediaServices
      )
    )
  }
}

#endif
