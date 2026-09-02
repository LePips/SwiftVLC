@testable import SwiftVLC
import Testing

extension Integration {
  /// Deterministic overlap coverage for recast's mutation authority.
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(1)))
  @MainActor struct PlayerRecastConcurrencyTests {
    @Test
    func `A pre-cancelled recast performs no replacement or renderer mutation`() async throws {
      let player = try Self.activePlayer()
      let pointer = player.pointer
      let generation = player.sessionGeneration
      var rendererCalls = 0
      var playCalls = 0
      player._nativeSetRendererOverrideForTesting = { _ in
        rendererCalls += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        playCalls += 1
        return 0
      }

      let operation = Task { @MainActor in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await player.recastAndWaitForOutcome(to: nil)
      }
      let outcome = try await operation.value

      #expect(outcome == .cancelled)
      #expect(player.pointer == pointer)
      #expect(player.sessionGeneration == generation)
      #expect(rendererCalls == 0)
      #expect(playCalls == 0)
    }

    @Test
    func `A shut-down player rejects recast without reviving its handle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      await player.shutdown()
      let inertPointer = player.pointer
      let generation = player.sessionGeneration
      var rendererCalls = 0
      player._nativeSetRendererOverrideForTesting = { _ in
        rendererCalls += 1
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .cancelled)
      #expect(player.pointer == inertPointer)
      #expect(player.sessionGeneration == generation)
      #expect(rendererCalls == 0)
    }

    @Test
    func `An attached MediaListPlayer conservatively supersedes both recast APIs`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let listPlayer = MediaListPlayer(instance: instance)
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(
        state: .playing,
        isPlaybackRequestedActive: true,
        isSeekable: true,
        isPausable: true
      )
      player.nativePlayerHasStartedPlayback = true
      listPlayer.mediaPlayer = player
      defer { listPlayer.mediaPlayer = nil }
      let pointer = player.pointer
      let generation = player.sessionGeneration
      var rendererCalls = 0
      player._nativeSetRendererOverrideForTesting = { _ in
        rendererCalls += 1
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)
      try await player.recast(to: nil)

      #expect(outcome == .superseded)
      #expect(player.pointer == pointer)
      #expect(player.sessionGeneration == generation)
      #expect(player.attachedMediaListPlayer === listPlayer)
      #expect(rendererCalls == 0)
    }

    @Test
    func `Callback-lane takeover blocks every post-await restore`() async throws {
      let player = try Self.activePlayer(
        requestedActive: false,
        currentTime: .seconds(5)
      )
      player.audioTracks = [Self.track(
        id: "prior-audio",
        type: .audio,
        language: "eng",
        isSelected: true
      )]
      var seekDispatches = 0
      player._nativeSetTimeOverrideForTesting = { _, _ in
        seekDispatches += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        player._handleEventForTesting(.seekableChanged(true))
        _ = player.eventBridge.synchronizePlaybackGeneration(
          player.sessionGeneration &+ 1,
          media: player.currentMedia?.pointer
        )
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .superseded)
      #expect(seekDispatches == 0)
      #expect(player.intentRevisions.audioTrackSelection == 0)
      #expect(player.playbackControlIntent != .pause)
    }

    @Test
    func `A newer seek wins while recast waits for successor seekability`() async throws {
      let player = try Self.activePlayer(currentTime: .seconds(5))
      player._recastWaitTimeoutForTesting = .seconds(1)
      var dispatchedTargets: [Int64] = []
      player._nativeSetTimeOverrideForTesting = { milliseconds, _ in
        dispatchedTargets.append(milliseconds)
        return 0
      }
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        Task { @MainActor in
          player._handleEventForTesting(.seekableChanged(true))
          guard let request = try? player.requestSeek(to: .seconds(9)) else {
            return
          }
          player._completePendingSeekForTesting(
            time: .seconds(9),
            position: 0.45
          )
          _ = await request.outcome
        }
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .settled)
      #expect(dispatchedTargets == [9000])
      #expect(player.currentTime == .seconds(9))
    }

    @Test
    func `Newer audio and subtitle choices win while recast waits for tracks`() async throws {
      let player = try Self.activePlayer()
      player._recastWaitTimeoutForTesting = .seconds(1)
      player.audioTracks = [Self.track(
        id: "prior-audio",
        type: .audio,
        language: "eng",
        isSelected: true
      )]
      player.subtitleTracks = [Self.track(
        id: "prior-subtitle",
        type: .subtitle,
        language: "fra",
        isSelected: true
      )]
      var newerAudioRevision: UInt64?
      var newerSubtitleRevision: UInt64?
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        Task { @MainActor in
          let carriedAudio = Self.track(
            id: "successor-english",
            type: .audio,
            language: "eng",
            isSelected: false
          )
          let userAudio = Self.track(
            id: "user-japanese",
            type: .audio,
            language: "jpn",
            isSelected: true
          )
          let carriedSubtitle = Self.track(
            id: "successor-french",
            type: .subtitle,
            language: "fra",
            isSelected: false
          )
          let userSubtitle = Self.track(
            id: "user-english-subtitle",
            type: .subtitle,
            language: "eng",
            isSelected: true
          )
          player.audioTracks = [carriedAudio, userAudio]
          player.subtitleTracks = [carriedSubtitle, userSubtitle]
          player.selectedAudioTrack = userAudio
          player.selectedSubtitleTrack = userSubtitle
          newerAudioRevision = player.intentRevisions.audioTrackSelection
          newerSubtitleRevision = player.intentRevisions.subtitleTrackSelection
        }
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .settled)
      #expect(player.selectedAudioTrack?.id == "user-japanese")
      #expect(player.selectedSubtitleTrack?.id == "user-english-subtitle")
      #expect(player.intentRevisions.audioTrackSelection == newerAudioRevision)
      #expect(player.intentRevisions.subtitleTrackSelection == newerSubtitleRevision)
    }

    @Test
    func `Newer track deselection skips the obsolete track readiness wait`() async throws {
      let player = try Self.activePlayer()
      player._recastWaitTimeoutForTesting = .seconds(2)
      player.audioTracks = [Self.track(
        id: "prior-audio",
        type: .audio,
        language: "eng",
        isSelected: true
      )]
      player.subtitleTracks = [Self.track(
        id: "prior-subtitle",
        type: .subtitle,
        language: "fra",
        isSelected: true
      )]
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        Task { @MainActor in
          player.selectedAudioTrack = nil
          player.selectedSubtitleTrack = nil
        }
        return 0
      }

      let start = ContinuousClock.now
      let outcome = try await player.recastAndWaitForOutcome(to: nil)
      let elapsed = start.duration(to: .now)

      #expect(outcome == .settled)
      #expect(elapsed < .milliseconds(500))
      #expect(player.intentRevisions.audioTrackSelection == 1)
      #expect(player.intentRevisions.subtitleTrackSelection == 1)
    }

    @Test
    func `A newer resume wins over restoration of the captured paused state`() async throws {
      let player = try Self.activePlayer(
        requestedActive: false,
        currentTime: .seconds(5)
      )
      player._recastWaitTimeoutForTesting = .milliseconds(100)
      var newerTransportRevision: UInt64?
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        Task { @MainActor in
          player.resume()
          newerTransportRevision = player.playbackControlIntentRevision
        }
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .settled)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.playbackControlIntentRevision == newerTransportRevision)
      #expect(player.state == .playing)
    }

    @Test
    func `A resume already in flight remains active across recast`() async throws {
      let player = try Self.activePlayer()
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        isSeekable: true,
        isPausable: true
      )
      player.playbackControlIntent = .resume
      let resumeRevision = player.playbackControlIntentRevision
      var pauseCount = 0
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._pauseProbeHookForTesting = { stage in
        guard stage == .nativePause else { return }
        pauseCount += 1
        player._handleEventForTesting(.stateChanged(.paused))
      }
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .settled)
      #expect(pauseCount == 0, "recast undid the authoritative Resume intent")
      #expect(player.state == .playing)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.playbackControlIntentRevision == resumeRevision)
    }

    @Test
    func `Recast preserves a managed audio pause without revoking active intent`() async throws {
      let player = try Self.activePlayer()
      player._setStateForTesting(
        state: .paused,
        isPlaybackRequestedActive: true,
        isSeekable: true,
        isPausable: true
      )
      player.playbackControlIntent = .resume
      player.preservesPlaybackIntentForManagedAudioSuspension = true
      player.isManagedAudioLifecycleSuspended = true
      let resumeRevision = player.playbackControlIntentRevision
      var pauseCount = 0
      player._nativeCanPauseOverrideForTesting = true
      player._nativePauseSafetyOverrideForTesting = true
      player._pauseProbeHookForTesting = { stage in
        guard stage == .nativePause else { return }
        pauseCount += 1
        player._handleEventForTesting(.stateChanged(.paused))
      }
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .settled)
      #expect(pauseCount == 1)
      #expect(player.state == .paused)
      #expect(player.isPlaybackRequestedActive)
      #expect(player.playbackControlIntent == .resume)
      #expect(player.playbackControlIntentRevision == resumeRevision)
      #expect(player.preservesPlaybackIntentForManagedAudioSuspension)
      #expect(player.isManagedAudioLifecycleSuspended)
    }

    @Test
    func `A newer stop is terminal and prevents later recast restoration`() async throws {
      let player = try Self.activePlayer(currentTime: .seconds(5))
      player._recastWaitTimeoutForTesting = .seconds(1)
      var seekDispatches = 0
      player._nativeSetTimeOverrideForTesting = { _, _ in
        seekDispatches += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        Task { @MainActor in
          player.stop()
        }
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .superseded)
      #expect(seekDispatches == 0)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.eventBridge.hasExplicitStopBarrier(
        playbackGeneration: player.sessionGeneration
      ))
    }

    @Test
    func `Cancelling during seek settlement returns promptly without cancelling the seek`() async throws {
      let player = try Self.activePlayer(currentTime: .seconds(5))
      player._recastWaitTimeoutForTesting = .seconds(1)
      var seekDispatched = false
      player._nativeSetTimeOverrideForTesting = { _, _ in
        seekDispatched = true
        return 0
      }
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        player._handleEventForTesting(.seekableChanged(true))
        return 0
      }

      let operation = Task { @MainActor in
        try await player.recastAndWaitForOutcome(to: nil)
      }
      let dispatchDeadline = ContinuousClock.now + .seconds(1)
      while !seekDispatched, ContinuousClock.now < dispatchDeadline {
        await Task.yield()
      }
      try #require(seekDispatched)

      let cancellationStart = ContinuousClock.now
      operation.cancel()
      let outcome = try await operation.value
      let cancellationLatency = cancellationStart.duration(to: .now)

      #expect(outcome == .cancelled)
      #expect(cancellationLatency < .milliseconds(500))
      #expect(player.pendingSeekSettlement != nil)

      // The native request still owns its ordinary resolver and can settle.
      player._completePendingSeekForTesting(
        time: .seconds(5),
        position: 0.25
      )
      #expect(player.pendingSeekSettlement == nil)
    }

    @Test
    func `Shutdown during restoration cannot be reported as settled`() async throws {
      let player = try Self.activePlayer()
      player._recastWaitTimeoutForTesting = .seconds(1)
      player.audioTracks = [Self.track(
        id: "prior-audio",
        type: .audio,
        language: "eng",
        isSelected: true
      )]
      var shutdownTask: Task<Void, Never>?
      player._nativePlayOverrideForTesting = {
        player._handleEventForTesting(.stateChanged(.playing))
        shutdownTask = Task { @MainActor in
          await Task.yield()
          await player.shutdown()
        }
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)
      if let shutdownTask {
        await shutdownTask.value
      }

      #expect(outcome == .cancelled)
      #expect(player.isShutdown)
      #expect(player.intentRevisions.audioTrackSelection == 0)
    }

    @Test
    func `Stopping and stopped supersede when no exact failure cause exists`() async {
      for state: PlayerState in [.stopping, .stopped] {
        let result = await Player.awaitPlaying(
          on: Self.statusStream(state),
          atLeast: PlaybackGeneration(1),
          timeout: .seconds(5)
        )
        #expect(result == .superseded, "\(state) must terminate the wait")
      }
    }

    private static func activePlayer(
      requestedActive: Bool = true,
      currentTime: Duration = .zero
    )
      throws -> Player {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(
        state: requestedActive ? .playing : .paused,
        isPlaybackRequestedActive: requestedActive,
        currentTime: currentTime,
        duration: .seconds(20),
        position: 0.25,
        isSeekable: true,
        isPausable: true
      )
      if currentTime > .zero {
        player.handleSourcedEvent(SourcedPlayerEvent(
          nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
          playbackGeneration: player.sessionGeneration,
          event: .timeChanged(currentTime),
          timelineRevision: player.acceptedTimelineRevision,
          lifecycleControlEpoch: player.eventBridge.currentLifecycleControlEpoch
        ))
      }
      player.nativePlayerHasStartedPlayback = true
      return player
    }

    private static func statusStream(_ state: PlayerState) -> AsyncStream<PlaybackStatus> {
      AsyncStream { continuation in
        continuation.yield(
          PlaybackStatus(state: state, generation: PlaybackGeneration(1))
        )
        continuation.finish()
      }
    }

    private static func track(
      id: String,
      type: TrackType,
      language: String?,
      isSelected: Bool
    ) -> Track {
      Track(
        id: id,
        type: type,
        name: id,
        codec: 0,
        language: language,
        trackDescription: nil,
        isSelected: isSelected,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: nil,
        height: nil,
        frameRate: nil,
        frameRateRatio: nil,
        encoding: nil
      )
    }
  }
}
