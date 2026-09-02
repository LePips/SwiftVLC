@testable import SwiftVLC
import CLibVLC
import CustomDump
import Dispatch
import Observation
import Testing

private enum FrozenNonterminalCallback: CaseIterable, Sendable {
  case opening
  case playing
  case paused
  case buffering
  case seekable
  case vout

  var event: libvlc_event_t {
    var event = libvlc_event_t()
    switch self {
    case .opening:
      event.type = Int32(libvlc_MediaPlayerOpening.rawValue)
    case .playing:
      event.type = Int32(libvlc_MediaPlayerPlaying.rawValue)
    case .paused:
      event.type = Int32(libvlc_MediaPlayerPaused.rawValue)
    case .buffering:
      event.type = Int32(libvlc_MediaPlayerBuffering.rawValue)
      event.u.media_player_buffering.new_cache = 50
    case .seekable:
      event.type = Int32(libvlc_MediaPlayerSeekableChanged.rawValue)
      event.u.media_player_seekable_changed.new_seekable = 1
    case .vout:
      event.type = Int32(libvlc_MediaPlayerVout.rawValue)
      event.u.media_player_vout.new_count = 2
    }
    return event
  }

  func matches(_ event: PlayerEvent) -> Bool {
    switch (self, event) {
    case (.opening, .stateChanged(.opening)),
         (.playing, .stateChanged(.playing)),
         (.paused, .stateChanged(.paused)),
         (.buffering, .bufferingProgress),
         (.seekable, .seekableChanged(true)),
         (.vout, .voutChanged(2)):
      true
    default:
      false
    }
  }
}

private enum StopQuarantinedCallback: CaseIterable, Sendable {
  case opening
  case playing
  case paused
  case buffering

  var event: libvlc_event_t {
    switch self {
    case .opening: FrozenNonterminalCallback.opening.event
    case .playing: FrozenNonterminalCallback.playing.event
    case .paused: FrozenNonterminalCallback.paused.event
    case .buffering: FrozenNonterminalCallback.buffering.event
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct PlayerLifecycleCallbackOrderingTests {
    @Test(arguments: FrozenNonterminalCallback.allCases)
    fileprivate func `Every nonterminal callback keeps its callback-entry generation`(
      callbackKind: FrozenNonterminalCallback
    )
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.twosecURL)
      let successor = try Media(url: TestMedia.testMP4URL)
      let outgoingGeneration = bridge.synchronizePlaybackGeneration(
        1,
        media: first.pointer
      )
      let sourcedStream = bridge.makeSourcedStream(policy: .unbounded)
      let sourcedCallback = Task.detached { () -> SourcedPlayerEvent? in
        for await sourced in sourcedStream where callbackKind.matches(sourced.event) {
          return sourced
        }
        return nil
      }
      defer { sourcedCallback.cancel() }

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackEntryHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        bridge._setNativeEventCallbackEntryHookForTesting(nil)
      }

      let callback = Task.detached {
        bridge._emitNativeEventForTesting(callbackKind.event)
      }
      try #require(await waitForLifecycleSemaphore(entered))

      let successorGeneration = bridge.synchronizePlaybackGeneration(
        outgoingGeneration + 1,
        media: successor.pointer
      )
      release.signal()
      await callback.value
      bridge._setNativeEventCallbackEntryHookForTesting(nil)

      let sourced = try #require(await sourcedCallback.value)
      #expect(sourced.playbackGeneration == outgoingGeneration)
      #expect(sourced.lifecycleControlEpoch != bridge.currentLifecycleControlEpoch)

      // Opening/Playing used to clear this pending wrapper echo after the
      // successor had already been installed. A real echo then looked external
      // and advanced the generation a second time.
      let echoStream = bridge.makeSourcedStream(policy: .unbounded)
      let echo = Task.detached { () -> SourcedPlayerEvent? in
        for await sourced in echoStream {
          if case .mediaChanged = sourced.event {
            return sourced
          }
        }
        return nil
      }
      defer { echo.cancel() }
      bridge._emitNativeEventForTesting(mediaChangedEvent(successor.pointer))
      let sourcedEcho = try #require(await echo.value)
      #expect(sourcedEcho.playbackGeneration == successorGeneration)
      #expect(bridge.currentPlaybackGeneration == successorGeneration)
    }

    @Test
    func `MediaChanged classification is immutable across a later wrapper load`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.twosecURL)
      let external = try Media(url: TestMedia.testMP4URL)
      let wrapperSuccessor = try Media(url: TestMedia.silenceURL)
      let firstGeneration = bridge.synchronizePlaybackGeneration(1, media: first.pointer)
      let sourcedStream = bridge.makeSourcedStream(policy: .unbounded)
      let mediaEvents = Task.detached { () -> [SourcedPlayerEvent] in
        var values: [SourcedPlayerEvent] = []
        for await sourced in sourcedStream {
          guard case .mediaChanged = sourced.event else { continue }
          values.append(sourced)
          if values.count == 2 {
            return values
          }
        }
        return values
      }
      defer { mediaEvents.cancel() }
      let outcomeStream = bridge.makeTerminalOutcomeStream()
      let outcomes = Task.detached { () -> [PlaybackTerminalOutcome] in
        var values: [PlaybackTerminalOutcome] = []
        for await outcome in outcomeStream {
          values.append(outcome)
          if values.count == 2 {
            return values
          }
        }
        return values
      }
      defer { outcomes.cancel() }

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackEntryHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        bridge._setNativeEventCallbackEntryHookForTesting(nil)
      }

      let externalAddress = UInt(bitPattern: external.pointer)
      let callback = Task.detached {
        bridge._emitNativeEventForTesting(
          mediaChangedEvent(OpaquePointer(bitPattern: externalAddress))
        )
      }
      try #require(await waitForLifecycleSemaphore(entered))
      let externallyAdoptedGeneration = bridge.currentPlaybackGeneration
      #expect(externallyAdoptedGeneration == firstGeneration + 1)

      let wrapperGeneration = bridge.synchronizePlaybackGeneration(
        externallyAdoptedGeneration + 1,
        media: wrapperSuccessor.pointer
      )
      release.signal()
      await callback.value
      bridge._setNativeEventCallbackEntryHookForTesting(nil)
      bridge._emitNativeEventForTesting(mediaChangedEvent(wrapperSuccessor.pointer))

      let sourced = await mediaEvents.value
      expectNoDifference(
        sourced.map(\.playbackGeneration),
        [externallyAdoptedGeneration, wrapperGeneration]
      )
      #expect(bridge.currentPlaybackGeneration == wrapperGeneration)
      let terminal = await outcomes.value
      expectNoDifference(
        terminal.map(\.generation),
        [PlaybackGeneration(firstGeneration), PlaybackGeneration(externallyAdoptedGeneration)]
      )
    }

    @Test
    func `External media adoption publishes the outgoing stopped boundary before successor progress`()
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.eventTask?.cancel()
      player.eventTask = nil
      let bridge = player.eventBridge
      let first = try Media(url: TestMedia.twosecURL)
      let successor = try Media(url: TestMedia.testMP4URL)
      player.load(first)
      let outgoingGeneration = player.sessionGeneration
      let outgoingLifecycleEpoch = bridge.currentLifecycleControlEpoch
      let transitions = player.stateTransitions
      var iterator = transitions.makeAsyncIterator()

      player._handleEventForTesting(.stateChanged(.stopping))
      libvlc_media_player_set_media(player.pointer, successor.pointer)
      try #require(
        await poll(timeout: .seconds(1)) {
          bridge.currentPlaybackGeneration > outgoingGeneration
        },
        "the native MediaChanged callback did not reserve the successor"
      )
      let successorGeneration = bridge.currentPlaybackGeneration
      let successorLifecycleEpoch = bridge.currentLifecycleControlEpoch

      player.handleSourcedEvent(
        SourcedPlayerEvent(
          nativeHandleGeneration: bridge.currentNativeHandleGeneration,
          playbackGeneration: successorGeneration,
          event: .mediaChanged,
          lifecycleControlEpoch: successorLifecycleEpoch
        )
      )
      player.handleSourcedEvent(
        SourcedPlayerEvent(
          nativeHandleGeneration: bridge.currentNativeHandleGeneration,
          playbackGeneration: successorGeneration,
          event: .stateChanged(.opening),
          lifecycleControlEpoch: successorLifecycleEpoch
        )
      )
      player.handleSourcedEvent(
        SourcedPlayerEvent(
          nativeHandleGeneration: bridge.currentNativeHandleGeneration,
          playbackGeneration: outgoingGeneration,
          event: .stateChanged(.stopped),
          lifecycleControlEpoch: outgoingLifecycleEpoch
        )
      )
      player.handleSourcedEvent(
        SourcedPlayerEvent(
          nativeHandleGeneration: bridge.currentNativeHandleGeneration,
          playbackGeneration: successorGeneration,
          event: .stateChanged(.playing),
          lifecycleControlEpoch: successorLifecycleEpoch
        )
      )

      var observed: [PlayerState] = []
      for _ in 0..<4 {
        try observed.append(#require(await iterator.next()))
      }
      expectNoDifference(observed, [.stopping, .stopped, .opening, .playing])
      #expect(player.generation == PlaybackGeneration(successorGeneration))
      #expect(player.currentMedia?.mrl == successor.mrl)
      #expect(player.state == .playing)
    }

    @Test(arguments: StopQuarantinedCallback.allCases)
    fileprivate func `Stop quarantines active callbacks on both sides of its native call`(
      callbackKind: StopQuarantinedCallback
    )
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .idle,
        nativeState: .idle,
        isPlaybackRequestedActive: true
      )
      let bridge = player.eventBridge
      let transitions = player.stateTransitions
      let observedStates = Task { @MainActor in
        var states: [PlayerState] = []
        for await state in transitions {
          states.append(state)
          if state == .error {
            return states
          }
        }
        return states
      }
      defer { observedStates.cancel() }

      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      bridge._setNativeEventCallbackEntryHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        bridge._setNativeEventCallbackEntryHookForTesting(nil)
      }
      let preStopCallback = Task.detached {
        bridge._emitNativeEventForTesting(callbackKind.event)
      }
      try #require(await waitForLifecycleSemaphore(entered))

      player.stop()
      #expect(!player.isPlaybackRequestedActive)
      release.signal()
      await preStopCallback.value
      bridge._setNativeEventCallbackEntryHookForTesting(nil)

      // This callback enters after Stop and therefore carries the Stop epoch;
      // the generation-scoped latch, rather than the epoch comparison, must
      // reject it.
      bridge._emitNativeEventForTesting(callbackKind.event)
      bridge._broadcastForTesting(
        .encounteredError,
        nativeHandleGeneration: bridge.currentNativeHandleGeneration,
        playbackGeneration: bridge.currentPlaybackGeneration,
        lifecycleControlEpoch: bridge.currentLifecycleControlEpoch
      )

      let states = await observedStates.value
      #expect(!states.contains(.opening))
      #expect(!states.contains(.buffering))
      #expect(!states.contains(.playing))
      #expect(!states.contains(.paused))
      #expect(player.state == .error)
      #expect(!player.isPlaybackRequestedActive)

      // An accepted Play is a newer control boundary on this same generation.
      player._nativePlaybackStateOverrideForTesting = .idle
      player._nativePlayOverrideForTesting = { 0 }
      try player.play()
      #expect(player.isPlaybackRequestedActive)
      bridge._emitNativeEventForTesting(FrozenNonterminalCallback.playing.event)
      try #require(
        await poll(timeout: .seconds(1), until: { player.state == .playing }),
        "a callback after accepted Play remained quarantined"
      )
      #expect(player.isPlaybackRequestedActive)
    }

    @Test
    func `Rejected Play restores Stop quarantine while accepted Play owns synchronous callbacks`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let bridge = player.eventBridge
      player._setStateForTesting(state: .idle, nativeState: .idle)
      player.clearPlaybackControlForExternalStop()
      #expect(bridge.hasExplicitStopBarrier(playbackGeneration: player.sessionGeneration))

      player._nativePlayOverrideForTesting = {
        bridge._emitNativeEventForTesting(FrozenNonterminalCallback.playing.event)
        return -1
      }
      #expect(throws: VLCError.self) {
        try player.play()
      }
      for _ in 0..<10 {
        await Task.yield()
      }
      #expect(player.state == .idle)
      #expect(!player.isPlaybackRequestedActive)
      #expect(bridge.hasExplicitStopBarrier(playbackGeneration: player.sessionGeneration))

      player._nativePlayOverrideForTesting = {
        bridge._emitNativeEventForTesting(FrozenNonterminalCallback.playing.event)
        return 0
      }
      try player.play()
      try #require(
        await poll(timeout: .seconds(1), until: { player.state == .playing }),
        "the callback emitted synchronously by accepted Play was rejected"
      )
      #expect(player.isPlaybackRequestedActive)
      #expect(!bridge.hasExplicitStopBarrier(playbackGeneration: player.sessionGeneration))
    }

    @Test
    func `Stop retries after a synchronously rejected Play from intent observation`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativePlaybackStateOverrideForTesting = .playing
      var stopDispatchCount = 0
      var rejectedPlayError: VLCError?
      var observerRan = false
      player._nativeStopOverrideForTesting = {
        stopDispatchCount += 1
      }
      player._nativePlayOverrideForTesting = { -1 }

      withObservationTracking {
        _ = player.isPlaybackRequestedActive
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          do {
            try player.play()
          } catch let error as VLCError {
            rejectedPlayError = error
          } catch {
            Issue.record("Unexpected rejected Play error: \(error)")
          }
        }
      }

      player.stop()

      #expect(observerRan)
      #expect(rejectedPlayError != nil)
      #expect(stopDispatchCount == 1)
      #expect(!player.isPlaybackRequestedActive)
      #expect(
        player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: player.sessionGeneration
        )
      )
    }

    @Test
    func `Synchronously accepted Play from intent observation supersedes Stop`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativePlaybackStateOverrideForTesting = .playing
      var stopDispatchCount = 0
      var observerRan = false
      var acceptedPlayError: VLCError?
      player._nativeStopOverrideForTesting = {
        stopDispatchCount += 1
      }
      player._nativePlayOverrideForTesting = { 0 }

      withObservationTracking {
        _ = player.isPlaybackRequestedActive
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          do {
            try player.play()
          } catch let error as VLCError {
            acceptedPlayError = error
          } catch {
            Issue.record("Unexpected accepted Play error: \(error)")
          }
        }
      }

      player.stop()

      #expect(observerRan)
      #expect(acceptedPlayError == nil)
      #expect(stopDispatchCount == 0)
      #expect(player.isPlaybackRequestedActive)
      #expect(
        !player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: player.sessionGeneration
        )
      )
    }

    @Test
    func `Terminal callback entry invalidates external intent restoration inside observation`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: false
      )
      let lease = try #require(
        player.makeExternalPlaybackIntentRestorationLease()
      )
      var observerRan = false

      withObservationTracking {
        _ = player.isPlaybackRequestedActive
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          var mediaStopping = libvlc_event_t()
          mediaStopping.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
          mediaStopping.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
          player.eventBridge._emitNativeEventForTesting(mediaStopping)
          #expect(
            player.state == .playing,
            "the terminal callback must still be queued on the event consumer"
          )
        }
      }

      let restored = player.restorePlaybackIntentFromExternalControl(
        true,
        ifCurrent: lease
      )

      #expect(observerRan)
      #expect(!restored)
      #expect(!player.isPlaybackRequestedActive)
      #expect(!player.ownsExternalPlaybackIntentRestoration(lease))
    }
  }
}

private func mediaChangedEvent(_ media: OpaquePointer?) -> libvlc_event_t {
  var event = libvlc_event_t()
  event.type = Int32(libvlc_MediaPlayerMediaChanged.rawValue)
  event.u.media_player_media_changed.new_media = media
  return event
}

private func waitForLifecycleSemaphore(_ semaphore: DispatchSemaphore) async -> Bool {
  await withCheckedContinuation { continuation in
    DispatchQueue.global(qos: .userInitiated).async {
      continuation.resume(returning: semaphore.wait(timeout: .now() + 5) == .success)
    }
  }
}
