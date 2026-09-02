#if os(iOS) || os(macOS)
@testable import SwiftVLC
import Testing

/// What a managed audio session does when the system takes it away.
///
/// The bug this exists for is small and total: `hasActivatedAudioSession`
/// latched on the first success and was never cleared, so after any
/// interruption `activateAudioSessionIfNeeded()` no-oped forever. Take a phone
/// call during PiP and the audio never comes back for the rest of that
/// controller's life.
///
/// Every input here arrives as an `AVAudioSession` notification, which no test
/// on this host can raise — there is no `AVAudioSession` on macOS at all. So
/// the policy is a pure function and these are its rules.
@Suite(.tags(.logic))
struct PiPAudioSessionDisruptionTests {
  private func reaction(
    _ disruption: PiPController.AudioSessionDisruption,
    playing: Bool = true,
    managed: Bool = true,
    lifecycleSuspended: Bool = false,
    mediaServicesSuspended: Bool = false,
    resumeDenied: Bool = false
  )
    -> PiPController.AudioSessionReaction {
    PiPController.reaction(
      to: disruption,
      isPlaybackIntentActive: playing,
      managesAudioSession: managed,
      wasPlaybackSuspendedForLifecycle: lifecycleSuspended,
      wasPlaybackSuspendedForMediaServices: mediaServicesSuspended,
      wasManagedResumeDenied: resumeDenied
    )
  }

  /// The regression itself. An interruption must release the latch, or nothing
  /// can ever reactivate.
  @Test
  func `An interruption releases the activation latch`() {
    let result = reaction(.interruptionBegan)
    #expect(result.clearsActivationLatch)
    // The system already deactivated us; reactivating here would fight
    // whatever took focus.
    #expect(!result.reactivates)
    #expect(!result.pausesPlayback)
  }

  @Test
  func `An interruption ending while playing reactivates`() {
    let result = reaction(.interruptionEnded(shouldResume: true))
    #expect(result.reactivates)
    #expect(!result.clearsActivationLatch, "reactivating and clearing the latch would fight each other")
  }

  /// The criterion that matters most for trust: someone who paused before the
  /// call must not find playback running after it. The system's `.shouldResume`
  /// is a hint about the interruption, not consent from the user.
  @Test
  func `An interruption ending does not resume playback the user paused`() {
    let result = reaction(.interruptionEnded(shouldResume: true), playing: false)
    #expect(!result.reactivates, "an interruption ending resumed playback the user had paused")
    #expect(result.clearsActivationLatch, "a later play must still be able to activate")
  }

  @Test
  func `An interruption ending without the resume hint does not reactivate`() {
    let result = reaction(.interruptionEnded(shouldResume: false))
    #expect(!result.reactivates)
    #expect(result.clearsActivationLatch)
  }

  /// Apple's headphone-unplug rule. Continuing would move the audio to the
  /// speaker, which is the one outcome the user certainly did not ask for.
  @Test
  func `Losing the route pauses rather than rerouting`() {
    let result = reaction(.routeLost)
    #expect(result.pausesPlayback)
    // The session is still valid, so the latch stands.
    #expect(!result.clearsActivationLatch)
    #expect(!result.reactivates)
  }

  /// A media-services reset invalidates every session object. Apple requires
  /// rebuilding configuration without restarting playback until a fresh user
  /// action, so the pre-reset active intent becomes an ordinary recorded pause.
  @Test
  func `A media services reset invalidates activation and waits for user action`() {
    let result = reaction(.mediaServicesReset)
    #expect(result.clearsActivationLatch)
    #expect(result.pausesPlayback)
    #expect(!result.preservesPlaybackIntentWhenPausing)
    #expect(result.requiresFreshPlaybackIntent)
    #expect(!result.reactivates)
    #expect(!result.resumesManagedSuspendedPlayback)
  }

  @Test
  func `A media services reset while paused invalidates without reactivating`() {
    let result = reaction(.mediaServicesReset, playing: false)
    #expect(!result.reactivates, "a reset must not take audio focus for a paused player")
    #expect(result.clearsActivationLatch)
    #expect(result.pausesPlayback, "native playback can outlive an already-inactive intent")
    #expect(result.requiresFreshPlaybackIntent)
  }

  @Test
  func `Losing media services suspends playback without changing intent`() {
    let result = reaction(.mediaServicesLost)
    #expect(result.clearsActivationLatch)
    #expect(result.pausesPlayback)
    #expect(result.preservesPlaybackIntentWhenPausing)
    #expect(!result.reactivates)
  }

  @Test
  func `A media services reset clears suspensions without resuming them`() {
    let result = reaction(.mediaServicesReset, lifecycleSuspended: true)
    #expect(!result.reactivates)
    #expect(!result.resumesManagedSuspendedPlayback)
    #expect(result.pausesPlayback)
    #expect(result.clearsLifecycleSuspension)

    let mediaServicesPause = reaction(
      .mediaServicesReset,
      mediaServicesSuspended: true
    )
    #expect(!mediaServicesPause.reactivates)
    #expect(!mediaServicesPause.resumesManagedSuspendedPlayback)
    #expect(mediaServicesPause.pausesPlayback)
    #expect(mediaServicesPause.clearsMediaServicesSuspension)

    let userPaused = reaction(
      .mediaServicesReset,
      playing: false,
      mediaServicesSuspended: true
    )
    #expect(!userPaused.reactivates)
    #expect(!userPaused.resumesManagedSuspendedPlayback)
    #expect(userPaused.pausesPlayback)
    #expect(userPaused.clearsMediaServicesSuspension)
  }

  @Test
  func `Background without PiP suspends hidden playback and releases focus`() {
    let result = reaction(.enteredBackground(isPictureInPictureActive: false))
    #expect(result.clearsActivationLatch)
    #expect(result.pausesPlayback)
    #expect(result.preservesPlaybackIntentWhenPausing)
    #expect(result.deactivatesSession)
  }

  @Test
  func `Background with active PiP preserves playback and audio focus`() {
    #expect(
      reaction(.enteredBackground(isPictureInPictureActive: true))
        == PiPController.AudioSessionReaction()
    )
  }

  @Test
  func `Device lock has the same deterministic suspension policy`() {
    let result = reaction(.deviceLocked(isPictureInPictureActive: false))
    #expect(result.pausesPlayback)
    #expect(result.preservesPlaybackIntentWhenPausing)
    #expect(result.deactivatesSession)

    #expect(
      reaction(.deviceLocked(isPictureInPictureActive: true))
        == PiPController.AudioSessionReaction()
    )
  }

  @Test
  func `Duplicate lifecycle signals do not issue duplicate pauses`() {
    let result = reaction(
      .deviceLocked(isPictureInPictureActive: false),
      lifecycleSuspended: true
    )
    #expect(!result.pausesPlayback)
    #expect(result.deactivatesSession)
    #expect(result.clearsActivationLatch)
  }

  @Test
  func `Foreground resumes only playback suspended by lifecycle`() {
    let result = reaction(.enteringForeground, lifecycleSuspended: true)
    #expect(result.reactivates)
    #expect(result.resumesManagedSuspendedPlayback)

    let ordinaryPlayback = reaction(.enteringForeground)
    #expect(!ordinaryPlayback.reactivates)
    #expect(!ordinaryPlayback.resumesManagedSuspendedPlayback)

    let userPaused = reaction(
      .enteringForeground,
      playing: false,
      lifecycleSuspended: true
    )
    #expect(!userPaused.reactivates)
    #expect(!userPaused.resumesManagedSuspendedPlayback)
    #expect(userPaused.clearsLifecycleSuspension)
  }

  @Test
  func `Interruption denial blocks delayed lifecycle recovery`() {
    let denied = reaction(
      .enteringForeground,
      lifecycleSuspended: true,
      resumeDenied: true
    )
    #expect(!denied.reactivates)
    #expect(!denied.resumesManagedSuspendedPlayback)

    let systemDenied = reaction(.interruptionEnded(shouldResume: false))
    #expect(systemDenied.deniesManagedResume)
    #expect(!systemDenied.reactivates)
  }

  @Test
  func `Overlapping background and media outage wait for both recoveries`() {
    let resetWhileBackgrounded = reaction(
      .mediaServicesReset,
      lifecycleSuspended: true,
      mediaServicesSuspended: true
    )
    #expect(!resetWhileBackgrounded.reactivates)
    #expect(!resetWhileBackgrounded.resumesManagedSuspendedPlayback)
    #expect(resetWhileBackgrounded.pausesPlayback)
    #expect(resetWhileBackgrounded.clearsMediaServicesSuspension)
    #expect(resetWhileBackgrounded.clearsLifecycleSuspension)

    let foregroundWhileServicesAreLost = reaction(
      .enteringForeground,
      lifecycleSuspended: true,
      mediaServicesSuspended: true
    )
    #expect(!foregroundWhileServicesAreLost.reactivates)
    #expect(!foregroundWhileServicesAreLost.resumesManagedSuspendedPlayback)
    #expect(foregroundWhileServicesAreLost.clearsLifecycleSuspension)
    #expect(!foregroundWhileServicesAreLost.clearsMediaServicesSuspension)
  }

  /// A library told not to manage the session must not manage it on the way
  /// out either — including not pausing the host app's playback.
  @Test(arguments: [
    PiPController.AudioSessionDisruption.interruptionBegan,
    .interruptionEnded(shouldResume: true),
    .routeLost,
    .mediaServicesLost,
    .mediaServicesReset,
    .enteredBackground(isPictureInPictureActive: false),
    .deviceLocked(isPictureInPictureActive: false),
    .enteringForeground,
    .pictureInPictureBecameActive
  ])
  func `An unmanaged session is never touched`(disruption: PiPController.AudioSessionDisruption) {
    #expect(
      reaction(disruption, managed: false) == PiPController.AudioSessionReaction(),
      "managesAudioSession == false still produced a session mutation"
    )
  }
}

extension Integration {
  /// The effects side. The rules above decide *what* should happen; these
  /// check the controller actually does it — in particular that the latch is
  /// released, which is the whole bug.
  @Suite(.tags(.mainActor), .serialized)
  @MainActor struct PiPAudioSessionEffectTests {
    @MainActor
    final class PauseRecorder {
      var pauseCount = 0
      var pauseRecordsPlaybackIntent: [Bool] = []
      var acceptsPause = true
      var resumeCount = 0
      var acceptsResume = true

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: { _, recordsPlaybackIntent in
            self.pauseCount += 1
            self.pauseRecordsPlaybackIntent.append(recordsPlaybackIntent)
            return .init(accepted: self.acceptsPause, playbackControlRevision: nil)
          },
          resume: { _ in
            self.resumeCount += 1
            return self.acceptsResume
          },
          cancelPendingPause: { _, _, _ in },
          shouldResume: { false },
          skip: { _ in .init(resolved: .settled) }
        )
      }
    }

    private func makeController(
      player: Player,
      recorder: PauseRecorder,
      managesAudioSession: Bool = true
    )
      -> PiPController {
      PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(10),
        managesAudioSession: managesAudioSession
      )
    }

    /// The regression, end to end at the controller: before this, a latched
    /// controller stayed latched through an interruption and could never
    /// activate again.
    @Test
    func `An interruption clears the latch so a later signal can reactivate`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      controller.hasActivatedAudioSession = true

      controller.react(to: .interruptionBegan)

      #expect(
        !controller.hasActivatedAudioSession,
        "the activation latch survived an interruption; audio can never come back"
      )
      await player.shutdown()
    }

    @Test
    func `Losing the route pauses playback`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)

      controller.react(to: .routeLost)

      #expect(recorder.pauseCount == 1, "unplugging the output did not pause playback")
      await player.shutdown()
    }

    @Test
    func `A media services reset quarantines late native playback until explicit resume`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      controller.hasActivatedAudioSession = true
      controller.isPlaybackSuspendedForManagedAudioLifecycle = true
      controller.isPlaybackSuspendedForMediaServices = true

      controller.react(to: .mediaServicesReset)

      #expect(recorder.pauseCount == 1)
      #expect(recorder.pauseRecordsPlaybackIntent == [true])
      #expect(recorder.resumeCount == 0)
      #expect(!controller.hasActivatedAudioSession)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(player.playbackControlIntent == .pause)
      #expect(!controller.isPlaybackSuspendedForManagedAudioLifecycle)
      #expect(!controller.isPlaybackSuspendedForMediaServices)

      // A native callback and even a stale copy already queued in the PiP
      // observer are observations, not post-reset user permission.
      player._handleEventForTesting(.stateChanged(.playing))
      player.setPlaybackIntentFromExternalControl(true)
      controller.handlePlaybackIntentChanged(true)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!controller.hasActivatedAudioSession)
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)

      // Public Resume is an explicit playback-enabling command. The native
      // state override makes the otherwise empty test player take the real
      // resume path without pretending a Boolean observer was user input.
      player._setStateForTesting(
        state: .paused,
        nativeState: .paused,
        isPlaybackRequestedActive: false
      )
      player.resume()
      #expect(!player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(player.isPlaybackRequestedActive)
      controller.handlePlaybackIntentChanged(true)
      #expect(controller.hasActivatedAudioSession)
      await player.shutdown()
    }

    @Test
    func `Fresh Resume crosses the native reset boundary even while VLC reports playing`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player.beginMediaServicesResetPlaybackQuarantine()
      var nativeResumeCommands = 0
      player._nativeResumeCommandOverrideForTesting = {
        nativeResumeCommands += 1
      }

      let accepted = player.issueResume(
        authorizesPlaybackAfterMediaServicesReset: true
      )

      #expect(accepted)
      #expect(nativeResumeCommands == 1)
      #expect(!player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(player.isPlaybackRequestedActive)

      // Native activation can fail after Swift accepts the first command.
      // With no native success event to consume, another explicit Resume must
      // remain a real engine command so it can retry the retained native latch.
      player.resume()
      #expect(nativeResumeCommands == 2)
      await player.shutdown()
    }

    @Test
    func `Only accepted explicit Resume authorizes native reset recovery`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .paused,
        nativeState: .paused,
        isPlaybackRequestedActive: false
      )
      var authorizations: [Bool] = []
      player._nativeResumeAuthorizationOverrideForTesting = {
        authorizations.append($0)
      }

      #expect(player.issueManagedAudioResume())
      #expect(authorizations == [false])

      player._setStateForTesting(
        state: .paused,
        nativeState: .paused,
        isPlaybackRequestedActive: false
      )
      player.resume()
      #expect(authorizations == [false, true])
      await player.shutdown()
    }

    @Test
    func `Rejected playback commands cannot arm a later automatic reset recovery`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .idle,
        nativeState: .idle,
        isPlaybackRequestedActive: false
      )
      player.beginMediaServicesResetPlaybackQuarantine()
      var nativeResumeCommands = 0
      player._nativeResumeCommandOverrideForTesting = {
        nativeResumeCommands += 1
      }

      let resumeAccepted = player.issueResume(
        authorizesPlaybackAfterMediaServicesReset: true
      )
      #expect(!resumeAccepted)
      #expect(nativeResumeCommands == 0)
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(!player.isPlaybackRequestedActive)

      player._nativePlayOverrideForTesting = { -1 }
      #expect(throws: VLCError.self) {
        try player.play()
      }
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(!player.isPlaybackRequestedActive)
      await player.shutdown()
    }

    @Test
    func `AVKit Play forces the native reset boundary even when playback looks active`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(10),
        managesAudioSession: false
      )
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player.beginMediaServicesResetPlaybackQuarantine()
      var nativeResumeCommands = 0
      player._nativeResumeCommandOverrideForTesting = {
        nativeResumeCommands += 1
      }

      controller.handleSetPlaying(true)

      #expect(nativeResumeCommands == 1)
      #expect(!player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(player.isPlaybackRequestedActive)
      await player.shutdown()
    }

    @Test
    func `A rejected reset pause still installs the durable quarantine`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      recorder.acceptsPause = false
      let controller = makeController(player: player, recorder: recorder)
      player._setStateForTesting(
        state: .opening,
        nativeState: .opening,
        isPlaybackRequestedActive: false
      )
      controller.hasActivatedAudioSession = true
      controller.isPlaybackSuspendedForManagedAudioLifecycle = true
      controller.isPlaybackSuspendedForMediaServices = true
      controller.isManagedAudioResumeDeniedByInterruption = true
      controller.isManagedAudioResumePendingActivation = true

      controller.react(to: .mediaServicesReset)

      #expect(recorder.pauseCount == 1)
      #expect(recorder.pauseRecordsPlaybackIntent == [true])
      #expect(!controller.hasActivatedAudioSession)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(player.playbackControlIntent == .pause)
      #expect(!controller.isPlaybackSuspendedForManagedAudioLifecycle)
      #expect(!controller.isPlaybackSuspendedForMediaServices)
      #expect(!controller.isManagedAudioResumeDeniedByInterruption)
      #expect(!controller.isManagedAudioResumePendingActivation)

      player._handleEventForTesting(.stateChanged(.playing))
      controller.handlePlaybackIntentChanged(true)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!controller.hasActivatedAudioSession)
      await player.shutdown()
    }

    @Test
    func `A repeated reset retires pre-reset resume work without moving the boundary`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .buffering,
        nativeState: .buffering,
        isPlaybackRequestedActive: true
      )
      player.pauseTransition = .resuming
      player.deferredPauseCommand = .resume
      player.playbackControlIntent = .resume

      player.beginMediaServicesResetPlaybackQuarantine()
      let resetRevision = player.playbackControlIntentRevision
      player.beginMediaServicesResetPlaybackQuarantine()

      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(player.pauseTransition == nil)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.playbackControlIntent == .pause)
      #expect(player.playbackControlIntentRevision == resetRevision)
      #expect(!player.isPlaybackRequestedActive)
      await player.shutdown()
    }

    @Test
    func `The reset quarantine survives controller reconstruction and stays player scoped`() async {
      let resetPlayer = Player(instance: TestInstance.makeAudioOnly())
      let unaffectedPlayer = Player(instance: TestInstance.makeAudioOnly())
      let first = makeController(player: resetPlayer, recorder: PauseRecorder())
      resetPlayer._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )

      first.react(to: .mediaServicesReset)
      let successor = makeController(player: resetPlayer, recorder: PauseRecorder())
      resetPlayer._handleEventForTesting(.stateChanged(.playing))
      successor.handlePlaybackIntentChanged(true)

      #expect(resetPlayer.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(!resetPlayer.isPlaybackRequestedActive)
      #expect(!successor.hasActivatedAudioSession)

      unaffectedPlayer.setPlaybackIntentFromExternalControl(true)
      #expect(unaffectedPlayer.isPlaybackRequestedActive)
      #expect(!unaffectedPlayer.requiresFreshPlaybackIntentAfterMediaServicesReset)
      withExtendedLifetime(first) {}
      await resetPlayer.shutdown()
      await unaffectedPlayer.shutdown()
    }

    /// Criterion 4, at the effect level rather than the policy level: an
    /// unmanaged controller must not pause the host app's playback either.
    @Test
    func `An unmanaged controller neither pauses nor unlatches`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder, managesAudioSession: false)
      controller.hasActivatedAudioSession = true

      controller.react(to: .routeLost)
      controller.react(to: .interruptionBegan)
      controller.react(to: .mediaServicesReset)

      #expect(recorder.pauseCount == 0, "an unmanaged controller paused the host app's playback")
      #expect(controller.hasActivatedAudioSession)
      #expect(!player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      await player.shutdown()
    }

    @Test
    func `Background grace is cancelled when automatic PiP becomes active`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      player.setPlaybackIntentFromExternalControl(true)

      controller.applicationDidEnterBackground(pauseGrace: .milliseconds(50))
      controller.handlePiPActiveChangedForManagedAudioSession(true)
      try? await Task.sleep(for: .milliseconds(100))

      #expect(recorder.pauseCount == 0)
      #expect(!controller.isPlaybackSuspendedForManagedAudioLifecycle)
      controller.applicationWillEnterForeground()
      await player.shutdown()
    }

    @Test
    func `Stopping PiP in background suspends playback immediately`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      player.setPlaybackIntentFromExternalControl(true)
      controller.hasActivatedAudioSession = true
      controller.isApplicationInBackground = true
      controller.handlePiPActiveChangedForManagedAudioSession(false)
      for _ in 0..<20 where recorder.pauseCount == 0 {
        await Task.yield()
      }

      #expect(recorder.pauseCount == 1)
      #expect(recorder.pauseRecordsPlaybackIntent == [false])
      #expect(controller.isPlaybackSuspendedForManagedAudioLifecycle)
      #expect(!controller.hasActivatedAudioSession)

      // The active intent is deliberately preserved across this library-owned
      // pause. A copy already queued in the observer must not reactivate audio
      // before foreground or PiP recovery authorizes it.
      controller.handlePlaybackIntentChanged(true)
      #expect(!controller.hasActivatedAudioSession)

      controller.applicationWillEnterForeground()
      await player.shutdown()
    }

    @Test
    func `A lifecycle pause resumes only after activation and accepted resume`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      player.setPlaybackIntentFromExternalControl(true)
      controller.isPlaybackSuspendedForManagedAudioLifecycle = true
      controller.hasActivatedAudioSession = true

      controller.apply(
        .init(
          resumesManagedSuspendedPlayback: true,
          clearsLifecycleSuspension: true
        )
      )

      #expect(recorder.resumeCount == 1)
      #expect(!controller.isPlaybackSuspendedForManagedAudioLifecycle)

      controller.isPlaybackSuspendedForManagedAudioLifecycle = true
      recorder.acceptsResume = false
      controller.apply(
        .init(
          resumesManagedSuspendedPlayback: true,
          clearsLifecycleSuspension: true
        )
      )

      #expect(recorder.resumeCount == 2)
      #expect(controller.isPlaybackSuspendedForManagedAudioLifecycle)
      await player.shutdown()
    }

    @Test
    func `A deferred managed pause preserves intent and can be cancelled`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .opening, isPlaybackRequestedActive: true)
      player._nativePlaybackStateOverrideForTesting = .opening

      #expect(player.issueManagedAudioPause())
      #expect(player.isPlaybackRequestedActive)
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.preservesPlaybackIntentForManagedAudioSuspension)

      player._handleEventForTesting(.stateChanged(.paused))
      #expect(player.isPlaybackRequestedActive)
      #expect(player.preservesPlaybackIntentForManagedAudioSuspension)

      #expect(player.issueManagedAudioResume())
      #expect(player.isPlaybackRequestedActive)
      #expect(player.deferredPauseCommand != .pause)
      #expect(!player.preservesPlaybackIntentForManagedAudioSuspension)
      await player.shutdown()
    }

    @Test
    func `Managed suspension ownership follows the player across controllers`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let firstRecorder = PauseRecorder()
      let first = makeController(player: player, recorder: firstRecorder)
      first.isPlaybackSuspendedForManagedAudioLifecycle = true
      first.isPlaybackSuspendedForMediaServices = true

      let successor = makeController(player: player, recorder: PauseRecorder())
      #expect(successor.isPlaybackSuspendedForManagedAudioLifecycle)
      #expect(successor.isPlaybackSuspendedForMediaServices)
      withExtendedLifetime(first) {}
      await player.shutdown()
    }

    @Test
    func `Explicit playback control abandons managed suspension ownership`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      player._nativePlaybackStateOverrideForTesting = .playing
      player.preservesPlaybackIntentForManagedAudioSuspension = true
      player.isManagedAudioLifecycleSuspended = true
      player.isManagedAudioMediaServicesSuspended = true
      player.isManagedAudioResumeDeniedByInterruption = true
      player.isManagedAudioResumePendingActivation = true

      _ = player.issuePause()

      #expect(!player.preservesPlaybackIntentForManagedAudioSuspension)
      #expect(!player.isManagedAudioLifecycleSuspended)
      #expect(!player.isManagedAudioMediaServicesSuspended)
      #expect(!player.isManagedAudioResumeDeniedByInterruption)
      #expect(!player.isManagedAudioResumePendingActivation)
      await player.shutdown()
    }

    @Test
    func `Late automatic PiP activation recovers a lifecycle-only pause`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      player.setPlaybackIntentFromExternalControl(true)
      controller.hasActivatedAudioSession = true
      controller.isPlaybackSuspendedForManagedAudioLifecycle = true

      controller.handlePiPActiveChangedForManagedAudioSession(true)

      #expect(recorder.resumeCount == 1)
      #expect(!controller.isPlaybackSuspendedForManagedAudioLifecycle)
      await player.shutdown()
    }

    @Test
    func `A later activation retry completes the pending managed resume`() async {
      enum ActivationFailure: Error { case transient }

      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      player.setPlaybackIntentFromExternalControl(true)
      controller.isPlaybackSuspendedForManagedAudioLifecycle = true
      controller.isManagedAudioResumePendingActivation = true
      var attempts = 0

      controller.activateAudioSessionIfNeeded(using: {
        attempts += 1
        throw ActivationFailure.transient
      })
      #expect(recorder.resumeCount == 0)
      #expect(controller.isPlaybackSuspendedForManagedAudioLifecycle)

      controller.activateAudioSessionIfNeeded(using: { attempts += 1 })
      #expect(attempts == 2)
      #expect(recorder.resumeCount == 1)
      #expect(!controller.isPlaybackSuspendedForManagedAudioLifecycle)
      #expect(!controller.isManagedAudioResumePendingActivation)
      await player.shutdown()
    }

    @Test
    func `A playback signal retries an approved pending activation`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PauseRecorder()
      let controller = makeController(player: player, recorder: recorder)
      player.setPlaybackIntentFromExternalControl(true)
      controller.isPlaybackSuspendedForManagedAudioLifecycle = true
      controller.isManagedAudioResumePendingActivation = true

      controller.handlePlaybackIntentChanged(true)

      #expect(controller.hasActivatedAudioSession)
      #expect(recorder.resumeCount == 1)
      #expect(!controller.isPlaybackSuspendedForManagedAudioLifecycle)
      #expect(!controller.isManagedAudioResumePendingActivation)
      await player.shutdown()
    }

    @Test
    func `A stale active intent preserves an interruption resume denial`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let controller = makeController(player: player, recorder: PauseRecorder())
      controller.isPlaybackSuspendedForManagedAudioLifecycle = true
      controller.isManagedAudioResumeDeniedByInterruption = true

      controller.handlePlaybackIntentChanged(true)

      #expect(controller.isManagedAudioResumeDeniedByInterruption)
      #expect(!controller.hasActivatedAudioSession)
      #expect(controller.isPlaybackSuspendedForManagedAudioLifecycle)
      await player.shutdown()
    }

    @Test
    func `Route loss pauses a player that has no PiP controller`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      var nativePauseCommands = 0
      player._pauseProbeHookForTesting = { stage in
        if case .nativePause = stage {
          nativePauseCommands += 1
        }
      }

      player.handleManagedAppleAudioSessionDisruption(.routeLost)

      #expect(nativePauseCommands == 1)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.playbackControlIntent == .pause)
      await player.shutdown()
    }

    @Test
    func `Media-services loss suspends a player without PiP while preserving intent`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true

      player.handleManagedAppleAudioSessionDisruption(.mediaServicesLost)

      #expect(player.isPlaybackRequestedActive)
      #expect(player.preservesPlaybackIntentForManagedAudioSuspension)
      #expect(player.isManagedAudioMediaServicesSuspended)
      await player.shutdown()
    }

    @Test
    func `Media-services reset quarantines a player that has no PiP controller`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      var nativePauseCommands = 0
      player._pauseProbeHookForTesting = { stage in
        if case .nativePause = stage {
          nativePauseCommands += 1
        }
      }

      player.handleManagedAppleAudioSessionDisruption(.mediaServicesReset)

      #expect(nativePauseCommands == 1)
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.playbackControlIntent == .pause)

      // A queued native callback remains an observation, not fresh user
      // permission, even when no PiP object exists to filter it.
      player._handleEventForTesting(.stateChanged(.playing))
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(!player.isPlaybackRequestedActive)
      await player.shutdown()
    }

    @Test
    func `One controller handles reset effects while every live latch is invalidated`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let firstRecorder = PauseRecorder()
      let secondRecorder = PauseRecorder()
      let first = makeController(player: player, recorder: firstRecorder)
      let second = makeController(player: player, recorder: secondRecorder)
      player.registerManagedAppleAudioSessionController(first)
      player.registerManagedAppleAudioSessionController(second)
      first.hasActivatedAudioSession = true
      second.hasActivatedAudioSession = true
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )

      player.handleManagedAppleAudioSessionDisruption(.mediaServicesReset)

      #expect(!first.hasActivatedAudioSession)
      #expect(!second.hasActivatedAudioSession)
      #expect(firstRecorder.pauseCount + secondRecorder.pauseCount == 1)
      #expect(secondRecorder.pauseCount == 1, "the most recently registered owner was not selected")
      #expect(player.requiresFreshPlaybackIntentAfterMediaServicesReset)
      #expect(!player.isPlaybackRequestedActive)
      await player.shutdown()
    }

    #if os(iOS)
    @Test
    func `Different players rely on the native broker rather than a Swift global heuristic`() async {
      let firstPlayer = Player(instance: TestInstance.makeAudioOnly())
      let secondPlayer = Player(instance: TestInstance.makeAudioOnly())
      let first = makeController(player: firstPlayer, recorder: PauseRecorder())
      let second = makeController(player: secondPlayer, recorder: PauseRecorder())
      first.hasActivatedAudioSession = true
      second.hasActivatedAudioSession = true
      second.updatePiPActive(true)

      #expect(!first.hasAnotherManagedAudioSessionUser())

      await firstPlayer.shutdown()
      await secondPlayer.shutdown()
    }

    @Test
    func `Same-player successor controller preserves the shared player lease`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let first = makeController(player: player, recorder: PauseRecorder())
      let successor = makeController(player: player, recorder: PauseRecorder())
      first.hasActivatedAudioSession = true
      successor.hasActivatedAudioSession = true
      successor.updatePiPActive(true)

      #expect(first.hasAnotherManagedAudioSessionUser())
      await player.shutdown()
    }
    #endif
  }
}
#endif
