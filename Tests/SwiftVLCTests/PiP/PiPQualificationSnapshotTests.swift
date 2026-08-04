#if os(iOS)
@_spi(Qualification) @testable import SwiftVLC
import AVKit
import CustomDump
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPQualificationSnapshotTests {
    @Test
    func `qualification snapshot reports the policy applied to native and direct AVKit`() throws {
      let nativePlayer = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      backend.attach(to: nativePlayer)
      let native = PiPController(player: nativePlayer, nativeBackend: backend)
      native.playbackStateObservation = .init(duration: nil, isSeekable: false)

      expectNoDifference(
        native.playbackQualificationSnapshot,
        PiPPlaybackQualificationSnapshot(
          requiresLinearPlayback: true,
          durationMilliseconds: nil,
          isSeekable: false
        )
      )
      #expect(native.nativePlaybackQualificationSnapshot == nil)

      let directPlayer = Player(instance: TestInstance.shared)
      let direct = PiPController(player: directPlayer)
      let avController = try #require(direct.pipController)
      avController.requiresLinearPlayback = false
      direct.playbackStateObservation = .init(duration: .seconds(42), isSeekable: true)

      expectNoDifference(
        direct.playbackQualificationSnapshot,
        PiPPlaybackQualificationSnapshot(
          requiresLinearPlayback: false,
          durationMilliseconds: 42000,
          isSeekable: true
        )
      )
      #expect(direct.nativePlaybackQualificationSnapshot == nil)
    }
  }
}
#endif
