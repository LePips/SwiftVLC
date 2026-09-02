@testable import SwiftVLC
import CLibVLC
import Observation
import Synchronization
import Testing

extension Logic {
  struct PlaybackRateEventContractTests {
    @Test
    func `Native rate payload maps without wrapper-range clamping`() {
      var event = libvlc_event_t()
      event.type = Int32(libvlc_MediaPlayerRateChanged.rawValue)
      event.u.media_player_rate_changed.new_rate = 8

      #expect(mapEffectivePlaybackRateResolution(event) == 8)
      if case .some(let mapped) = mapEvent(event) {
        Issue.record("Rate unexpectedly entered PlayerEvent as \(mapped)")
      }
    }

    @Test
    func `Runtime gate is the only difference in native event attachment`() {
      let legacy = EventBridge.makePlayerEventTypes(
        effectiveRateChangedEventAvailable: false
      )
      let extended = EventBridge.makePlayerEventTypes(
        effectiveRateChangedEventAvailable: true
      )
      let rateType = Int32(libvlc_MediaPlayerRateChanged.rawValue)

      #expect(!legacy.contains(rateType))
      #expect(extended.last == rateType)
      #expect(extended.dropLast() == legacy[...])
      #expect(extended.count == legacy.count + 1)
    }

    @Test
    func `Public availability matches the weak-link native version gate`() {
      #expect(
        Player.supportsEffectivePlaybackRateEvents
          == swiftvlc_media_player_rate_changed_event_available()
      )
      #expect(
        EventBridge.playerEventTypes.contains(
          Int32(libvlc_MediaPlayerRateChanged.rawValue)
        ) == Player.supportsEffectivePlaybackRateEvents
      )
    }
  }
}

extension Integration {
  @MainActor struct PlaybackRateEventStreamTests {
    @Test(.timeLimit(.minutes(1)))
    func `Native callback publishes exact rate and provenance`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let nativeGeneration = bridge.currentNativeHandleGeneration
      let playbackGeneration = bridge.currentPlaybackGeneration
      let stream = player.effectivePlaybackRateResolutions
      var iterator = stream.makeAsyncIterator()

      var event = libvlc_event_t()
      event.type = Int32(libvlc_MediaPlayerRateChanged.rawValue)
      event.u.media_player_rate_changed.new_rate = 8
      bridge._emitNativeEventForTesting(event)

      let resolution = try #require(await iterator.next())
      #expect(resolution.effectiveRate == 8)
      #expect(resolution.nativeGeneration == NativePlayerGeneration(nativeGeneration))
      #expect(resolution.playbackGeneration == PlaybackGeneration(playbackGeneration))
    }

    @Test(.timeLimit(.minutes(1)))
    func `Unified mirror lane adopts media before following rate resolution`() async throws {
      let player = Player(instance: TestInstance.shared)
      player.eventTask?.cancel()
      await player.eventTask?.value

      let bridge = player.eventBridge
      let stream = bridge.makeSourcedPlayerSignalStream(policy: .unbounded)
      var iterator = stream.makeAsyncIterator()
      let nativeGeneration = bridge.currentNativeHandleGeneration
      let successorValue = bridge.synchronizePlaybackGeneration(
        player.sessionGeneration &+ 1,
        media: nil
      )
      let successor = PlaybackGeneration(successorValue)

      bridge._broadcastForTesting(
        .mediaChanged,
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: successorValue
      )
      bridge._broadcastEffectivePlaybackRateResolutionForTesting(
        1.5,
        nativeHandleGeneration: nativeGeneration,
        playbackGeneration: successorValue
      )

      let first = try #require(await iterator.next())
      guard
        case .event(let sourcedMediaChange) = first,
        case .mediaChanged = sourcedMediaChange.event
      else {
        Issue.record("MediaChanged was not first on the unified mirror lane")
        return
      }
      #expect(sourcedMediaChange.playbackGeneration == successorValue)
      player.handleSourcedPlayerSignal(first)
      #expect(player.generation == successor)

      let rateInvalidated = Mutex(false)
      withObservationTracking {
        _ = player.rate
      } onChange: {
        rateInvalidated.withLock { $0 = true }
      }

      let second = try #require(await iterator.next())
      guard case .effectivePlaybackRateResolution(let resolution) = second else {
        Issue.record("Effective rate did not follow MediaChanged on the unified mirror lane")
        return
      }
      #expect(resolution.playbackGeneration == successor)
      player.handleSourcedPlayerSignal(second)

      #expect(player.generation == successor)
      #expect(rateInvalidated.withLock { $0 })
    }

    @Test(.timeLimit(.minutes(1)))
    func `Rapid effective changes remain ordered without implying request IDs`() async throws {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let nativeGeneration = bridge.currentNativeHandleGeneration
      let stream = player.effectivePlaybackRateResolutions
      var iterator = stream.makeAsyncIterator()
      let expected: [Float] = [0.5, 2, 1.25, 1]

      for rate in expected {
        bridge._broadcastEffectivePlaybackRateResolutionForTesting(
          rate,
          nativeHandleGeneration: nativeGeneration
        )
      }

      var received: [EffectivePlaybackRateResolution] = []
      for _ in expected {
        try received.append(#require(await iterator.next()))
      }

      #expect(received.map(\.effectiveRate) == expected)
      #expect(received.allSatisfy {
        $0.nativeGeneration == NativePlayerGeneration(nativeGeneration)
      })
      #expect(received.allSatisfy {
        $0.playbackGeneration == PlaybackGeneration(bridge.currentPlaybackGeneration)
      })
    }
  }
}
