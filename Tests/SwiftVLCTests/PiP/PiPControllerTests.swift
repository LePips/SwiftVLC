#if os(iOS) || os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AVFoundation
import AVKit
import CLibVLC
import Dispatch
import Observation
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPControllerTests {
    @MainActor
    final class PlaybackRecorder {
      var pauseCount = 0
      var pauseRecordsIntent: [Bool] = []
      var resumeCount = 0
      var cancelPendingPauseCount = 0
      var shouldResume = false
      var skipIntervals: [CMTime] = []
      var skipOutcome: PiPController.SkipOutcome = .settled
      /// Models an input libVLC refuses to pause, so the deferred-pause retry
      /// bound can be exercised.
      var pauseSucceeds = true

      var driver: PiPController.PlaybackDriver {
        .init(
          pause: { _, recordsPlaybackControlIntent in
            self.pauseCount += 1
            self.pauseRecordsIntent.append(recordsPlaybackControlIntent)
            return .init(
              accepted: self.pauseSucceeds,
              playbackControlRevision: nil
            )
          },
          resume: { _ in
            self.resumeCount += 1
            return true
          },
          cancelPendingPause: { _, _, _ in
            self.cancelPendingPauseCount += 1
          },
          shouldResume: { self.shouldResume },
          skip: { interval in
            self.skipIntervals.append(interval)
            return .init(resolved: self.skipOutcome)
          }
        )
      }
    }

    // MARK: - Deferred pause bounding

    /// A permanently unpausable input used to retry every debounce interval
    /// forever while the published intent already said inactive — paused
    /// controls over continuing playback. It must settle to a typed rejection
    /// within a fixed bound and reconcile the intent back to playing.
    @Test
    func `A permanently unpausable input settles to a rejection and stays playing`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      // State first: the controller's observers latch the initial values at
      // init, so a transition afterwards broadcasts an active intent that
      // cancels the very pause under test.
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )

      controller._setPlayingForTesting(false)
      #expect(!player.isPlaybackRequestedActive, "PiP should publish inactive intent immediately")

      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled, "the deferred pause never stopped retrying")

      #expect(controller.deferredPauseOutcome == .rejected)
      #expect(
        recorder.pauseCount <= PiPController.maxDeferredPauseAttempts,
        "retried past the bound: \(recorder.pauseCount)"
      )
      #expect(
        player.isPlaybackRequestedActive,
        "intent stayed inactive while playback continued — paused UI over playing media"
      )
      #expect(controller._pipPlaybackActiveForTesting())
      #expect(recorder.cancelPendingPauseCount == 1)
      #expect(recorder.pauseRecordsIntent.first == true)
      #expect(
        recorder.pauseRecordsIntent.dropFirst().allSatisfy { !$0 },
        "a retry was incorrectly promoted to a fresh transport command"
      )
    }

    /// A live player can retain a pause that native capability checks reject.
    /// Terminal rejection must retire that player-owned command before the
    /// public outcome becomes visible, or a later capability event can execute
    /// a pause after the controller has declared the request finished.
    @Test
    func `Terminal rejection retires the player-owned deferred pause`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativePlaybackStateOverrideForTesting = .playing
      player.configureQualificationPauseFault(mode: .permanentRejection)
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )

      controller._setPlayingForTesting(false)

      #expect(await awaitDeferredPauseOutcome(controller))
      #expect(controller.deferredPauseOutcome == .rejected)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.deferredPauseCommandPlaybackGeneration == nil)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.qualificationPauseFaultSnapshot.forcedRejectionCount >= 1)
      #expect(player.qualificationPauseFaultSnapshot.nativePauseCommandCount == 0)
    }

    @Test
    func `Transient qualification rejection returns to the live pause path`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player.configureQualificationPauseFault(
        mode: .transientRejection,
        transientRejections: 3
      )
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )
      controller._deferredPauseRetryHookForTesting = {
        player.performDeferredPauseCommandIfNeeded()
      }

      controller._setPlayingForTesting(false)

      #expect(await awaitDeferredPauseOutcome(controller))
      #expect(controller.deferredPauseOutcome == .issued)
      #expect(player.qualificationPauseFaultSnapshot.forcedRejectionCount == 3)
      #expect(player.qualificationPauseFaultSnapshot.nativePauseCommandCount == 1)
      #expect(player.qualificationPauseFaultSnapshot.remainingTransientRejections == 0)
    }

    /// Apps need to react when a deferred pause settles, rather than polling
    /// an internal diagnostic while playback intent has already changed.
    @Test
    func `Deferred pause outcome invalidates observation when it settles`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )

      controller._setPlayingForTesting(false)
      #expect(controller.deferredPauseOutcome == nil)

      let fired = Mutex(false)
      withObservationTracking {
        _ = controller.deferredPauseOutcome
      } onChange: {
        fired.withLock { $0 = true }
      }

      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled)
      #expect(controller.deferredPauseOutcome == .rejected)
      #expect(fired.withLock { $0 }, "settled outcome did not invalidate Observation")
    }

    @Test
    func `A newer pause outcome prevents rejected attempt side effects`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )
      let observerRan = Mutex(false)

      withObservationTracking {
        _ = controller.deferredPauseOutcome
      } onChange: {
        MainActor.assumeIsolated {
          let isFirstCallback = observerRan.withLock { didRun in
            guard !didRun else { return false }
            didRun = true
            return true
          }
          guard isFirstCallback else { return }
          // Model a newer command taking ownership at the exact Observation
          // boundary of the older rejection publication.
          controller.setDeferredPauseOutcome(.cancelled)
          player.setPlaybackIntentFromExternalControl(false)
          controller.pipPlaybackActive = false
        }
      }

      controller._setPlayingForTesting(false)
      #expect(await awaitDeferredPauseOutcome(controller))

      #expect(observerRan.withLock { $0 })
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!controller._pipPlaybackActiveForTesting())
    }

    /// Publishing the rejection is an Observation reentrancy boundary. An app
    /// can synchronously stop the player without replacing the PiP outcome;
    /// the older rejection must not then restore active intent or advertise
    /// active PiP playback over that newer stop.
    @Test
    func `A player stop observed during rejection prevents active restoration`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )
      let observerRan = Mutex(false)

      withObservationTracking {
        _ = controller.deferredPauseOutcome
      } onChange: {
        MainActor.assumeIsolated {
          let isFirstCallback = observerRan.withLock { didRun in
            guard !didRun else { return false }
            didRun = true
            return true
          }
          guard isFirstCallback else { return }
          player.stop()
        }
      }

      controller._setPlayingForTesting(false)
      #expect(await awaitDeferredPauseOutcome(controller))

      #expect(observerRan.withLock { $0 })
      #expect(controller.deferredPauseOutcome == .rejected)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!controller._pipPlaybackActiveForTesting())
      #expect(
        player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: player.sessionGeneration
        )
      )
    }

    /// Terminal ownership is reserved on the native callback thread before
    /// the corresponding event reaches Player's main-actor consumer. The
    /// rejected-pause repair must consult that reservation rather than the
    /// still-playing observable mirror.
    @Test
    func `Native terminal entry during rejection prevents active restoration`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )
      let observerRan = Mutex(false)

      withObservationTracking {
        _ = controller.deferredPauseOutcome
      } onChange: {
        MainActor.assumeIsolated {
          let isFirstCallback = observerRan.withLock { didRun in
            guard !didRun else { return false }
            didRun = true
            return true
          }
          guard isFirstCallback else { return }
          var mediaStopping = libvlc_event_t()
          mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
          mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
          player.eventBridge._emitNativeEventForTesting(mediaStopping)
          #expect(
            player.state == .playing,
            "the regression requires terminal delivery to remain queued"
          )
        }
      }

      controller._setPlayingForTesting(false)
      #expect(await awaitDeferredPauseOutcome(controller))

      #expect(observerRan.withLock { $0 })
      #expect(controller.deferredPauseOutcome == .rejected)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!controller._pipPlaybackActiveForTesting())
    }

    @Test
    func `A player pause observed during rejection prevents active restoration`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )
      let observerRan = Mutex(false)

      withObservationTracking {
        _ = controller.deferredPauseOutcome
      } onChange: {
        MainActor.assumeIsolated {
          let isFirstCallback = observerRan.withLock { didRun in
            guard !didRun else { return false }
            didRun = true
            return true
          }
          guard isFirstCallback else { return }
          player.pause()
        }
      }

      controller._setPlayingForTesting(false)
      #expect(await awaitDeferredPauseOutcome(controller))

      #expect(observerRan.withLock { $0 })
      #expect(controller.deferredPauseOutcome == .rejected)
      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!controller._pipPlaybackActiveForTesting())
    }

    @Test
    func `Media replacement cancels a deferred pause before it reaches the successor`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      controller._setPlayingForTesting(false)
      let replacement = try Media(url: TestMedia.silenceURL)
      player.load(replacement)

      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled)
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(recorder.pauseCount == 0, "the outgoing media's pause reached its successor")
    }

    @Test
    func `Callback-lane media advancement cancels pause before main-actor adoption`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      controller._setPlayingForTesting(false)
      let adoptedGeneration = player.eventBridge.currentPlaybackGeneration + 1
      _ = player.eventBridge.synchronizePlaybackGeneration(
        adoptedGeneration,
        media: nil
      )

      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled)
      #expect(player.generation.value < adoptedGeneration)
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(recorder.pauseCount == 0, "the outgoing media's pause reached the callback-lane successor")
    }

    @Test
    func `Media advancement inside the live pause probe cancels the old command`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )
      let scheduledGeneration = player.eventBridge.currentPlaybackGeneration
      player._pauseProbeHookForTesting = { stage in
        guard stage == .state else { return }
        player._pauseProbeHookForTesting = nil
        _ = player.eventBridge.synchronizePlaybackGeneration(
          scheduledGeneration + 1,
          media: nil
        )
      }

      controller._setPlayingForTesting(false)

      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled)
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(player.pauseTransition == nil)
      #expect(player.deferredPauseCommand == nil)
    }

    @Test
    func `Media advancement after a retained PiP pause retires only that command`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let scheduledGeneration = player.eventBridge.currentPlaybackGeneration
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = false
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )
      var retryCount = 0
      controller._deferredPauseRetryHookForTesting = {
        retryCount += 1
        guard retryCount == 2 else { return }
        controller._deferredPauseRetryHookForTesting = nil
        _ = player.eventBridge.synchronizePlaybackGeneration(
          scheduledGeneration + 1,
          media: nil
        )
      }

      controller._setPlayingForTesting(false)

      #expect(await awaitDeferredPauseOutcome(controller))
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.deferredPauseCommandPlaybackGeneration == nil)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Migrated retained pause is retired by its exact command revision`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let outgoingGeneration = player.eventBridge.currentPlaybackGeneration
      player.setPlaybackControlIntent(.pause)
      let ownedRevision = player.playbackControlIntentRevision

      // Model playlist adoption carrying the same command onto its successor:
      // generation changes, but exact command identity does not.
      player.setDeferredPauseCommand(
        .pause,
        playbackGeneration: outgoingGeneration + 1
      )
      player.cancelPendingPause(
        playbackGeneration: outgoingGeneration,
        playbackControlRevision: ownedRevision,
        restoringPlaybackControlIntent: .resume
      )

      #expect(player.deferredPauseCommand == nil)
      #expect(player.deferredPauseCommandPlaybackGeneration == nil)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Migrated issued pause is followed by a resume during cleanup`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let outgoingGeneration = player.eventBridge.currentPlaybackGeneration
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: false)
      player.setPlaybackControlIntent(.pause)
      let ownedRevision = player.playbackControlIntentRevision
      let successorGeneration = outgoingGeneration + 1
      _ = player.eventBridge.synchronizePlaybackGeneration(
        successorGeneration,
        media: nil
      )

      // Model the event lane having sent this exact pause after playlist
      // adoption moved it to the successor. Cleanup must not merely clear a
      // now-absent deferred command; it owes the successor a resume.
      player.lastIssuedPausePlaybackGeneration = successorGeneration
      player.lastIssuedPausePlaybackControlRevision = ownedRevision
      player.setPauseTransition(
        .pausing,
        playbackGeneration: successorGeneration
      )
      player.cancelPendingPause(
        playbackGeneration: outgoingGeneration,
        playbackControlRevision: ownedRevision,
        restoringPlaybackControlIntent: .resume
      )

      #expect(player.playbackControlIntent == .resume)
      #expect(player.deferredPauseCommand == .resume)
      #expect(player.deferredPauseCommandPlaybackGeneration == successorGeneration)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Event-lane pause issued between retries settles as issued`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = false
      player._nativePauseSafetyOverrideForTesting = true
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )
      var retryCount = 0
      controller._deferredPauseRetryHookForTesting = {
        retryCount += 1
        guard retryCount == 2 else { return }
        controller._deferredPauseRetryHookForTesting = nil
        player._nativeCanPauseOverrideForTesting = true
        player.performDeferredPauseCommandIfNeeded()
      }

      controller._setPlayingForTesting(false)

      #expect(await awaitDeferredPauseOutcome(controller))
      #expect(controller.deferredPauseOutcome == .issued)
      #expect(player.deferredPauseCommand == nil)
      #expect(
        player.lastIssuedPausePlaybackControlRevision
          == player.playbackControlIntentRevision
      )
    }

    @Test
    func `A newer resume aborts the next PiP retry before it can pause`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = false
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: true)
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )
      var retryCount = 0
      controller._deferredPauseRetryHookForTesting = {
        retryCount += 1
        guard retryCount == 2 else { return }
        controller._deferredPauseRetryHookForTesting = nil
        player.resume()
      }

      controller._setPlayingForTesting(false)

      #expect(await awaitDeferredPauseOutcome(controller))
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(player.deferredPauseCommand == nil)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `A newer app pause supersedes PiP cleanup without being erased`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .opening,
        nativeState: .opening,
        isPlaybackRequestedActive: true
      )
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )
      controller._deferredPauseRetryHookForTesting = {
        controller._deferredPauseRetryHookForTesting = nil
        player.pause()
      }

      controller._setPlayingForTesting(false)

      #expect(await awaitDeferredPauseOutcome(controller))
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
    }

    @Test
    func `Bounded PiP cleanup preserves a pause that predated the attempt`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._nativePlaybackStateOverrideForTesting = .playing
      player._nativeCanPauseOverrideForTesting = false
      player._setStateForTesting(state: .playing, isPlaybackRequestedActive: false)
      player.setPlaybackControlIntent(.pause)
      let controller = PiPController(
        player: player,
        playbackDriver: .live(player: player),
        pauseDebounce: .milliseconds(1)
      )

      controller._setPlayingForTesting(false)

      #expect(await awaitDeferredPauseOutcome(controller))
      #expect(controller.deferredPauseOutcome == .cancelled)
      #expect(player.deferredPauseCommand == .pause)
      #expect(player.playbackControlIntent == .pause)
      #expect(!player.isPlaybackRequestedActive)
    }

    /// A rejection that clears must still pause: the bound exists to stop
    /// runaway retries, not to give up on a slow input.
    @Test
    func `A transient rejection still pauses once the input becomes pausable`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      // State first: the controller's observers latch the initial values at
      // init, so a transition afterwards broadcasts an active intent that
      // cancels the very pause under test.
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )

      controller._setPlayingForTesting(false)
      try? await Task.sleep(for: .milliseconds(5))
      recorder.pauseSucceeds = true

      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled)
      #expect(controller.deferredPauseOutcome == .issued)
      #expect(!player.isPlaybackRequestedActive, "a successful pause must leave intent inactive")
    }

    /// The outcome describes the *current* attempt. Leaving a settled value
    /// visible while a new pause is in flight would let a reader — a test, or
    /// a future diagnostic — mistake the previous attempt's result for this
    /// one's, which is exactly the confusion the typed outcome exists to
    /// remove.
    @Test
    func `A newly scheduled pause clears the previous outcome`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = true
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      // Settle a first pause so there is an outcome to go stale.
      controller._setPlayingForTesting(false)
      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled)
      #expect(controller.deferredPauseOutcome == .issued)

      // Resume, then request another pause. The second attempt is still
      // debouncing, so no outcome describes it yet.
      controller._setPlayingForTesting(true)
      controller._setPlayingForTesting(false)

      #expect(
        controller.deferredPauseOutcome == nil,
        "a pause in flight reported the previous attempt's outcome"
      )
    }

    @Test
    func `A newer play command cancels the pending pause with no native call`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      controller._setPlayingForTesting(false)
      controller._setPlayingForTesting(true)

      #expect(controller.deferredPauseOutcome == .cancelled)
      try? await Task.sleep(for: .milliseconds(60))
      #expect(recorder.pauseCount == 0, "a cancelled task issued a late duplicate pause")
    }

    /// `.stopped` represents both an explicit stop and natural end of media,
    /// so this pins both terminal paths required by the issue.
    @Test
    func `Stop or end cancels the deferred pause`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = PlaybackRecorder()
      recorder.pauseSucceeds = false
      // State first: the controller's observers latch the initial values at
      // init, so a transition afterwards broadcasts an active intent that
      // cancels the very pause under test.
      player._setStateForTesting(state: .playing)
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(1)
      )

      controller._setPlayingForTesting(false)
      player._setStateForTesting(state: .stopped)

      let settled = await awaitDeferredPauseOutcome(controller)
      #expect(settled)
      #expect(controller.deferredPauseOutcome == .cancelled)
    }

    private func awaitDeferredPauseOutcome(_ controller: PiPController) async -> Bool {
      let deadline = ContinuousClock.now + .seconds(5)
      while controller.deferredPauseOutcome == nil {
        if ContinuousClock.now >= deadline {
          return false
        }
        try? await Task.sleep(for: .milliseconds(5))
      }
      return true
    }

    @Test
    func `Init with player does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      _ = controller
    }

    @Test
    func `isPossible reflects PiP support of the environment`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      // On macOS desktop, PiP may be supported; on headless CI it won't be.
      // Just verify accessing the property doesn't crash and returns a Bool.
      let possible = controller.isPossible
      #expect(possible == true || possible == false)
    }

    @Test
    func `isActive returns false initially`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      #expect(controller.isActive == false)
    }

    @Test
    func `Direct PiP reports composited VLC overlays`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      #expect(controller.overlaySupport == .composited)
    }

    @Test
    func `layer returns a valid AVSampleBufferDisplayLayer`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let layer = controller.layer
      #expect(layer.videoGravity == .resizeAspect)
    }

    @Test
    func `start does not crash without PiP support`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.start()
    }

    @Test
    func `stop does not crash without PiP support`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.stop()
    }

    @Test
    func `toggle does not crash without PiP support`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.toggle()
    }

    @Test
    func `Creating PiPController attaches vmem callbacks`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      // If vmem callbacks were attached incorrectly, subsequent player
      // operations would crash. Verify the player is still usable.
      #expect(player.state == .idle)
      _ = player.currentTime
      _ = player.volume
      _ = controller
    }

    @Test
    func `PiPController deinit cleans up without crash`() {
      let player = Player(instance: TestInstance.shared)
      do {
        let controller = PiPController(player: player)
        _ = controller.layer
        controller.start()
        // controller goes out of scope and deinits here
      }
      // Player should still be usable after PiPController is deallocated
      #expect(player.state == .idle)
    }

    @Test
    func `Multiple PiPControllers for different players`() {
      let player1 = Player(instance: TestInstance.shared)
      let player2 = Player(instance: TestInstance.shared)
      let controller1 = PiPController(player: player1)
      let controller2 = PiPController(player: player2)
      // Each controller should have its own independent layer
      #expect(controller1.layer !== controller2.layer)
      #expect(controller1.isActive == false)
      #expect(controller2.isActive == false)
      // Both players should remain functional
      #expect(player1.state == .idle)
      #expect(player2.state == .idle)
    }

    @Test
    func `isActive invalidates observation`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let fired = Mutex(false)

      withObservationTracking {
        _ = controller.isActive
      } onChange: {
        fired.withLock { $0 = true }
      }

      controller._setStateForTesting(isActive: true)

      #expect(fired.withLock { $0 })
      #expect(controller.isActive == true)
    }

    @Test
    func `isPossible invalidates observation`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let fired = Mutex(false)
      let nextValue = !controller.isPossible

      withObservationTracking {
        _ = controller.isPossible
      } onChange: {
        fired.withLock { $0 = true }
      }

      controller._setStateForTesting(isPossible: nextValue)

      #expect(fired.withLock { $0 })
      #expect(controller.isPossible == nextValue)
    }

    @Test
    func `isActive observer cannot overwrite a newer same-value publication`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let observerRan = Mutex(false)

      withObservationTracking {
        _ = controller.isActive
      } onChange: {
        MainActor.assumeIsolated {
          let isFirstCallback = observerRan.withLock { observerRan in
            guard !observerRan else { return false }
            observerRan = true
            return true
          }
          guard isFirstCallback else { return }
          // Observation fires before the outer `true` mutation. Reasserting the
          // currently visible value is still a newer command and must cancel it.
          controller._setStateForTesting(isActive: false)
        }
      }

      controller._setStateForTesting(isActive: true)

      #expect(observerRan.withLock { $0 })
      #expect(controller.isActive == false)
    }

    @Test
    func `isPossible observer can retain the current value against an older update`() throws {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      _ = try #require(controller.callbackRegistration?.isBound == true)
      controller._setStateForTesting(isPossible: true)
      #expect(controller.isPossible)
      let observerRan = Mutex(false)

      withObservationTracking {
        _ = controller.isPossible
      } onChange: {
        MainActor.assumeIsolated {
          let isFirstCallback = observerRan.withLock { observerRan in
            guard !observerRan else { return false }
            observerRan = true
            return true
          }
          guard isFirstCallback else { return }
          controller._setStateForTesting(isPossible: true)
        }
      }

      controller._setStateForTesting(isPossible: false)

      #expect(observerRan.withLock { $0 })
      #expect(controller.isPossible)
    }

    @Test
    func `deferred pause observer can retain the current terminal outcome`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      controller.setDeferredPauseOutcome(.cancelled)
      let observerRan = Mutex(false)

      withObservationTracking {
        _ = controller.deferredPauseOutcome
      } onChange: {
        MainActor.assumeIsolated {
          let isFirstCallback = observerRan.withLock { observerRan in
            guard !observerRan else { return false }
            observerRan = true
            return true
          }
          guard isFirstCallback else { return }
          controller.setDeferredPauseOutcome(.cancelled)
        }
      }

      controller.setDeferredPauseOutcome(.issued)

      #expect(observerRan.withLock { $0 })
      #expect(controller.deferredPauseOutcome == .cancelled)
    }
  }
}
#endif
