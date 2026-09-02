@testable import SwiftVLC
import CLibVLC
import CustomDump
import Dispatch
import Testing

private enum CachedTerminalTimelineEmission: CaseIterable, Equatable, Sendable {
  case externalLanding
  case exactFrame
}

private enum TerminalTimelineResetBoundary: CaseIterable, Sendable {
  case media
  case playback
  case nativeHandle
}

private struct CachedTerminalTimelineResetCase: Sendable {
  let emission: CachedTerminalTimelineEmission
  let boundary: TerminalTimelineResetBoundary

  static let allCases = CachedTerminalTimelineEmission.allCases.flatMap { emission in
    TerminalTimelineResetBoundary.allCases.map { boundary in
      Self(emission: emission, boundary: boundary)
    }
  }
}

private enum TimelineCallbackTerminal: CaseIterable, Sendable {
  case mediaStopping
  case encounteredError
  case stopped

  func event(mediaAddress: UInt?) -> libvlc_event_t {
    var event = libvlc_event_t()
    switch self {
    case .mediaStopping:
      event.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      event.u.media_player_media_stopping.media = mediaAddress.flatMap {
        OpaquePointer(bitPattern: $0)
      }
      event.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos

    case .encounteredError:
      event.type = Int32(libvlc_MediaPlayerEncounteredError.rawValue)
      event.u.media_player_encountered_error.failure = libvlc_playback_failure_decoder

    case .stopped:
      event.type = Int32(libvlc_MediaPlayerStopped.rawValue)
    }
    return event
  }

  func matches(_ event: PlayerEvent) -> Bool {
    switch (self, event) {
    case (.mediaStopping, .mediaStopping),
         (.encounteredError, .encounteredError),
         (.stopped, .stateChanged(.stopped)):
      true
    default:
      false
    }
  }
}

private struct TerminalCallbackTimelineCase: Sendable {
  let terminal: TimelineCallbackTerminal
  let emission: CachedTerminalTimelineEmission

  static let allCases = TimelineCallbackTerminal.allCases.flatMap { terminal in
    CachedTerminalTimelineEmission.allCases.map { emission in
      Self(terminal: terminal, emission: emission)
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct PlaybackTerminalOutcomeTests {
    @Test
    func `Replacement freezes the outgoing generation and final timeline`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let first = try Media(url: TestMedia.twosecURL)
      player.load(first)
      let generation = player.generation
      let nativeGeneration = player.nativeEventGeneration
      let outcome = firstOutcome(from: player.terminalOutcomes)

      let native = player.eventBridge.currentNativeHandleGeneration
      // Duration can be learned by the wrapper's native poll without a
      // LengthChanged callback, and paused seeks may not emit clock events.
      // Both synchronous facts still belong in the frozen outcome.
      player._setStateForTesting(duration: .seconds(60))
      player.commitSeekTarget(
        milliseconds: 15000,
        revision: player.eventBridge.advanceTimelineRevision()
      )
      player.eventBridge._broadcastForTesting(.bufferingProgress(0.75), nativeHandleGeneration: native)
      player.eventBridge._broadcastForTesting(.voutChanged(2), nativeHandleGeneration: native)

      try player.load(Media(url: TestMedia.silenceURL))

      let value = try #require(await outcome.value)
      #expect(value.generation == generation)
      #expect(value.nativeGeneration == nativeGeneration)
      #expect(value.cause == .replacement)
      #expect(value.finalTimeline.time == .seconds(15))
      #expect(value.finalTimeline.duration == .seconds(60))
      #expect(value.finalTimeline.position == 0.25)
      #expect(value.finalTimeline.bufferFill == 0.75)
      #expect(value.finalTimeline.activeVideoOutputs == 2)
    }

    @Test
    func `A stale clock callback cannot overwrite an authoritative terminal snapshot`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let generation = player.sessionGeneration
      let nativeGeneration = player.eventBridge.currentNativeHandleGeneration
      let staleRevision = player.acceptedTimelineRevision
      let staleStamp = NativeSeekEmissionStamp(
        timelineGeneration: player.nativeSeekMonitor.timelineGeneration,
        externalEpoch: player.nativeSeekMonitor.externalSeekEpoch,
        externalDrainPending: false,
        externalOverlapAmbiguous: false,
        timelineEmissionSequence: 0
      )
      let authoritativeRevision = player.eventBridge.advanceTimelineRevision()
      player.eventBridge.updateAuthoritativeTimeline(
        time: .seconds(40),
        position: 0.4,
        playbackGeneration: generation,
        timelineRevision: authoritativeRevision
      )

      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(11)),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: generation,
        emittedTimelineRevision: staleRevision,
        nativeSeekEmissionStamp: staleStamp
      )
      player.eventBridge._broadcastForTesting(
        .positionChanged(0.11),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: generation,
        emittedTimelineRevision: staleRevision,
        nativeSeekEmissionStamp: staleStamp
      )

      let outcome = firstOutcome(from: player.terminalOutcomes)
      try player.load(Media(url: TestMedia.silenceURL))
      let value = try #require(await outcome.value)
      #expect(value.finalTimeline.time == .seconds(40))
      #expect(value.finalTimeline.position == 0.4)
    }

    @Test
    func `A previous media clock cannot seed its successor terminal snapshot`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let staleRevision = player.acceptedTimelineRevision
      let staleStamp = NativeSeekEmissionStamp(
        timelineGeneration: player.nativeSeekMonitor.timelineGeneration,
        externalEpoch: player.nativeSeekMonitor.externalSeekEpoch,
        externalDrainPending: false,
        externalOverlapAmbiguous: false,
        timelineEmissionSequence: 0
      )
      try player.load(Media(url: TestMedia.silenceURL))
      let successorGeneration = player.sessionGeneration
      let nativeGeneration = player.eventBridge.currentNativeHandleGeneration

      player.eventBridge._broadcastForTesting(
        .timeChanged(.seconds(11)),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: successorGeneration,
        emittedTimelineRevision: staleRevision,
        nativeSeekEmissionStamp: staleStamp
      )
      player.eventBridge._broadcastForTesting(
        .positionChanged(0.11),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: successorGeneration,
        emittedTimelineRevision: staleRevision,
        nativeSeekEmissionStamp: staleStamp
      )

      let outcome = firstOutcome(from: player.terminalOutcomes)
      try player.load(Media(url: TestMedia.sparseURL))
      let value = try #require(await outcome.value)
      #expect(value.finalTimeline.time == .zero)
      #expect(value.finalTimeline.position == 0)
    }

    @Test
    func `An explicit stop intent outranks a following media replacement`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let outgoing = player.sessionGeneration
      let outcome = firstOutcome(from: player.terminalOutcomes)

      player.eventBridge.markRequestedStop(playbackGeneration: outgoing)
      try player.load(Media(url: TestMedia.silenceURL))

      let value = try #require(await outcome.value)
      #expect(value.generation == PlaybackGeneration(outgoing))
      #expect(value.cause == .requestedStop)
    }

    @Test
    func `Authoritative EOF emits once before the stopped reset`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)
      let expectedGeneration = player.generation
      let stream = player.terminalOutcomes
      let outcomes = collect(stream, for: .milliseconds(100))

      let native = player.eventBridge.currentNativeHandleGeneration
      player.eventBridge._broadcastForTesting(.timeChanged(.seconds(2)), nativeHandleGeneration: native)
      var stopping = libvlc_event_t()
      stopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      stopping.u.media_player_media_stopping.media = media.pointer
      stopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      player.eventBridge._emitNativeEventForTesting(stopping)

      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      player.eventBridge._emitNativeEventForTesting(stopped)

      let values = await outcomes.value
      #expect(values.count == 1)
      let value = try #require(values.first)
      #expect(value.generation == expectedGeneration)
      #expect(value.cause == .naturalEnd)
      #expect(value.finalTimeline.time == .seconds(2))
    }

    @Test
    func `Stopped freezes an already emitted external time and position landing`() async throws {
      let player = try makeCallbackTimelinePlayer()
      let outcome = firstOutcome(from: player.terminalOutcomes)

      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      emitStopped(on: player)

      let value = try #require(await outcome.value)
      #expect(value.finalTimeline.time == .seconds(33))
      #expect(value.finalTimeline.position == 0.33)
    }

    @Test
    func `Stopped freezes an already emitted external position only landing`() async throws {
      let player = try makeCallbackTimelinePlayer()
      let outcome = firstOutcome(from: player.terminalOutcomes)

      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: -1,
        position: 0.33
      )
      emitStopped(on: player)

      let value = try #require(await outcome.value)
      #expect(value.finalTimeline.time == .zero)
      #expect(value.finalTimeline.position == 0.33)
    }

    @Test
    func `Stopped freezes an already emitted exact frame before MainActor delivery`() async throws {
      let player = try makeCallbackTimelinePlayer()
      let outcome = firstOutcome(from: player.terminalOutcomes)
      let frameGeneration = player.nativeSeekMonitor.frameGeneration

      #expect(player.nativeSeekMonitor._requestFrameStepForTesting(
        requestID: 34,
        frameGeneration: frameGeneration
      ) { .accepted } == .accepted)
      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 34,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 34_000_000,
        position: 0.34
      )
      emitStopped(on: player)

      let value = try #require(await outcome.value)
      #expect(value.finalTimeline.time == .seconds(34))
      #expect(value.finalTimeline.position == 0.34)
    }

    @Test
    func `Stopped freezes the exact frame after an external landing`() async throws {
      let player = try makeCallbackTimelinePlayer()
      let outcome = firstOutcome(from: player.terminalOutcomes)

      player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
      player.nativeSeekMonitor._noteSeekEndedForTesting()
      player.nativeSeekMonitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      let frameGeneration = player.nativeSeekMonitor.frameGeneration
      #expect(player.nativeSeekMonitor._requestFrameStepForTesting(
        requestID: 34,
        frameGeneration: frameGeneration
      ) { .accepted } == .accepted)
      player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
        requestID: 34,
        status: NativeFrameStepTerminalStatus.success.rawValue,
        timeMicroseconds: 34_000_000,
        position: 0.34
      )
      emitStopped(on: player)

      let value = try #require(await outcome.value)
      #expect(value.finalTimeline.time == .seconds(34))
      #expect(value.finalTimeline.position == 0.34)
    }

    @Test(arguments: CachedTerminalTimelineResetCase.allCases)
    fileprivate func `Cached landing and frame evidence cannot cross a reset boundary`(
      testCase: CachedTerminalTimelineResetCase
    )
      async throws {
      let player = try makeCallbackTimelinePlayer()
      cacheTimelineEmission(testCase.emission, on: player)
      try crossTimelineResetBoundary(testCase.boundary, on: player)

      let outcome = firstOutcome(from: player.terminalOutcomes)
      emitStopped(on: player)

      let value = try #require(await outcome.value)
      expectNoDifference(value.finalTimeline, emptyFinalTimeline)
    }

    @Test(arguments: CachedTerminalTimelineEmission.allCases)
    fileprivate func `Pre-entry timeline evidence stays with an entered terminal across playback replacement`(
      emission: CachedTerminalTimelineEmission
    )
      async throws {
      let player = try makeCallbackTimelinePlayer()
      cacheTimelineEmission(emission, on: player)
      let bridge = player.eventBridge
      let outgoingGeneration = player.sessionGeneration
      let outcome = firstOutcome(from: player.terminalOutcomes)
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }

      let callback = Task.detached {
        bridge._emitNativeEventForTesting(
          TimelineCallbackTerminal.stopped.event(mediaAddress: nil)
        )
      }
      try #require(await wait(entered))

      let successorGeneration = bridge.beginPlaybackGeneration(
        player.sessionGeneration + 1,
        media: player.currentMedia?.pointer
      )
      player.sessionGeneration = successorGeneration
      release.signal()
      await callback.value
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)

      let value = try #require(await outcome.value)
      #expect(value.generation == PlaybackGeneration(outgoingGeneration))
      #expect(value.cause == .unknownNativeStop)
      let expectedTime: Duration = emission == .externalLanding
        ? .seconds(33)
        : .seconds(34)
      let expectedPosition = emission == .externalLanding ? 0.33 : 0.34
      expectNoDifference(
        value.finalTimeline,
        PlaybackFinalTimeline(
          time: expectedTime,
          duration: nil,
          position: expectedPosition,
          bufferFill: 0,
          activeVideoOutputs: 0
        )
      )
      #expect(bridge.terminalCause(for: successorGeneration) == nil)
    }

    @Test
    func `Encountered error freezes the engine failure kind for its generation`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let expectedGeneration = player.generation
      let outcome = firstOutcome(from: player.terminalOutcomes)

      var error = libvlc_event_t()
      error.type = Int32(libvlc_MediaPlayerEncounteredError.rawValue)
      error.u.media_player_encountered_error.failure = libvlc_playback_failure_decoder
      player.eventBridge._emitNativeEventForTesting(error)

      let value = try #require(await outcome.value)
      #expect(value.generation == expectedGeneration)
      #expect(value.cause == .failure(.decoder))

      error.u.media_player_encountered_error.failure = libvlc_playback_failure_output
      player.eventBridge._emitNativeEventForTesting(error)
      #expect(player.terminalCause(for: expectedGeneration) == .failure(.decoder))
    }

    @Test
    func `Unattributed stop reports unknown and never claims natural end`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let outcome = firstOutcome(from: player.terminalOutcomes)

      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      player.eventBridge._emitNativeEventForTesting(stopped)

      let value = try #require(await outcome.value)
      #expect(value.cause == .unknownNativeStop)
      await Task.yield()
      #expect(!player.didReachEnd)
    }

    @Test
    func `A stale terminal transition cannot reset its successor`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      let outgoing = player.sessionGeneration
      try player.load(Media(url: TestMedia.silenceURL))
      player._setStateForTesting(
        state: .playing,
        currentTime: .seconds(9),
        duration: .seconds(30),
        position: 0.3
      )

      player.handleSourcedEvent(
        SourcedPlayerEvent(
          nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
          playbackGeneration: outgoing,
          event: .stateChanged(.stopped)
        )
      )

      #expect(player.state == .playing)
      #expect(player.currentTime == .seconds(9))
      #expect(player.position == 0.3)
    }

    @Test
    func `Reloading the same media cannot attribute the retired stop to its successor`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let media = try Media(url: TestMedia.twosecURL)
      player.load(media)
      let firstGeneration = player.generation
      let sharedPointer = try #require(player.currentMedia?.pointer)
      let outcomes = collect(player.terminalOutcomes, for: .milliseconds(100))

      player.load(Media(retaining: sharedPointer))
      let secondGeneration = player.generation

      var retiredStopping = libvlc_event_t()
      retiredStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      retiredStopping.u.media_player_media_stopping.media = sharedPointer
      retiredStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_user
      player.eventBridge._emitNativeEventForTesting(retiredStopping)

      player.eventBridge._broadcastForTesting(
        .stateChanged(.opening),
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration
      )

      var currentStopping = libvlc_event_t()
      currentStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
      currentStopping.u.media_player_media_stopping.media = sharedPointer
      currentStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
      player.eventBridge._emitNativeEventForTesting(currentStopping)

      let values = await outcomes.value
      #expect(values.map(\.generation) == [firstGeneration, secondGeneration])
      #expect(values.map(\.cause) == [.replacement, .naturalEnd])
    }

    private func firstOutcome(
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

    private func makeCallbackTimelinePlayer() throws -> Player {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      // Remove any incidental load-time watcher activity. The three tests then
      // control every callback entry without yielding the main actor.
      player.resetNativeSeekMonitorForCausalBoundary()
      return player
    }

    private var emptyFinalTimeline: PlaybackFinalTimeline {
      PlaybackFinalTimeline(
        time: .zero,
        duration: nil,
        position: 0,
        bufferFill: 0,
        activeVideoOutputs: 0
      )
    }

    private func cacheTimelineEmission(
      _ emission: CachedTerminalTimelineEmission,
      on player: Player
    ) {
      switch emission {
      case .externalLanding:
        player.nativeSeekMonitor._noteExternalSeekStartedForTesting()
        player.nativeSeekMonitor._noteSeekEndedForTesting()
        player.nativeSeekMonitor._noteTimeUpdatedForTesting(
          timeMilliseconds: 33000,
          position: 0.33
        )

      case .exactFrame:
        let frameGeneration = player.nativeSeekMonitor.frameGeneration
        #expect(player.nativeSeekMonitor._requestFrameStepForTesting(
          requestID: 34,
          frameGeneration: frameGeneration
        ) { .accepted } == .accepted)
        player.nativeSeekMonitor._noteFrameStepCompletedForTesting(
          requestID: 34,
          status: NativeFrameStepTerminalStatus.success.rawValue,
          timeMicroseconds: 34_000_000,
          position: 0.34
        )
      }
    }

    private func crossTimelineResetBoundary(
      _ boundary: TerminalTimelineResetBoundary,
      on player: Player
    )
      throws {
      switch boundary {
      case .media:
        player.resetMediaDerivedState()

      case .playback:
        player.sessionGeneration = player.eventBridge.beginPlaybackGeneration(
          player.sessionGeneration + 1,
          media: player.currentMedia?.pointer
        )

      case .nativeHandle:
        try player.replaceNativePlayerForDrawablePlayback(target: nil)
      }
    }

    private func emitStopped(on player: Player) {
      var stopped = libvlc_event_t()
      stopped.type = Int32(libvlc_MediaPlayerStopped.rawValue)
      player.eventBridge._emitNativeEventForTesting(stopped)
    }

    private func wait(_ semaphore: DispatchSemaphore) async -> Bool {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(
            returning: semaphore.wait(timeout: .now() + 5) == .success
          )
        }
      }
    }

    private func collect(
      _ stream: AsyncStream<PlaybackTerminalOutcome>,
      for duration: Duration
    ) -> Task<[PlaybackTerminalOutcome], Never> {
      Task.detached {
        let collector = Task { () -> [PlaybackTerminalOutcome] in
          var values: [PlaybackTerminalOutcome] = []
          for await value in stream {
            values.append(value)
          }
          return values
        }
        try? await Task.sleep(for: duration)
        collector.cancel()
        return await collector.value
      }
    }
  }
}

extension Integration {
  @Suite(.serialized)
  struct TerminalEntryLinearizationTests {
    @Test(arguments: TerminalCallbackTimelineCase.allCases)
    fileprivate func `A terminal reservation excludes later evidence after lifecycle contention`(
      testCase: TerminalCallbackTimelineCase
    )
      async throws {
      let setup = try await MainActor.run {
        let player = Player(instance: TestInstance.makeAudioOnly())
        try player.load(Media(url: TestMedia.twosecURL))
        player.resetNativeSeekMonitorForCausalBoundary()
        return (
          player: player,
          bridge: player.eventBridge,
          monitor: player.nativeSeekMonitor,
          generation: player.sessionGeneration,
          mediaAddress: player.currentMedia.map { UInt(bitPattern: $0.pointer) },
          outcomes: player.terminalOutcomes
        )
      }
      let retainedPlayer = setup.player
      let entryRevision = setup.bridge.advanceTimelineRevision()
      let sourcedStream = setup.bridge.makeSourcedStream(policy: .unbounded)
      let sourcedTerminal = Task.detached { () -> SourcedPlayerEvent? in
        for await sourced in sourcedStream where testCase.terminal.matches(sourced.event) {
          return sourced
        }
        return nil
      }
      let outcome = Task.detached {
        await setup.outcomes.first(where: { _ in true })
      }

      let lifecycleLocked = DispatchSemaphore(value: 0)
      let releaseLifecycle = DispatchSemaphore(value: 0)
      let lifecycleReleased = DispatchSemaphore(value: 0)
      let releaseMainActor = DispatchSemaphore(value: 0)
      let callbackReservedNativeOrder = DispatchSemaphore(value: 0)
      let callbackReservedEntry = DispatchSemaphore(value: 0)
      let releaseCallback = DispatchSemaphore(value: 0)
      defer {
        releaseLifecycle.signal()
        releaseMainActor.signal()
        releaseCallback.signal()
        setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
        setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting(nil)
      }

      let holder = Task.detached {
        await MainActor.run {
          _ = setup.bridge.performIfCurrentPlaybackGeneration(setup.generation) {
            lifecycleLocked.signal()
            _ = releaseLifecycle.wait(timeout: .now() + 5)
          }
          lifecycleReleased.signal()
          _ = releaseMainActor.wait(timeout: .now() + 5)
        }
      }
      try #require(await wait(lifecycleLocked))

      setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting {
        callbackReservedNativeOrder.signal()
      }
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting {
        callbackReservedEntry.signal()
        _ = releaseCallback.wait(timeout: .now() + 5)
      }
      let callback = Task.detached {
        setup.bridge._emitNativeEventForTesting(
          testCase.terminal.event(mediaAddress: setup.mediaAddress)
        )
      }
      try #require(await wait(callbackReservedNativeOrder))
      releaseLifecycle.signal()
      try #require(await wait(lifecycleReleased))
      try #require(await wait(callbackReservedEntry))

      cacheTimelineEmission(testCase.emission, monitor: setup.monitor)
      let laterRevision = setup.bridge.advanceTimelineRevision()

      releaseCallback.signal()
      await callback.value
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting(nil)
      let value = try #require(await outcome.value)
      let sourced = try #require(await sourcedTerminal.value)

      releaseMainActor.signal()
      await holder.value

      expectNoDifference(value.finalTimeline, emptyFinalTimeline)
      #expect(sourced.timelineRevision == entryRevision)
      #expect(sourced.timelineRevision < laterRevision)
      _ = retainedPlayer
    }

    private func cacheTimelineEmission(
      _ emission: CachedTerminalTimelineEmission,
      monitor: NativeSeekMonitor
    ) {
      switch emission {
      case .externalLanding:
        monitor._noteExternalSeekStartedForTesting()
        monitor._noteSeekEndedForTesting()
        monitor._noteTimeUpdatedForTesting(
          timeMilliseconds: 33000,
          position: 0.33
        )

      case .exactFrame:
        let frameGeneration = monitor.frameGeneration
        #expect(monitor._requestFrameStepForTesting(
          requestID: 34,
          frameGeneration: frameGeneration
        ) { .accepted } == .accepted)
        monitor._noteFrameStepCompletedForTesting(
          requestID: 34,
          status: NativeFrameStepTerminalStatus.success.rawValue,
          timeMicroseconds: 34_000_000,
          position: 0.34
        )
      }
    }

    private var emptyFinalTimeline: PlaybackFinalTimeline {
      PlaybackFinalTimeline(
        time: .zero,
        duration: nil,
        position: 0,
        bufferFill: 0,
        activeVideoOutputs: 0
      )
    }

    private func wait(_ semaphore: DispatchSemaphore) async -> Bool {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(
            returning: semaphore.wait(timeout: .now() + 5) == .success
          )
        }
      }
    }
  }
}
