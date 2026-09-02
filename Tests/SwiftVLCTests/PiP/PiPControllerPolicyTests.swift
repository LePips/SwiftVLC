#if os(iOS) || os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AVFoundation
import AVKit
import Dispatch
import Synchronization
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPControllerPolicyTests {
    @Test
    func `delegate state queries are safe off the main thread`() async {
      guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      let contentSource = AVPictureInPictureController.ContentSource(
        sampleBufferDisplayLayer: controller.layer,
        playbackDelegate: controller._playbackDelegateForTesting
      )
      let pip = AVPictureInPictureController(contentSource: contentSource)

      // `AVPictureInPictureController` isn't `Sendable`, but
      // `PiPController._isPlaybackPausedForTesting` is `nonisolated` and
      // documented as safe to call off the main thread. Wrap both refs
      // in an `@unchecked Sendable` box so they can be captured by the
      // background closure without pointer-to-Int round-trips. ARC keeps
      // both alive until the box (and the closure) goes out of scope.
      struct Refs: @unchecked Sendable {
        let controller: PiPController
        let pip: AVPictureInPictureController
      }
      let refs = Refs(controller: controller, pip: pip)

      let paused = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
        DispatchQueue.global().async {
          continuation.resume(returning: refs.controller._isPlaybackPausedForTesting(refs.pip))
        }
      }

      #expect(paused == true)
    }

    @Test(.enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)"))
    func `transient PiP pause then play does not send native pause or resume`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      defer { player.stop() }

      let recorder = PiPControllerTests.PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      controller._setPlayingForTesting(false)
      controller._setPlayingForTesting(true)
      try? await Task.sleep(for: .milliseconds(80))

      #expect(recorder.pauseCount == 0)
      #expect(recorder.resumeCount == 0)
      #expect(recorder.cancelPendingPauseCount == 1)
    }

    @Test(.enabled(if: TestCondition.canPlayMedia, "Requires video output (skipped on CI)"))
    func `PiP skip cancels pending pause and suppresses redundant resume`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(await poll(until: { player.state == .playing }), "Waiting for: player.state == .playing")
      defer { player.stop() }

      let recorder = PiPControllerTests.PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(20)
      )

      controller._setPlayingForTesting(false)
      await controller._skipByIntervalForTesting(CMTime(seconds: 1, preferredTimescale: 1000))
      controller._setPlayingForTesting(true)
      try? await Task.sleep(for: .milliseconds(80))

      #expect(recorder.pauseCount == 0)
      #expect(recorder.resumeCount == 0)
      #expect(recorder.cancelPendingPauseCount == 1)
      #expect(recorder.skipIntervals.count == 1)
    }

    @Test
    func `public init defaults both policy knobs to true`() {
      let player = Player(instance: TestInstance.shared)
      let controller = PiPController(player: player)
      #expect(controller.startsAutomaticallyFromInline == true)
      #expect(controller.managesAudioSession == true)
    }

    @Test
    func `internal init stores both policy knobs and does not crash`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PiPControllerTests.PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        startsAutomaticallyFromInline: false,
        managesAudioSession: false
      )
      #expect(controller.startsAutomaticallyFromInline == false)
      #expect(controller.managesAudioSession == false)
      controller.start()
      controller.stop()
    }

    @Test
    func `audio session activation retries after failure and is idempotent after success`() {
      enum ActivationError: Error {
        case rejected
      }

      let player = Player(instance: TestInstance.shared)
      let recorder = PiPControllerTests.PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        managesAudioSession: true
      )
      var activationAttempts = 0
      let activate: () throws -> Void = {
        activationAttempts += 1
        if activationAttempts == 1 {
          throw ActivationError.rejected
        }
      }

      controller.activateAudioSessionIfNeeded(using: activate)
      #expect(activationAttempts == 1)
      #expect(controller.hasActivatedAudioSession == false)

      controller.activateAudioSessionIfNeeded(using: activate)
      #expect(activationAttempts == 2)
      #expect(controller.hasActivatedAudioSession == true)

      controller.activateAudioSessionIfNeeded(using: activate)
      #expect(activationAttempts == 2)
      #expect(controller.hasActivatedAudioSession == true)
    }

    #if os(iOS)
    /// A start request cannot open PiP without loaded media and therefore
    /// must not activate the shared audio session or take audio focus.
    @Test
    func `start without media does not activate the audio session`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PiPControllerTests.PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        managesAudioSession: true
      )

      #expect(player.currentMedia == nil)
      #expect(controller.hasActivatedAudioSession == false)

      controller.start()

      #expect(controller.hasActivatedAudioSession == false)
    }

    /// With `managesAudioSession: false` neither init nor `start()` may
    /// touch the shared audio session — category and activation both
    /// stay exactly as they were.
    @Test
    func `managesAudioSession false leaves the audio session untouched`() {
      let session = AVAudioSession.sharedInstance()
      let categoryBefore = session.category
      let modeBefore = session.mode

      let player = Player(instance: TestInstance.shared)
      let recorder = PiPControllerTests.PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        managesAudioSession: false
      )
      controller.start()

      #expect(session.category == categoryBefore)
      #expect(session.mode == modeBefore)
      #expect(controller.hasActivatedAudioSession == false)
    }

    /// With `managesAudioSession: true`, both configuration and activation are
    /// deferred into one native broker lease: constructing the controller
    /// neither changes category nor grabs focus. A viable start performs the
    /// atomic acquisition; generic/simulator destinations may have no PiP
    /// controller to receive it.
    @Test
    func `managed audio configuration and activation wait for a viable start`() throws {
      let session = AVAudioSession.sharedInstance()
      let categoryBefore = session.category
      let modeBefore = session.mode
      let player = Player(instance: TestInstance.shared)
      try player.load(Media(url: TestMedia.twosecURL))
      let recorder = PiPControllerTests.PlaybackRecorder()
      let controller = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        managesAudioSession: true
      )

      #expect(session.category == categoryBefore)
      #expect(session.mode == modeBefore)
      #expect(controller.hasActivatedAudioSession == false)

      let hasViableBackend = controller.pipController != nil
      controller.start()
      #expect(controller.hasActivatedAudioSession == hasViableBackend)
      if hasViableBackend {
        #expect(session.category == .playback)
        #expect(session.mode == .moviePlayback)
      }
    }

    @Test
    func `constructing a direct controller during active intent does not activate audio session`() {
      let player = Player(instance: TestInstance.shared)
      player.setPlaybackIntentFromExternalControl(true)

      let controller = PiPController(
        player: player,
        playbackDriver: PiPControllerTests.PlaybackRecorder().driver,
        pauseDebounce: .milliseconds(250),
        managesAudioSession: true
      )

      #expect(player.isPlaybackRequestedActive)
      #expect(controller.hasActivatedAudioSession == false)
    }

    /// The sample-buffer path mirrors the knob onto AVKit's
    /// `canStartPictureInPictureAutomaticallyFromInline`. The AVKit
    /// controller only exists where PiP is supported, so assert through
    /// it conditionally.
    @Test
    func `startsAutomaticallyFromInline reaches the AVKit controller`() {
      let player = Player(instance: TestInstance.shared)
      let recorder = PiPControllerTests.PlaybackRecorder()

      let disabled = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        startsAutomaticallyFromInline: false
      )
      if let avController = disabled.pipController {
        #expect(avController.canStartPictureInPictureAutomaticallyFromInline == false)
      }

      let enabled = PiPController(
        player: player,
        playbackDriver: recorder.driver,
        pauseDebounce: .milliseconds(250),
        startsAutomaticallyFromInline: true
      )
      if let avController = enabled.pipController {
        #expect(avController.canStartPictureInPictureAutomaticallyFromInline == true)
      }
    }
    #endif

    /// `allowsPrivateMacOSAPI` is a simple atomic-backed property; the
    /// only contract is that reads see the most recent write. The flag
    /// defaults to `false` and roundtrips through `true` and back.
    @Test func `allowsPrivateMacOSAPI defaults to false and roundtrips`() {
      // Remember the entry value so the rest of the suite isn't
      // affected by this test's writes.
      let initial = PiPController.allowsPrivateMacOSAPI
      defer { PiPController.allowsPrivateMacOSAPI = initial }

      #expect(PiPController.allowsPrivateMacOSAPI == false)

      PiPController.allowsPrivateMacOSAPI = true
      #expect(PiPController.allowsPrivateMacOSAPI == true)

      PiPController.allowsPrivateMacOSAPI = false
      #expect(PiPController.allowsPrivateMacOSAPI == false)
    }
  }
}
#endif
