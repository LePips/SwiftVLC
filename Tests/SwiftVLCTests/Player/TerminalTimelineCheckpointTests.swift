@testable import SwiftVLC
import CLibVLC
import CustomDump
import Dispatch
import Synchronization
import Testing

private enum TerminalCheckpointEvent: CaseIterable, Sendable {
  case mediaStopping
  case encounteredError
  case stopped

  var expectedCause: PlaybackTerminalCause {
    switch self {
    case .mediaStopping: .naturalEnd
    case .encounteredError: .failure(.decoder)
    case .stopped: .unknownNativeStop
    }
  }

  func value(mediaAddress: UInt?) -> libvlc_event_t {
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
}

private enum CompetingTerminalFinalizer: CaseIterable, Sendable {
  case beginPlayback
  case synchronizePlayback
  case externalMediaChanged
}

private struct ReservedTerminalFinalizerCase: Sendable {
  let terminal: TerminalCheckpointEvent
  let mutation: PostBoundaryTimelineMutation
  let finalizer: CompetingTerminalFinalizer

  static let allCases = TerminalCheckpointEvent.allCases.flatMap { terminal in
    PostBoundaryTimelineMutation.allCases.flatMap { mutation in
      CompetingTerminalFinalizer.allCases.map { finalizer in
        Self(terminal: terminal, mutation: mutation, finalizer: finalizer)
      }
    }
  }
}

private struct TerminalFinalizerOrderingCase: Sendable {
  let terminal: TerminalCheckpointEvent
  let finalizer: CompetingTerminalFinalizer

  static let allCases = TerminalCheckpointEvent.allCases.flatMap { terminal in
    CompetingTerminalFinalizer.allCases.map { finalizer in
      Self(terminal: terminal, finalizer: finalizer)
    }
  }
}

private enum PostBoundaryTimelineMutation: CaseIterable, Equatable, Sendable {
  case externalLanding
  case exactFrame
  case wrapperSeek
  case duration
  case buffering
  case videoOutput
}

private struct PostBoundaryTerminalTimelineCase: Sendable {
  let terminal: TerminalCheckpointEvent
  let mutation: PostBoundaryTimelineMutation

  static let allCases = TerminalCheckpointEvent.allCases.flatMap { terminal in
    PostBoundaryTimelineMutation.allCases.map { mutation in
      Self(terminal: terminal, mutation: mutation)
    }
  }
}

private enum PreBoundaryTimelineEvidence: CaseIterable, Equatable, Sendable {
  case ordinaryClock
  case externalLanding
  case exactFrame
  case wrapperSeek
}

private struct PreBoundaryTerminalTimelineCase: Sendable {
  let terminal: TerminalCheckpointEvent
  let evidence: PreBoundaryTimelineEvidence

  static let allCases = TerminalCheckpointEvent.allCases.flatMap { terminal in
    PreBoundaryTimelineEvidence.allCases.map { evidence in
      Self(terminal: terminal, evidence: evidence)
    }
  }
}

extension Integration {
  @Suite(.serialized)
  struct PlayerTerminalTimelineCheckpointTests {
    private typealias CallbackSetup = (
      player: Player,
      bridge: EventBridge,
      monitor: NativeSeekMonitor,
      generation: UInt64,
      mediaAddress: UInt?,
      outcomes: AsyncStream<PlaybackTerminalOutcome>
    )

    @Test(arguments: PreBoundaryTerminalTimelineCase.allCases)
    fileprivate func `A terminal entry preserves committed pre-entry timeline evidence`(
      testCase: PreBoundaryTerminalTimelineCase
    )
      async throws {
      let setup = try await makeCallbackSetup()
      try await seedBaseline(on: setup)
      let frameRequestID = await preparePreciseMutation(
        needsFrameRequest: testCase.evidence == .exactFrame,
        on: setup
      )

      let expectedTime: Duration
      let expectedPosition: Double
      switch testCase.evidence {
      case .ordinaryClock:
        expectedTime = .seconds(11)
        expectedPosition = 0.11

      case .externalLanding:
        await emitExternalLanding(on: setup)
        try #require(await waitForPlayerTimeline(
          setup.player,
          time: .seconds(33),
          position: 0.33
        ))
        expectedTime = .seconds(33)
        expectedPosition = 0.33

      case .exactFrame:
        let frameRequestID = try #require(frameRequestID)
        setup.monitor._noteFrameStepCompletedForTesting(
          requestID: frameRequestID,
          status: NativeFrameStepTerminalStatus.success.rawValue,
          timeMicroseconds: 34_000_000,
          position: 0.34
        )
        try #require(await waitForPlayerTimeline(
          setup.player,
          time: .seconds(34),
          position: 0.34
        ))
        expectedTime = .seconds(34)
        expectedPosition = 0.34

      case .wrapperSeek:
        try await MainActor.run {
          try setup.player.seek(to: .seconds(33))
        }
        try #require(await waitForPlayerTimeline(
          setup.player,
          time: .seconds(33),
          position: 0.33
        ))
        expectedTime = .seconds(33)
        expectedPosition = 0.33
      }

      let outcome = firstMatchingOutcome(from: setup.outcomes) { _ in true }
      await emit(testCase.terminal, on: setup)
      let value = try #require(await outcome.value)
      expectNoDifference(
        value.finalTimeline,
        baselineFinalTimeline(time: expectedTime, position: expectedPosition)
      )
    }

    @Test(arguments: PostBoundaryTerminalTimelineCase.allCases)
    fileprivate func `A terminal entry excludes delivered post-entry mutations while MainActor is free`(
      testCase: PostBoundaryTerminalTimelineCase
    )
      async throws {
      let setup = try await makeCallbackSetup()
      try await seedBaseline(on: setup)
      let frameRequestID = await preparePreciseMutation(
        needsFrameRequest: testCase.mutation == .exactFrame,
        on: setup
      )
      let gate = installEntryGate(on: setup.bridge)
      defer {
        gate.release.signal()
        setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }

      let outcome = firstMatchingOutcome(from: setup.outcomes) { _ in true }
      let callback = emitDetached(testCase.terminal, on: setup)
      try #require(await wait(gate.entered))
      try await applyPostBoundaryMutation(
        testCase.mutation,
        frameRequestID: frameRequestID,
        on: setup
      )

      gate.release.signal()
      await callback.value
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      let value = try #require(await outcome.value)
      expectNoDifference(value.finalTimeline, baselineFinalTimeline)
    }

    @Test(arguments: ReservedTerminalFinalizerCase.allCases)
    fileprivate func `A competing finalizer consumes the entered terminal reservation exactly once`(
      testCase: ReservedTerminalFinalizerCase
    )
      async throws {
      let setup = try await makeCallbackSetup()
      try await seedBaseline(on: setup)
      let frameRequestID = await preparePreciseMutation(
        needsFrameRequest: testCase.mutation == .exactFrame,
        on: setup
      )
      let successorMedia = try Media(url: TestMedia.testMP4URL)
      let nativeGeneration = setup.bridge.currentNativeHandleGeneration
      let gate = installEntryGate(on: setup.bridge)
      defer {
        gate.release.signal()
        setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }

      let outgoing = firstMatchingOutcome(from: setup.outcomes) {
        $0.generation == PlaybackGeneration(setup.generation)
      }
      let callback = emitDetached(testCase.terminal, on: setup)
      try #require(await wait(gate.entered))
      try await applyPostBoundaryMutation(
        testCase.mutation,
        frameRequestID: frameRequestID,
        on: setup
      )

      let successorGeneration: UInt64 = switch testCase.finalizer {
      case .beginPlayback:
        setup.bridge.beginPlaybackGeneration(
          setup.generation + 1,
          media: setup.mediaAddress.flatMap { OpaquePointer(bitPattern: $0) }
        )
      case .synchronizePlayback:
        setup.bridge.synchronizePlaybackGeneration(
          setup.generation + 1,
          media: successorMedia.pointer
        )
      case .externalMediaChanged:
        setup.bridge._noteExternalMediaChangedForTesting(successorMedia.pointer)
      }
      await MainActor.run {
        setup.player.sessionGeneration = successorGeneration
      }

      gate.release.signal()
      await callback.value
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      let value = try #require(await outgoing.value)
      #expect(value.cause == testCase.terminal.expectedCause)
      #expect(value.nativeGeneration == NativePlayerGeneration(nativeGeneration))
      expectNoDifference(value.finalTimeline, baselineFinalTimeline)
      #expect(setup.bridge.terminalCause(for: successorGeneration) == nil)
    }

    @Test(arguments: TerminalFinalizerOrderingCase.allCases)
    fileprivate func `A finalizer cannot overtake terminal entry before its reservation is installed`(
      testCase: TerminalFinalizerOrderingCase
    )
      async throws {
      let setup = try await makeCallbackSetup()
      try await seedBaseline(on: setup)
      let successorMedia = try Media(url: TestMedia.testMP4URL)
      let successorMediaAddress = UInt(bitPattern: successorMedia.pointer)
      let nativeGeneration = setup.bridge.currentNativeHandleGeneration
      let gate = installNativeOrderingGate(on: setup.bridge)
      defer {
        gate.release.signal()
        setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting(nil)
      }

      let outgoing = firstMatchingOutcome(from: setup.outcomes) {
        $0.generation == PlaybackGeneration(setup.generation)
      }
      let callback = emitDetached(testCase.terminal, on: setup)
      try #require(await wait(gate.entered))

      let finalizerStarted = DispatchSemaphore(value: 0)
      let finalizerCompleted = DispatchSemaphore(value: 0)
      let finalizer = Task.detached {
        finalizerStarted.signal()
        defer { finalizerCompleted.signal() }
        return switch testCase.finalizer {
        case .beginPlayback:
          setup.bridge.beginPlaybackGeneration(
            setup.generation + 1,
            media: setup.mediaAddress.flatMap { OpaquePointer(bitPattern: $0) }
          )
        case .synchronizePlayback:
          setup.bridge.synchronizePlaybackGeneration(
            setup.generation + 1,
            media: OpaquePointer(bitPattern: successorMediaAddress)
          )
        case .externalMediaChanged:
          setup.bridge._noteExternalMediaChangedForTesting(
            OpaquePointer(bitPattern: successorMediaAddress)
          )
        }
      }
      try #require(await wait(finalizerStarted))
      let completedEarly = await wait(
        finalizerCompleted,
        timeout: .milliseconds(100)
      )
      #expect(!completedEarly)

      gate.release.signal()
      await callback.value
      let successorGeneration = await finalizer.value
      setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting(nil)
      await MainActor.run {
        setup.player.sessionGeneration = successorGeneration
      }

      let value = try #require(await outgoing.value)
      #expect(value.cause == testCase.terminal.expectedCause)
      #expect(value.nativeGeneration == NativePlayerGeneration(nativeGeneration))
      expectNoDifference(value.finalTimeline, baselineFinalTimeline)
      #expect(setup.bridge.terminalCause(for: successorGeneration) == nil)
    }

    @Test(arguments: TerminalCheckpointEvent.allCases)
    fileprivate func `A post-entry media reset cannot erase the captured terminal timeline`(
      terminal: TerminalCheckpointEvent
    )
      async throws {
      let setup = try await makeCallbackSetup()
      try await seedBaseline(on: setup)
      let gate = installEntryGate(on: setup.bridge)
      defer {
        gate.release.signal()
        setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }

      let outcome = firstMatchingOutcome(from: setup.outcomes) { _ in true }
      let callback = emitDetached(terminal, on: setup)
      try #require(await wait(gate.entered))
      await MainActor.run {
        setup.player.resetMediaDerivedState()
      }
      try #require(await waitUntil {
        await MainActor.run {
          setup.player.currentTime == .zero
            && setup.player.duration == nil
            && setup.player.position == 0
            && setup.player.bufferFill == 0
            && setup.player.activeVideoOutputs == 0
        }
      })

      gate.release.signal()
      await callback.value
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      let value = try #require(await outcome.value)
      expectNoDifference(value.finalTimeline, baselineFinalTimeline)
    }

    @Test(arguments: TerminalCheckpointEvent.allCases)
    fileprivate func `A terminal reservation cannot terminate a playback generation created after entry`(
      terminal: TerminalCheckpointEvent
    )
      async throws {
      let setup = try await makeCallbackSetup()
      try await seedBaseline(on: setup)
      let gate = installEntryGate(on: setup.bridge)
      defer {
        gate.release.signal()
        setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }

      let outgoing = firstMatchingOutcome(from: setup.outcomes) {
        $0.generation == PlaybackGeneration(setup.generation)
      }
      let callback = emitDetached(terminal, on: setup)
      try #require(await wait(gate.entered))
      let successorGeneration = setup.bridge.beginPlaybackGeneration(
        setup.generation + 1,
        media: setup.mediaAddress.flatMap { OpaquePointer(bitPattern: $0) }
      )
      await MainActor.run {
        setup.player.sessionGeneration = successorGeneration
      }
      seedSuccessorTimeline(
        generation: successorGeneration,
        on: setup.bridge
      )

      gate.release.signal()
      await callback.value
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      let value = try #require(await outgoing.value)
      #expect(value.cause == terminal.expectedCause)
      expectNoDifference(value.finalTimeline, baselineFinalTimeline)
      #expect(setup.bridge.terminalCause(for: successorGeneration) == nil)
    }

    private func makeCallbackSetup() async throws -> CallbackSetup {
      try await MainActor.run {
        let player = Player(instance: TestInstance.makeAudioOnly())
        try player.load(Media(url: TestMedia.twosecURL))
        player.resetNativeSeekMonitorForCausalBoundary()
        return (
          player,
          player.eventBridge,
          player.nativeSeekMonitor,
          player.sessionGeneration,
          player.currentMedia.map { UInt(bitPattern: $0.pointer) },
          player.terminalOutcomes
        )
      }
    }

    private func seedBaseline(on setup: CallbackSetup) async throws {
      await MainActor.run {
        setup.player._setStateForTesting(
          state: .paused,
          currentTime: .seconds(11),
          duration: .seconds(100),
          position: 0.11,
          isSeekable: true
        )
      }
      let nativeGeneration = setup.bridge.currentNativeHandleGeneration
      setup.bridge._broadcastForTesting(
        .timeChanged(.seconds(11)),
        nativeHandleGeneration: nativeGeneration
      )
      setup.bridge._broadcastForTesting(
        .positionChanged(0.11),
        nativeHandleGeneration: nativeGeneration
      )
      setup.bridge._broadcastForTesting(
        .lengthChanged(.seconds(100)),
        nativeHandleGeneration: nativeGeneration
      )
      setup.bridge._broadcastForTesting(
        .bufferingProgress(0.25),
        nativeHandleGeneration: nativeGeneration
      )
      setup.bridge._broadcastForTesting(
        .voutChanged(1),
        nativeHandleGeneration: nativeGeneration
      )
      try #require(await waitUntil {
        await MainActor.run {
          setup.player.currentTime == .seconds(11)
            && setup.player.duration == .seconds(100)
            && setup.player.position == 0.11
            && setup.player.bufferFill == 0.25
            && setup.player.activeVideoOutputs == 1
        }
      })
    }

    private func preparePreciseMutation(
      needsFrameRequest: Bool,
      on setup: CallbackSetup
    )
      async -> UInt64? {
      let frameRequestID = Mutex<UInt64?>(nil)
      await MainActor.run {
        setup.player._setStateForTesting(
          state: .paused,
          duration: .seconds(100),
          isSeekable: true
        )
        setup.player._nativeSeekBaselineOverrideForTesting = { (11000, 0.11) }
        setup.player._nativeSetTimeOverrideForTesting = { _, _ in 0 }
        if needsFrameRequest {
          setup.player._nativeNextFrameOverrideForTesting = { requestID in
            frameRequestID.withLock { $0 = requestID }
            return .accepted
          }
          setup.player.nextFrame()
        }
      }
      return frameRequestID.withLock { $0 }
    }

    private func emitExternalLanding(on setup: CallbackSetup) async {
      await MainActor.run {
        setup.monitor._noteExternalSeekStartedForTesting()
        setup.monitor._noteSeekEndedForTesting()
        setup.monitor._noteTimeUpdatedForTesting(
          timeMilliseconds: 33000,
          position: 0.33
        )
      }
    }

    private func applyPostBoundaryMutation(
      _ mutation: PostBoundaryTimelineMutation,
      frameRequestID: UInt64?,
      on setup: CallbackSetup
    )
      async throws {
      switch mutation {
      case .externalLanding:
        await emitExternalLanding(on: setup)
        try #require(await waitForPlayerTimeline(
          setup.player,
          time: .seconds(33),
          position: 0.33
        ))

      case .exactFrame:
        let frameRequestID = try #require(frameRequestID)
        setup.monitor._noteFrameStepCompletedForTesting(
          requestID: frameRequestID,
          status: NativeFrameStepTerminalStatus.success.rawValue,
          timeMicroseconds: 34_000_000,
          position: 0.34
        )
        try #require(await waitForPlayerTimeline(
          setup.player,
          time: .seconds(34),
          position: 0.34
        ))

      case .wrapperSeek:
        try await MainActor.run {
          try setup.player.seek(to: .seconds(33))
        }
        try #require(await waitForPlayerTimeline(
          setup.player,
          time: .seconds(33),
          position: 0.33
        ))

      case .duration:
        await MainActor.run {
          setup.player._setStateForTesting(duration: .seconds(200))
        }
        try #require(await waitUntil {
          await MainActor.run { setup.player.duration == .seconds(200) }
        })

      case .buffering:
        setup.bridge._broadcastForTesting(
          .bufferingProgress(0.75),
          nativeHandleGeneration: setup.bridge.currentNativeHandleGeneration
        )
        try #require(await waitUntil {
          await MainActor.run { setup.player.bufferFill == 0.75 }
        })

      case .videoOutput:
        setup.bridge._broadcastForTesting(
          .voutChanged(2),
          nativeHandleGeneration: setup.bridge.currentNativeHandleGeneration
        )
        try #require(await waitUntil {
          await MainActor.run { setup.player.activeVideoOutputs == 2 }
        })
      }
    }

    private func waitForPlayerTimeline(
      _ player: Player,
      time: Duration,
      position: Double
    )
      async -> Bool {
      await waitUntil {
        await MainActor.run {
          player.currentTime == time && player.position == position
        }
      }
    }

    private func installEntryGate(
      on bridge: EventBridge
    ) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      return (entered, release)
    }

    private func installNativeOrderingGate(
      on bridge: EventBridge
    ) -> (entered: DispatchSemaphore, release: DispatchSemaphore) {
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackAfterNativeReservationHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      return (entered, release)
    }

    private func emitDetached(
      _ terminal: TerminalCheckpointEvent,
      on setup: CallbackSetup
    ) -> Task<Void, Never> {
      Task.detached {
        setup.bridge._emitNativeEventForTesting(
          terminal.value(mediaAddress: setup.mediaAddress)
        )
      }
    }

    private func emit(
      _ terminal: TerminalCheckpointEvent,
      on setup: CallbackSetup
    )
      async {
      await emitDetached(terminal, on: setup).value
    }

    private func firstMatchingOutcome(
      from stream: AsyncStream<PlaybackTerminalOutcome>,
      where predicate: @escaping @Sendable (PlaybackTerminalOutcome) -> Bool
    ) -> Task<PlaybackTerminalOutcome?, Never> {
      Task.detached { await stream.first(where: predicate) }
    }

    private func seedSuccessorTimeline(
      generation: UInt64,
      on bridge: EventBridge
    ) {
      let nativeGeneration = bridge.currentNativeHandleGeneration
      bridge._broadcastForTesting(
        .timeChanged(.seconds(22)),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: generation
      )
      bridge._broadcastForTesting(
        .positionChanged(0.22),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: generation
      )
      bridge._broadcastForTesting(
        .lengthChanged(.seconds(200)),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: generation
      )
      bridge._broadcastForTesting(
        .bufferingProgress(0.75),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: generation
      )
      bridge._broadcastForTesting(
        .voutChanged(2),
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: generation
      )
    }

    private var baselineFinalTimeline: PlaybackFinalTimeline {
      baselineFinalTimeline(time: .seconds(11), position: 0.11)
    }

    private func baselineFinalTimeline(
      time: Duration,
      position: Double
    ) -> PlaybackFinalTimeline {
      PlaybackFinalTimeline(
        time: time,
        duration: .seconds(100),
        position: position,
        bufferFill: 0.25,
        activeVideoOutputs: 1
      )
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

    private func wait(
      _ semaphore: DispatchSemaphore,
      timeout: DispatchTimeInterval = .seconds(5)
    )
      async -> Bool {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(
            returning: semaphore.wait(
              timeout: .now() + timeout
            ) == .success
          )
        }
      }
    }

    private func waitUntil(
      _ predicate: @escaping @Sendable () async -> Bool
    )
      async -> Bool {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(5))
      while clock.now < deadline {
        if await predicate() {
          return true
        }
        await Task.yield()
      }
      return false
    }
  }
}
