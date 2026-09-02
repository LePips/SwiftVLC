#if os(iOS) || os(macOS)
@testable import SwiftVLC
import SwiftUI
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPInitializerCompatibilityTests {
    @Test
    @available(*, deprecated, message: "Exercises the pre-1.1 compatibility initializer")
    func `Current and legacy initializer references stay callable`() {
      let player = Player(instance: TestInstance.shared)
      let currentInitializer:
        (Player, Binding<PiPController?>?, Bool) -> PiPVideoView =
        PiPVideoView.init(_:controller:startsAutomaticallyFromInline:)
      let legacyInitializer:
        (Player, Binding<PiPController?>?, Bool, Bool) -> PiPVideoView =
        PiPVideoView.init(
          _:controller:startsAutomaticallyFromInline:managesAudioSession:
        )

      _ = currentInitializer(player, nil, false)
      _ = legacyInitializer(player, nil, false, false)
      _ = legacyInitializer(player, nil, true, true)
    }
  }
}
#endif
