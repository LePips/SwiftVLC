@testable import SwiftVLC
import CLibVLC
import Foundation
import Observation
import Synchronization
import Testing

@_silgen_name("vlc_renderer_item_new")
private func makeNativeRendererItemForTesting(
  _ type: UnsafePointer<CChar>,
  _ name: UnsafePointer<CChar>?,
  _ uri: UnsafePointer<CChar>,
  _ extraSout: UnsafePointer<CChar>?,
  _ demuxFilter: UnsafePointer<CChar>?,
  _ iconURI: UnsafePointer<CChar>?,
  _ flags: Int32
) -> OpaquePointer?

@_silgen_name("vlc_renderer_item_release")
private func releaseNativeRendererItemForTesting(_ pointer: OpaquePointer)

@MainActor
private func nativeMediaMRL(on player: Player) -> String? {
  guard let media = libvlc_media_player_get_media(player.pointer) else { return nil }
  defer { libvlc_media_release(media) }
  guard let mrl = libvlc_media_get_mrl(media) else { return nil }
  defer { libvlc_free(mrl) }
  return String(cString: mrl)
}

@MainActor
private final class CurrentTimeRearmProbe {
  let player: Player
  var callbackCount = 0
  var secondCallbackMediaMRL: String?

  init(player: Player) {
    self.player = player
  }

  func arm() {
    withObservationTracking {
      _ = player.currentTime
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.callbackCount += 1
        if self.callbackCount == 1 {
          // `@Observable` setters normally open a second mutation scope.
          // Rearming here makes that hidden boundary deterministic.
          self.arm()
        } else if self.callbackCount == 2 {
          let nested = try! Media(url: TestMedia.sparseURL)
          self.secondCallbackMediaMRL = nested.mrl
          self.player.load(nested)
        }
      }
    }
  }
}

@MainActor
private final class PositionRearmProbe {
  let player: Player
  var callbackCount = 0

  init(player: Player) {
    self.player = player
  }

  func arm() {
    withObservationTracking {
      _ = player.position
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.callbackCount += 1
        if self.callbackCount == 1 {
          self.arm()
        }
      }
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerDormantSuccessorControlTests {
    @Test
    func `Dormant successor rejects timeline and transport commands without side effects`()
      async
      throws {
      let setup = try makeDormantSuccessor(nativeState: .paused)
      let player = setup.player
      player._setStateForTesting(
        currentTime: .seconds(7),
        duration: .seconds(100),
        position: 0.07,
        isSeekable: true,
        isPausable: true
      )

      let initialSeekRevision = player.intentRevisions.seek
      let initialPlaybackControlRevision = player.playbackControlIntentRevision
      let initialTimelineRevision = player.acceptedTimelineRevision
      let initialTime = player.currentTime
      let initialPosition = player.position
      var positionSeekCount = 0
      var frameStepCount = 0
      var resumeCount = 0
      var pauseDispatchCount = 0
      player._nativeSetPositionOverrideForTesting = { _, _ in
        positionSeekCount += 1
        return 0
      }
      player._nativeNextFrameOverrideForTesting = { _ in
        frameStepCount += 1
        return .accepted
      }
      player._nativeResumeCommandOverrideForTesting = {
        resumeCount += 1
      }
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._pauseProbeHookForTesting = { stage in
        if case .nativePause = stage {
          pauseDispatchCount += 1
        }
      }

      let seek = player.requestSeek(toPosition: PlaybackPosition(0.4), fast: true)
      let frame = player.requestNextFrame()
      #expect(seek.initialOutcome == .rejected)
      #expect(await seek.outcome == .rejected)
      #expect(frame.initialOutcome == .rejected)
      #expect(await frame.outcome == .rejected)
      #expect(!player.issuePause())
      #expect(!player.issueResume())

      #expect(positionSeekCount == 0)
      #expect(frameStepCount == 0)
      #expect(resumeCount == 0)
      #expect(pauseDispatchCount == 0)
      #expect(player.intentRevisions.seek == initialSeekRevision)
      #expect(player.playbackControlIntentRevision == initialPlaybackControlRevision)
      #expect(player.acceptedTimelineRevision == initialTimelineRevision)
      #expect(player.currentTime == initialTime)
      #expect(player.position == initialPosition)
      #expect(player.pauseTransition == nil)
      #expect(player.deferredPauseCommand == nil)

      #expect(
        throws: VLCError.invalidState(
          "current media is awaiting its native playback handle"
        )
      ) {
        try player.seek(to: .seconds(8))
      }
    }

    @Test
    func `Dispatch-time guards cannot redirect queued work to the retiring handle`() throws {
      let setup = try makeDormantSuccessor(nativeState: .paused)
      let player = setup.player
      var seekDispatchCount = 0
      var frameDispatchCount = 0
      player._nativeJumpTimeOverrideForTesting = { _ in
        seekDispatchCount += 1
        return 0
      }
      player._nativeNextFrameOverrideForTesting = { _ in
        frameDispatchCount += 1
        return .accepted
      }

      let seekResolver = SeekOutcomeResolver()
      let seekToken = player.nativeSeekMonitor.reserveCommand()
      let seekCommand = Player.NativeSeekCommand(
        nativeSeekToken: seekToken,
        playbackGeneration: player.sessionGeneration,
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
        externalEpoch: player.nativeSeekMonitor.externalSeekEpoch,
        timelineRevision: nil,
        dispatchEmissionSequence: nil,
        operation: .relative(milliseconds: 1000),
        evidence: Player.SeekSettlementEvidence(
          baselineTimeMilliseconds: nil,
          baselinePosition: nil,
          requestedTimeMilliseconds: nil,
          requestedPosition: nil
        ),
        publication: .revisionOnly,
        resolver: seekResolver
      )
      #expect(player.issueNativeSeekCommand(seekCommand) == -1)
      player.nativeSeekMonitor.cancelReservedCommand(seekToken)

      let frameResolver = FrameStepOutcomeResolver()
      player.pendingFrameSteps.append(
        Player.PendingFrameStep(
          requestToken: 1,
          playbackGeneration: player.sessionGeneration,
          nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
          nativeFrameGeneration: player.nativeSeekMonitor.frameGeneration,
          resolver: frameResolver,
          phase: .awaitingFrame,
          didDispatchNativeRequest: false,
          nativeRequestInFlight: false,
          timeoutTask: nil
        )
      )
      player.dispatchNextPendingFrameStepIfNeeded()

      #expect(seekDispatchCount == 0)
      #expect(frameDispatchCount == 0)
      #expect(frameResolver.resolvedOutcome == .superseded)
      #expect(player.pendingFrameSteps.isEmpty)
    }

    @Test
    func `Pause and resume revalidate after native probes before dispatch`() throws {
      let pausingPlayer = try makeActiveDrawablePlayer(nativeState: .playing)
      pausingPlayer._nativeCanPauseOverrideForTesting = true
      pausingPlayer._nativePauseSafetyOverrideForTesting = true
      let pauseSuccessor = try Media(url: TestMedia.twosecURL)
      var pauseDispatchCount = 0
      var didReplaceDuringPauseProbe = false
      pausingPlayer._pauseProbeHookForTesting = { stage in
        switch stage {
        case .capability where !didReplaceDuringPauseProbe:
          didReplaceDuringPauseProbe = true
          pausingPlayer.load(pauseSuccessor)
        case .nativePause:
          pauseDispatchCount += 1
        default:
          break
        }
      }

      #expect(!pausingPlayer.issuePause())
      #expect(didReplaceDuringPauseProbe)
      #expect(pauseDispatchCount == 0)
      #expect(!pausingPlayer.nativeHandleRepresentsCurrentMedia)
      #expect(pausingPlayer.playbackControlIntent == nil)
      #expect(pausingPlayer.pauseTransition == nil)
      #expect(pausingPlayer.deferredPauseCommand == nil)

      let resumingPlayer = try makeActiveDrawablePlayer(nativeState: .paused)
      let resumeSuccessor = try Media(url: TestMedia.twosecURL)
      var resumeDispatchCount = 0
      var didReplaceDuringResumeProbe = false
      resumingPlayer._nativeResumeCommandOverrideForTesting = {
        resumeDispatchCount += 1
      }
      resumingPlayer._pauseProbeHookForTesting = { stage in
        guard case .resumeState = stage, !didReplaceDuringResumeProbe else { return }
        didReplaceDuringResumeProbe = true
        resumingPlayer.load(resumeSuccessor)
      }

      #expect(!resumingPlayer.issueResume())
      #expect(didReplaceDuringResumeProbe)
      #expect(resumeDispatchCount == 0)
      #expect(!resumingPlayer.nativeHandleRepresentsCurrentMedia)
      #expect(resumingPlayer.playbackControlIntent == nil)
      #expect(resumingPlayer.pauseTransition == nil)
      #expect(resumingPlayer.deferredPauseCommand == nil)
    }

    @Test
    func `Load publishes dormant identity before reset observers can reenter controls`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      let initialAudioTrackRevision = player.intentRevisions.audioTrackSelection
      let initialTimelineRevision = player.acceptedTimelineRevision
      var nativeDispatches: [Player.MediaSpecificNativeDispatch] = []
      var observerRan = false
      var observedDormantIdentity = false
      var observedNativeState: PlayerState?
      var frameOutcome: FrameStepOutcome?
      player._mediaSpecificNativeDispatchHookForTesting = {
        nativeDispatches.append($0)
      }

      withObservationTracking {
        _ = player.currentTime
      } onChange: {
        MainActor.assumeIsolated {
          observerRan = true
          observedDormantIdentity = !player.nativeHandleRepresentsCurrentMedia
          observedNativeState = player.nativePlaybackState
          _ = player.videoSize
          player.currentChapter = 1
          player.selectedAudioTrack = nil
          frameOutcome = player.requestNextFrame().initialOutcome
        }
      }

      try player.load(Media(url: TestMedia.twosecURL))

      #expect(observerRan)
      #expect(observedDormantIdentity)
      #expect(observedNativeState == .idle)
      #expect(frameOutcome == .rejected)
      #expect(nativeDispatches.isEmpty)
      #expect(player.intentRevisions.audioTrackSelection == initialAudioTrackRevision)
      #expect(player.acceptedTimelineRevision == initialTimelineRevision &+ 1)
    }

    @Test
    func `Nested load from current-media observation supersedes the outer publication`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      let retiringPointer = player.pointer
      let generationBeforeLoads = player.sessionGeneration
      var nestedLoadRan = false
      var nestedMRL: String?
      var playDispatchCount = 0
      player._nativePlayOverrideForTesting = {
        playDispatchCount += 1
        return 0
      }

      withObservationTracking {
        _ = player.currentMedia
      } onChange: {
        MainActor.assumeIsolated {
          guard !nestedLoadRan else { return }
          nestedLoadRan = true
          let nested = try! Media(url: TestMedia.sparseURL)
          nestedMRL = nested.mrl
          player.load(nested)
          try! player.play()
        }
      }

      try player.load(Media(url: TestMedia.twosecURL))

      #expect(nestedLoadRan)
      #expect(player.sessionGeneration == generationBeforeLoads &+ 2)
      #expect(player.currentMedia?.mrl == nestedMRL)
      #expect(player.sessionGenerationMedia == player.currentMedia?.pointer)
      #expect(nativeMediaMRL(on: player) == nestedMRL)
      #expect(player.mediaPublicationGeneration == nil)
      #expect(player.nativeHandleRepresentsCurrentMedia)
      #expect(player.pointer != retiringPointer)
      #expect(playDispatchCount == 1)
    }

    @Test
    func `Reentrant play during current-media publication fails before native dispatch`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      var reentrantPlayError: VLCError?
      var playDispatchCount = 0
      player._nativePlayOverrideForTesting = {
        playDispatchCount += 1
        return 0
      }

      withObservationTracking {
        _ = player.currentMedia
      } onChange: {
        MainActor.assumeIsolated {
          do {
            try player.play()
          } catch let error as VLCError {
            reentrantPlayError = error
          } catch {
            Issue.record("Unexpected reentrant play error: \(error)")
          }
        }
      }

      let successor = try Media(url: TestMedia.twosecURL)
      let successorMRL = successor.mrl
      player.load(successor)

      #expect(
        reentrantPlayError
          == .invalidState("play() called while a media load is being published")
      )
      #expect(playDispatchCount == 0)
      #expect(player.currentMedia?.mrl == successorMRL)
      #expect(player.mediaPublicationGeneration == nil)
      #expect(!player.nativeHandleRepresentsCurrentMedia)
    }

    @Test
    func `Fresh-handle play publication yields to nested load and play`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      let retiringPointer = player.pointer
      let generationBeforePlays = player.sessionGeneration
      var nestedMRL: String?
      var nestedLoadRan = false
      var playDispatchCount = 0
      player._nativePlayOverrideForTesting = {
        playDispatchCount += 1
        return 0
      }

      withObservationTracking {
        _ = player.currentMedia
      } onChange: {
        MainActor.assumeIsolated {
          guard !nestedLoadRan else { return }
          nestedLoadRan = true
          let nested = try! Media(url: TestMedia.sparseURL)
          nestedMRL = nested.mrl
          player.load(nested)
          try! player.play()
        }
      }

      try player.play(Media(url: TestMedia.twosecURL))

      #expect(player.sessionGeneration == generationBeforePlays &+ 2)
      #expect(player.currentMedia?.mrl == nestedMRL)
      #expect(nativeMediaMRL(on: player) == nestedMRL)
      #expect(player.sessionGenerationMedia == player.currentMedia?.pointer)
      #expect(player.mediaPublicationGeneration == nil)
      #expect(player.nativeHandleRepresentsCurrentMedia)
      #expect(player.pointer != retiringPointer)
      #expect(playDispatchCount == 1)
    }

    @Test
    func `Synchronously rearmed reset observation has one guarded mutation boundary`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      let successor = try Media(url: TestMedia.twosecURL)
      let successorMRL = successor.mrl
      let probe = CurrentTimeRearmProbe(player: player)

      probe.arm()
      player.load(successor)

      #expect(probe.callbackCount == 1)
      #expect(probe.secondCallbackMediaMRL == nil)
      #expect(player.currentMedia?.mrl == successorMRL)
      #expect(!player.nativeHandleRepresentsCurrentMedia)
    }

    @Test
    func `Unscoped event raw storage still emits one observation`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var callbackCount = 0
      withObservationTracking {
        _ = player.currentTime
      } onChange: {
        MainActor.assumeIsolated {
          callbackCount += 1
        }
      }

      player._handleEventForTesting(.timeChanged(.seconds(9)))

      #expect(callbackCount == 1)
      #expect(player.currentTime == .seconds(9))
    }

    @Test
    func `Position raw storage has one mutation boundary for a synchronously rearmed observer`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      let probe = PositionRearmProbe(player: player)
      let playbackGeneration = player.sessionGeneration
      let nativeHandleGeneration = player.eventBridge.currentNativeHandleGeneration
      let timelineRevision = player.acceptedTimelineRevision
      let lifecycleControlEpoch = player.eventBridge.currentLifecycleControlEpoch

      probe.arm()
      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: playbackGeneration,
        event: .positionChanged(0.42),
        timelineRevision: timelineRevision,
        lifecycleControlEpoch: lifecycleControlEpoch
      ))

      #expect(probe.callbackCount == 1)
      #expect(player.position == 0.42)
    }

    @Test
    func `Native time event yields to a newer same-handle seek from its observer`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      let playbackGeneration = player.sessionGeneration
      let nativeHandleGeneration = player.eventBridge.currentNativeHandleGeneration
      let oldTimelineRevision = player.acceptedTimelineRevision
      let lifecycleControlEpoch = player.eventBridge.currentLifecycleControlEpoch
      var observerRan = false
      var newerInitialOutcome: SeekOutcome?
      var nativeSeekPositions: [Double] = []
      player._nativeSetPositionOverrideForTesting = { position, _ in
        nativeSeekPositions.append(position)
        return 0
      }
      withObservationTracking {
        _ = player.currentTime
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          newerInitialOutcome = player.requestSeek(
            toPosition: PlaybackPosition(0.6)
          ).initialOutcome
        }
      }

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: playbackGeneration,
        event: .timeChanged(.seconds(9)),
        timelineRevision: oldTimelineRevision,
        lifecycleControlEpoch: lifecycleControlEpoch
      ))

      #expect(observerRan)
      #expect(newerInitialOutcome == .pending)
      #expect(nativeSeekPositions == [0.6])
      #expect(player.acceptedTimelineRevision > oldTimelineRevision)
      #expect(player.currentTime == .seconds(60))
      #expect(player.position == 0.6)
      #expect(player.pendingSeekSettlement != nil)
      player.supersedeAllSeekWorkForCausalBoundary()
      player.resetNativeSeekMonitorForCausalBoundary()
    }

    @Test
    func `Native seek landing yields to a newer same-handle seek from its observer`() async throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      var nativeSeekPositions: [Double] = []
      player._nativeSetPositionOverrideForTesting = { position, _ in
        nativeSeekPositions.append(position)
        return 0
      }
      let first = player.requestSeek(toPosition: PlaybackPosition(0.2))
      #expect(first.initialOutcome == .pending)
      player.nativeSeekMonitor._noteSeekStartedForTesting()

      var observerRan = false
      var newerInitialOutcome: SeekOutcome?
      withObservationTracking {
        _ = player.currentTime
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          newerInitialOutcome = player.requestSeek(
            toPosition: PlaybackPosition(0.6)
          ).initialOutcome
        }
      }

      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 21000,
        position: 0.21
      )
      await drainMainActor()

      #expect(observerRan)
      #expect(await first.outcome == .superseded)
      #expect(newerInitialOutcome == .pending)
      #expect(nativeSeekPositions == [0.2, 0.6])
      #expect(player.currentTime == .seconds(60))
      #expect(player.position == 0.6)
      #expect(player.activeNativeSeek?.command.evidence.requestedPosition == 0.6)
      player.supersedeAllSeekWorkForCausalBoundary()
      player.resetNativeSeekMonitorForCausalBoundary()
    }

    @Test
    func `Active state callback cannot land after its observer stops the same handle`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .playing)
      let playbackGeneration = player.sessionGeneration
      let nativeHandleGeneration = player.eventBridge.currentNativeHandleGeneration
      let timelineRevision = player.acceptedTimelineRevision
      let lifecycleControlEpoch = player.eventBridge.currentLifecycleControlEpoch
      var observerRan = false
      withObservationTracking {
        _ = player.state
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          player.stop()
        }
      }

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: playbackGeneration,
        event: .stateChanged(.buffering),
        timelineRevision: timelineRevision,
        lifecycleControlEpoch: lifecycleControlEpoch
      ))

      #expect(observerRan)
      #expect(player.eventBridge.currentLifecycleControlEpoch > lifecycleControlEpoch)
      #expect(player.state == .playing)
    }

    @Test
    func `Buffer and vout callbacks cannot land after their observers stop the same handle`() throws {
      let bufferPlayer = try makeActiveDrawablePlayer(nativeState: .playing)
      bufferPlayer.bufferFill = 0.1
      let bufferGeneration = bufferPlayer.sessionGeneration
      let bufferNativeGeneration = bufferPlayer.eventBridge.currentNativeHandleGeneration
      let bufferTimelineRevision = bufferPlayer.acceptedTimelineRevision
      let bufferLifecycleEpoch = bufferPlayer.eventBridge.currentLifecycleControlEpoch
      var bufferObserverRan = false
      withObservationTracking {
        _ = bufferPlayer.bufferFill
      } onChange: {
        MainActor.assumeIsolated {
          guard !bufferObserverRan else { return }
          bufferObserverRan = true
          bufferPlayer.stop()
        }
      }
      bufferPlayer.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: bufferNativeGeneration,
        playbackGeneration: bufferGeneration,
        event: .bufferingProgress(0.8),
        timelineRevision: bufferTimelineRevision,
        lifecycleControlEpoch: bufferLifecycleEpoch
      ))

      let voutPlayer = try makeActiveDrawablePlayer(nativeState: .playing)
      voutPlayer.activeVideoOutputs = 1
      let voutGeneration = voutPlayer.sessionGeneration
      let voutNativeGeneration = voutPlayer.eventBridge.currentNativeHandleGeneration
      let voutTimelineRevision = voutPlayer.acceptedTimelineRevision
      let voutLifecycleEpoch = voutPlayer.eventBridge.currentLifecycleControlEpoch
      var voutObserverRan = false
      withObservationTracking {
        _ = voutPlayer.activeVideoOutputs
      } onChange: {
        MainActor.assumeIsolated {
          guard !voutObserverRan else { return }
          voutObserverRan = true
          voutPlayer.stop()
        }
      }
      voutPlayer.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: voutNativeGeneration,
        playbackGeneration: voutGeneration,
        event: .voutChanged(4),
        timelineRevision: voutTimelineRevision,
        lifecycleControlEpoch: voutLifecycleEpoch
      ))

      #expect(bufferObserverRan)
      #expect(bufferPlayer.bufferFill == 0.1)
      #expect(bufferPlayer.eventBridge.currentLifecycleControlEpoch > bufferLifecycleEpoch)
      #expect(voutObserverRan)
      #expect(voutPlayer.activeVideoOutputs == 1)
      #expect(voutPlayer.eventBridge.currentLifecycleControlEpoch > voutLifecycleEpoch)
    }

    @Test
    func `End reached callback cannot restore its flag after observer replay starts`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      let playbackGeneration = player.sessionGeneration
      let nativeHandleGeneration = player.eventBridge.currentNativeHandleGeneration
      let timelineRevision = player.acceptedTimelineRevision
      let lifecycleControlEpoch = player.eventBridge.currentLifecycleControlEpoch
      var observerRan = false
      var nativePlayCount = 0
      player._nativePlayOverrideForTesting = {
        nativePlayCount += 1
        return 0
      }
      withObservationTracking {
        _ = player.didReachEnd
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          try! player.play()
        }
      }

      player.handleSourcedEvent(SourcedPlayerEvent(
        nativeHandleGeneration: nativeHandleGeneration,
        playbackGeneration: playbackGeneration,
        event: .endReached,
        timelineRevision: timelineRevision,
        lifecycleControlEpoch: lifecycleControlEpoch
      ))

      #expect(observerRan)
      #expect(nativePlayCount == 1)
      #expect(player.eventBridge.currentLifecycleControlEpoch > lifecycleControlEpoch)
      #expect(!player.didReachEnd)
    }

    @Test
    func `Seek landing observation cannot publish into a nested successor`() async throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      player._nativeSetPositionOverrideForTesting = { _, _ in 0 }
      let request = player.requestSeek(toPosition: PlaybackPosition(0.2))
      #expect(request.initialOutcome == .pending)
      #expect(player.quarantinedSeekTimeline != nil)

      let successor = try Media(url: TestMedia.sparseURL)
      let successorMRL = successor.mrl
      var observerRan = false
      withObservationTracking {
        _ = player.currentTime
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          player.load(successor)
        }
      }

      player._completePendingSeekForTesting(time: .seconds(21), position: 0.21)

      #expect(observerRan)
      #expect(await request.outcome == .superseded)
      #expect(player.currentMedia?.mrl == successorMRL)
      #expect(player.currentTime == .zero)
      #expect(player.position == 0)
      #expect(player.activeNativeSeek == nil)
      #expect(player.queuedNativeSeek == nil)
      #expect(player.pendingSeekSettlement == nil)
      #expect(player.quarantinedSeekTimeline == nil)

      let outcome = firstTerminalOutcome(from: player.terminalOutcomes)
      let successorGeneration = player.sessionGeneration
      player.eventBridge.finishCurrentPlaybackGeneration(
        cause: .replacement,
        playbackGeneration: successorGeneration
      )
      let final = try #require(await outcome.value)
      #expect(final.generation == PlaybackGeneration(successorGeneration))
      #expect(final.finalTimeline.time == .zero)
      #expect(final.finalTimeline.position == 0)
    }

    @Test
    func `Frame landing observation cannot publish into a nested play`() async throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      player._nativeNextFrameOverrideForTesting = { _ in .accepted }
      player._nativePlayOverrideForTesting = { 0 }
      let request = player.requestNextFrame()
      #expect(request.initialOutcome == .pending)

      let successor = try Media(url: TestMedia.sparseURL)
      let successorMRL = successor.mrl
      var observerRan = false
      withObservationTracking {
        _ = player.currentTime
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          try! player.play(successor)
        }
      }

      #expect(player.resolveConsumedNativeFrameResult(NativeFrameStepResult(
        token: 1,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 7_700_000,
        position: 0.77
      )))

      #expect(observerRan)
      #expect(await request.outcome == .submitted(
        time: .milliseconds(7700),
        position: PlaybackPosition(0.77)
      ))
      #expect(player.currentMedia?.mrl == successorMRL)
      #expect(nativeMediaMRL(on: player) == successorMRL)
      #expect(player.currentTime == .zero)
      #expect(player.position == 0)
      #expect(player.nativeHandleRepresentsCurrentMedia)

      let outcome = firstTerminalOutcome(from: player.terminalOutcomes)
      let successorGeneration = player.sessionGeneration
      player.eventBridge.finishCurrentPlaybackGeneration(
        cause: .replacement,
        playbackGeneration: successorGeneration
      )
      let final = try #require(await outcome.value)
      #expect(final.generation == PlaybackGeneration(successorGeneration))
      #expect(final.finalTimeline.time == .zero)
      #expect(final.finalTimeline.position == 0)
    }

    @Test
    func `Derived intent observer cannot overwrite a newer nested command`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var observerRan = false
      withObservationTracking {
        _ = player.isPlaying
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          player.publishPlaybackIntent(false)
        }
      }

      #expect(!player.publishPlaybackIntent(true))
      #expect(observerRan)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!player.isPlaying)
      let nonisolatedIntent = player.nonisolatedPlaybackIntent.load(ordering: .acquiring)
      #expect(!nonisolatedIntent)
    }

    @Test
    func `Play end reset observation cannot redirect native dispatch to a successor`() throws {
      let player = try makeActiveDrawablePlayer(nativeState: .paused)
      player.didReachEnd = true
      var playDispatchCount = 0
      var successorMRL: String?
      var nestedLoadRan = false
      player._nativePlayOverrideForTesting = {
        playDispatchCount += 1
        return 0
      }

      withObservationTracking {
        _ = player.didReachEnd
      } onChange: {
        MainActor.assumeIsolated {
          guard !nestedLoadRan else { return }
          nestedLoadRan = true
          let successor = try! Media(url: TestMedia.sparseURL)
          successorMRL = successor.mrl
          player.load(successor)
        }
      }

      try player.play()

      #expect(playDispatchCount == 0)
      #expect(player.currentMedia?.mrl == successorMRL)
      #expect(!player.nativeHandleRepresentsCurrentMedia)
      #expect(player.didReachEnd == false)
    }

    func makeDormantSuccessor(
      nativeState: PlayerState
    )
      throws -> (player: Player, retiringPointer: OpaquePointer) {
      let player = try makeActiveDrawablePlayer(nativeState: nativeState)
      let retiringPointer = player.pointer
      try player.load(Media(url: TestMedia.twosecURL))
      #expect(player.pointer == retiringPointer)
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(player.nativePlayerReplacementHasCommittedMediaGeneration)
      #expect(!player.nativeHandleRepresentsCurrentMedia)
      return (player, retiringPointer)
    }

    func makeActiveDrawablePlayer(nativeState: PlayerState) throws -> Player {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(
        state: nativeState,
        nativeState: nativeState,
        isPlaybackRequestedActive: nativeState != .paused,
        currentTime: .seconds(5),
        duration: .seconds(100),
        position: 0.05,
        isSeekable: true,
        isPausable: true
      )
      return player
    }

    func makeRendererItem() throws -> RendererItem {
      let nativeItem = "chromecast".withCString { type in
        "SwiftVLC dormant-control fixture".withCString { name in
          "chromecast://127.0.0.1:8010".withCString { uri in
            makeNativeRendererItemForTesting(
              type,
              name,
              uri,
              nil,
              nil,
              nil,
              0x0003
            )
          }
        }
      }
      guard let nativeItem else {
        throw VLCError.operationFailed("Create renderer test fixture")
      }
      let renderer = RendererItem(retaining: nativeItem)
      releaseNativeRendererItemForTesting(nativeItem)
      return renderer
    }

    func firstTerminalOutcome(
      from stream: AsyncStream<PlaybackTerminalOutcome>
    ) -> Task<PlaybackTerminalOutcome?, Never> {
      Task.detached {
        await withTaskGroup(of: PlaybackTerminalOutcome?.self) { group in
          group.addTask { await stream.first(where: { _ in true }) }
          group.addTask {
            try? await Task.sleep(for: .seconds(1))
            return nil
          }
          let value = await group.next() ?? nil
          group.cancelAll()
          return value
        }
      }
    }

    func drainMainActor() async {
      for _ in 0..<20 {
        await Task.yield()
      }
    }
  }
}
