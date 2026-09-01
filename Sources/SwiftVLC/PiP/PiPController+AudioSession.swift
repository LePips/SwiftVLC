#if os(iOS) || os(macOS)
#if os(iOS)
import UIKit
#endif

// MARK: - Audio-session policy

extension PiPController {
  #if os(iOS)
  private static let managedAudioSessionControllers = NSHashTable<PiPController>.weakObjects()
  #endif

  /// Acquires the Player's deferred native audio-session lease the first time
  /// PiP is started or playback becomes actively requested.
  /// No-op when ``managesAudioSession`` is `false`, after the first
  /// activation, and on platforms without `AVAudioSession`.
  func activateAudioSessionIfNeeded() {
    if let audioSessionActivation {
      activateAudioSessionIfNeeded(using: audioSessionActivation)
      return
    }

    guard managesAudioSession else { return }
    if hasActivatedAudioSession {
      resumeManagedAudioSuspensionAfterActivationIfNeeded()
      return
    }

    #if os(iOS)
    guard player.acquireManagedAppleAudioSessionLeaseIfNeeded() else { return }
    #endif
    hasActivatedAudioSession = true
    resumeManagedAudioSuspensionAfterActivationIfNeeded()
  }

  /// Runs the platform activation operation at most once after it succeeds.
  ///
  /// A failed operation deliberately leaves ``hasActivatedAudioSession`` false
  /// so a later playback/PiP signal can retry. The iOS production path above
  /// uses this same state machine; accepting the operation as an argument keeps
  /// the failure and retry behavior deterministic in platform-neutral tests.
  func activateAudioSessionIfNeeded(using activate: () throws -> Void) {
    guard managesAudioSession else { return }
    if hasActivatedAudioSession {
      resumeManagedAudioSuspensionAfterActivationIfNeeded()
      return
    }
    do {
      try activate()
      hasActivatedAudioSession = true
      resumeManagedAudioSuspensionAfterActivationIfNeeded()
    } catch {
      // Activation can fail transiently (for example during an audio-session
      // interruption). Leave the state unset so the next signal retries.
    }
  }

  private func resumeManagedAudioSuspensionAfterActivationIfNeeded() {
    guard
      isManagedAudioResumePendingActivation,
      !isManagedAudioResumeDeniedByInterruption,
      player.isPlaybackRequestedActive,
      playbackDriver.resume(false)
    else { return }
    isPlaybackSuspendedForManagedAudioLifecycle = false
    isPlaybackSuspendedForMediaServices = false
    isManagedAudioResumePendingActivation = false
    player.preservesPlaybackIntentForManagedAudioSuspension = false
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
    /// Automatic PiP became active after the background grace had already
    /// issued a lifecycle suspension.
    case pictureInPictureBecameActive
  }

  /// What a disruption implies for the managed session.
  struct AudioSessionReaction: Equatable, Sendable {
    /// Clear ``hasActivatedAudioSession`` so a later signal can reactivate.
    /// Without this the latch is permanent and audio never returns.
    var clearsActivationLatch = false
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
    /// Retain an interruption-end denial across later lifecycle recovery.
    var deniesManagedResume = false
    /// A positive system decision or a new user intent clears the denial.
    var clearsManagedResumeDenial = false
    /// Publish an inactive playback intent even if the native pause cannot be
    /// issued while media services are rebuilding. The next Play/Resume is
    /// then an observable, post-disruption user action.
    var requiresFreshPlaybackIntent = false
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
  /// - A media-services reset invalidates every audio object and the current
  ///   broker lease. Playback remains paused and inactive until a new user
  ///   action acquires a freshly configured lease. Apple's reset contract
  ///   explicitly forbids treating the intent that existed before the reset
  ///   as permission to restart playback.
  ///
  /// With ``managesAudioSession`` disabled every reaction is empty: a library
  /// that was told not to touch the session must not touch it on the way out
  /// either.
  nonisolated static func reaction(
    to disruption: AudioSessionDisruption,
    isPlaybackIntentActive: Bool,
    managesAudioSession: Bool,
    wasPlaybackSuspendedForLifecycle: Bool = false,
    wasPlaybackSuspendedForMediaServices: Bool = false,
    wasManagedResumeDenied: Bool = false
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
      return AudioSessionReaction(
        clearsActivationLatch: !resumes,
        reactivates: resumes,
        deniesManagedResume: !shouldResume,
        clearsManagedResumeDenial: shouldResume
      )

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
      return AudioSessionReaction(
        // AVAudioSession and the AudioUnit graph were invalidated even if the
        // system did not deliver the earlier `mediaServicesLost` notification.
        clearsActivationLatch: true,
        // Always install a native pause barrier. Public intent can already be
        // inactive while VLC is still playing (for example during PiP's pause
        // debounce), and relying on the Boolean would let that playback cross
        // the reset boundary unnoticed.
        pausesPlayback: true,
        clearsLifecycleSuspension: wasPlaybackSuspendedForLifecycle,
        clearsMediaServicesSuspension: wasPlaybackSuspendedForMediaServices,
        requiresFreshPlaybackIntent: true
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

    case .enteringForeground, .pictureInPictureBecameActive:
      let resumes = isPlaybackIntentActive
        && wasPlaybackSuspendedForLifecycle
        && !wasPlaybackSuspendedForMediaServices
        && !wasManagedResumeDenied
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
    let wasAlreadySuspended = isPlaybackSuspendedForManagedAudioLifecycle
      || isPlaybackSuspendedForMediaServices
    if reaction.requiresFreshPlaybackIntent {
      // Install the quarantine before touching the native player. A queued
      // `.playing` callback can arrive synchronously with audio graph rebuild;
      // it must already be unable to republish the pre-reset intent.
      player.beginMediaServicesResetPlaybackQuarantine()
    }
    var pauseAccepted = !reaction.pausesPlayback
    if reaction.pausesPlayback {
      let attempt = playbackDriver.pause(
        nil,
        !reaction.preservesPlaybackIntentWhenPausing
      )
      pauseAccepted = attempt.accepted
    }
    if pauseAccepted || wasAlreadySuspended {
      if reaction.marksLifecycleSuspension {
        isPlaybackSuspendedForManagedAudioLifecycle = true
      }
      if reaction.marksMediaServicesSuspension {
        isPlaybackSuspendedForMediaServices = true
      }
      if reaction.marksLifecycleSuspension || reaction.marksMediaServicesSuspension {
        isManagedAudioResumePendingActivation = false
      }
    }
    if reaction.deniesManagedResume {
      isManagedAudioResumeDeniedByInterruption = true
      isManagedAudioResumePendingActivation = false
    }
    if reaction.clearsManagedResumeDenial {
      isManagedAudioResumeDeniedByInterruption = false
    }
    if reaction.deactivatesSession, pauseAccepted || wasAlreadySuspended {
      deactivateAudioSessionIfNeeded()
    }
    if reaction.clearsActivationLatch {
      #if os(iOS)
      _ = player.releaseManagedAppleAudioSessionLeaseIfNeeded()
      player.invalidateManagedAppleAudioSessionActivationLatches()
      #endif
      hasActivatedAudioSession = false
      if !reaction.reactivates {
        isManagedAudioResumePendingActivation = false
      }
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
      playbackDriver.resume(false) {
      resumedManagedSuspension = true
    }
    if reaction.resumesManagedSuspendedPlayback, !resumedManagedSuspension {
      isManagedAudioResumePendingActivation = true
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
    if resumedManagedSuspension {
      isManagedAudioResumePendingActivation = false
    }
    if
      !isPlaybackSuspendedForManagedAudioLifecycle,
      !isPlaybackSuspendedForMediaServices,
      !isManagedAudioResumePendingActivation {
      player.preservesPlaybackIntentForManagedAudioSuspension = false
    }
  }

  /// Returns audio focus to other apps after SwiftVLC has suspended hidden
  /// playback. Failures are intentionally non-terminal: the activation latch
  /// is still cleared, and foreground recovery will perform a fresh category
  /// setup and activation rather than trusting stale process state.
  func deactivateAudioSessionIfNeeded() {
    #if os(iOS)
    guard managesAudioSession, hasActivatedAudioSession else { return }
    guard !hasAnotherManagedAudioSessionUser() else { return }
    if audioSessionActivation == nil {
      _ = player.releaseManagedAppleAudioSessionLeaseIfNeeded()
      player.invalidateManagedAppleAudioSessionActivationLatches()
    } else {
      hasActivatedAudioSession = false
    }
    #else
    hasActivatedAudioSession = false
    #endif
  }

  #if os(iOS)
  func hasAnotherManagedAudioSessionUser() -> Bool {
    Self.managedAudioSessionControllers.allObjects.contains {
      $0 !== self
        && $0.player === player
        && $0.managesAudioSession
        && $0.hasActivatedAudioSession
        && ($0.isActive || (
          $0.player.isPlaybackRequestedActive
            && !$0.isPlaybackSuspendedForManagedAudioLifecycle
            && !$0.isPlaybackSuspendedForMediaServices
        ))
    }
  }
  #endif

  #if os(iOS)
  /// Subscribes to the session disruptions the managed path reacts to.
  ///
  /// Only when ``managesAudioSession`` is set: with it clear the library must
  /// not perform PiP-owned session activation or lifecycle mutation. The
  /// player independently observes route loss and media-services reset in
  /// both ownership modes because those are VLC transport-safety boundaries,
  /// not `AVAudioSession` configuration.
  func startAudioSessionObservers() {
    guard managesAudioSession else { return }
    Self.managedAudioSessionControllers.add(self)
    player.registerManagedAppleAudioSessionController(self)
    let center = NotificationCenter.default

    // A controller can be constructed by a background task after UIKit has
    // already posted didEnterBackground. Seed the current state so that path
    // receives the same bounded hidden-playback policy as a live transition.
    isApplicationInBackground = UIApplication.shared.applicationState == .background
    if isApplicationInBackground {
      scheduleBackgroundPauseIfNeeded(after: .seconds(1))
    }

    audioSessionObservers = [
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
    Self.managedAudioSessionControllers.remove(self)
    player.unregisterManagedAppleAudioSessionController(self)
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
      if isPlaybackSuspendedForManagedAudioLifecycle {
        react(to: .pictureInPictureBecameActive)
      }
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
        isPlaybackSuspendedForMediaServices,
        wasManagedResumeDenied:
        isManagedAudioResumeDeniedByInterruption
      )
    )
  }
}

#endif
