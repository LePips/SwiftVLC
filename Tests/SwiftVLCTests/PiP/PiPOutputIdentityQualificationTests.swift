#if os(iOS)
@_spi(Qualification) @testable import SwiftVLC
import CLibVLC
import Foundation
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPOutputIdentityQualificationTests {
    @Test
    func `qualification SPI exposes only the exact ready native output`() throws {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let pip = PiPController(player: player, nativeBackend: backend)
      let nativeController = NSObject()
      #expect(player.eventBridge.synchronizePlaybackGeneration(17, media: nil) == 17)
      player.sessionGeneration = 17
      let output = IOSNativePiPOutputIdentity(
        nativeHandle: player.nativeHandleLifetime.nativePiPHandleIdentity,
        playbackGeneration: PlaybackGeneration(17),
        output: 23
      )

      #expect(pip.nativeOutputIdentityQualificationSnapshot == nil)
      let takeOutcome = backend.continuityCoordinator
        .takePreservedControllerOutcome(for: output)
      let didAuthorizeFresh = if case .createFresh = takeOutcome {
        true
      } else {
        false
      }
      #expect(didAuthorizeFresh)
      #expect(backend.continuityCoordinator.didClaimFreshController(
        nativeController,
        output: output
      ))
      #expect(pip.nativeOutputIdentityQualificationSnapshot == nil)
      #expect(backend.continuityCoordinator.didBecomeReady(
        nativeController,
        output: output
      ))

      let snapshot = try #require(pip.nativeOutputIdentityQualificationSnapshot)
      #expect(
        snapshot.nativeHandleIdentity == player.nativeHandleLifetime.nativePiPHandleIdentity
      )
      #expect(snapshot.playbackGeneration == 17)
      #expect(snapshot.outputIdentity == 23)

      backend.continuityCoordinator.didCancel(nativeController, output: output)
      #expect(pip.nativeOutputIdentityQualificationSnapshot == nil)
    }

    @Test
    func `qualification SPI rejects a ready output from another native handle`() {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let pip = PiPController(player: player, nativeBackend: backend)
      let nativeController = NSObject()
      #expect(player.eventBridge.synchronizePlaybackGeneration(17, media: nil) == 17)
      player.sessionGeneration = 17
      let output = IOSNativePiPOutputIdentity(
        nativeHandle: player.nativeHandleLifetime.nativePiPHandleIdentity &+ 1,
        playbackGeneration: PlaybackGeneration(17),
        output: 23
      )

      let takeOutcome = backend.continuityCoordinator
        .takePreservedControllerOutcome(for: output)
      let didAuthorizeFresh = if case .createFresh = takeOutcome {
        true
      } else {
        false
      }
      #expect(didAuthorizeFresh)
      #expect(backend.continuityCoordinator.didClaimFreshController(
        nativeController,
        output: output
      ))
      #expect(backend.continuityCoordinator.didBecomeReady(
        nativeController,
        output: output
      ))
      #expect(pip.nativeOutputIdentityQualificationSnapshot == nil)
    }

    @Test
    func `qualification SPI rejects a ready output from another playback generation`() {
      let player = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      let pip = PiPController(player: player, nativeBackend: backend)
      let nativeController = NSObject()
      #expect(player.eventBridge.synchronizePlaybackGeneration(18, media: nil) == 18)
      player.sessionGeneration = 18
      let output = IOSNativePiPOutputIdentity(
        nativeHandle: player.nativeHandleLifetime.nativePiPHandleIdentity,
        playbackGeneration: PlaybackGeneration(17),
        output: 23
      )

      let takeOutcome = backend.continuityCoordinator
        .takePreservedControllerOutcome(for: output)
      let didAuthorizeFresh = if case .createFresh = takeOutcome {
        true
      } else {
        false
      }
      #expect(didAuthorizeFresh)
      #expect(backend.continuityCoordinator.didClaimFreshController(
        nativeController,
        output: output
      ))
      #expect(backend.continuityCoordinator.didBecomeReady(
        nativeController,
        output: output
      ))
      #expect(pip.nativeOutputIdentityQualificationSnapshot == nil)
    }

    @Test
    func `qualification SPI rejects ready output after EventBridge advances ahead of Player`() throws {
      let player = Player(instance: TestInstance.shared)
      player.eventTask?.cancel()
      let backend = IOSNativePiPBackend()
      let pip = PiPController(player: player, nativeBackend: backend)
      let nativeController = NSObject()
      let first = try Media(url: TestMedia.silenceURL)
      let successor = try Media(url: TestMedia.twosecURL)
      #expect(
        player.eventBridge.synchronizePlaybackGeneration(17, media: first.pointer) == 17
      )
      player.sessionGeneration = 17
      let output = IOSNativePiPOutputIdentity(
        nativeHandle: player.nativeHandleLifetime.nativePiPHandleIdentity,
        playbackGeneration: PlaybackGeneration(17),
        output: 23
      )

      let takeOutcome = backend.continuityCoordinator
        .takePreservedControllerOutcome(for: output)
      let didAuthorizeFresh = if case .createFresh = takeOutcome {
        true
      } else {
        false
      }
      #expect(didAuthorizeFresh)
      #expect(backend.continuityCoordinator.didClaimFreshController(
        nativeController,
        output: output
      ))
      #expect(backend.continuityCoordinator.didBecomeReady(
        nativeController,
        output: output
      ))
      #expect(pip.nativeOutputIdentityQualificationSnapshot != nil)

      var mediaChanged = libvlc_event_t()
      mediaChanged.type = Int32(libvlc_MediaPlayerMediaChanged.rawValue)
      mediaChanged.u.media_player_media_changed.new_media = successor.pointer
      player.eventBridge._emitNativeEventForTesting(mediaChanged)

      #expect(player.sessionGeneration == 17)
      #expect(player.eventBridge.currentPlaybackGeneration == 18)
      #expect(pip.nativeOutputIdentityQualificationSnapshot == nil)
    }
  }
}
#endif
