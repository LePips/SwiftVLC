@testable import SwiftVLC
import CLibVLC
import Testing

extension Logic {
  struct PlaybackRateEventContractTests {
    @Test
    func `Native rate payload maps without wrapper-range clamping`() {
      var event = libvlc_event_t()
      event.type = Int32(libvlc_MediaPlayerRateChanged.rawValue)
      event.u.media_player_rate_changed.new_rate = 8

      guard case .rateChanged(let rate) = mapEvent(event) else {
        Issue.record("Expected .rateChanged")
        return
      }
      #expect(rate == 8)
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
    func `Rapid effective changes remain ordered without implying request IDs`() async {
      let player = Player(instance: TestInstance.shared)
      let bridge = player.eventBridge
      let nativeGeneration = bridge.currentNativeHandleGeneration
      let stream = player.controlEvents

      for rate: Float in [0.5, 2, 1.25, 1] {
        bridge._broadcastForTesting(
          .rateChanged(rate),
          nativeHandleGeneration: nativeGeneration
        )
      }
      bridge._broadcastForTesting(
        .mediaChanged,
        nativeHandleGeneration: nativeGeneration
      )

      var rates: [Float] = []
      for await event in stream {
        if case .rateChanged(let rate) = event {
          rates.append(rate)
        } else if case .mediaChanged = event {
          break
        }
      }

      #expect(rates == [0.5, 2, 1.25, 1])
    }
  }
}
