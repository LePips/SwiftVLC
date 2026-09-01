@testable import SwiftVLC
import CustomDump
import Foundation
import Testing

private struct LenientSeekGateMirror: Equatable {
  let jumpAccepted: Bool
  let requestOutcome: SeekOutcome
  let positionAccepted: Bool
  let jumpDispatches: Int
  let positionDispatches: Int
}

/// Exercises the lenient seek surface (`seek(toPosition:fast:)`,
/// `jump(by:)`) alongside the strict seeks' position publication.
///
/// The lenient calls are best-effort wrappers over
/// `libvlc_media_player_set_position` / `libvlc_media_player_jump_time`:
/// idle-player tests assert the `false` no-op path headlessly, while the
/// playback tests (gated on `TestCondition.canPlayMedia`) verify that
/// accepted requests actually move the clock on the dummy-output
/// pipeline. HLS-live acceptance is a demuxer runtime property and is
/// covered by the device harness, not here.
extension Integration {
  @Suite(.tags(.mainActor, .async, .media), .serialized)
  @MainActor struct PlayerLenientSeekTests {
    // MARK: - Idle no-op paths (headless-safe)

    @Test
    func `jump on a player without media returns false and does not crash`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      #expect(player.jump(by: .seconds(-10)) == false)
      #expect(player.state == .idle)
    }

    @Test
    func `seek toPosition on idle player returns false`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      #expect(player.seek(toPosition: PlaybackPosition(0.5)) == false)
      #expect(player.position == 0)
      #expect(player.state == .idle)
    }

    // MARK: - Session gate timing

    @Test
    func `Terminal native state rejects every lenient surface despite active intent`() async {
      for nativeState in [PlayerState.stopped, .stopping, .error] {
        let player = Player(instance: TestInstance.makeAudioOnly())
        player._setStateForTesting(
          state: .playing,
          isPlaybackRequestedActive: true,
          currentTime: .seconds(10)
        )
        player._nativePlaybackStateOverrideForTesting = nativeState
        var jumpDispatches = 0
        var positionDispatches = 0
        player._nativeJumpTimeOverrideForTesting = { _ in
          jumpDispatches += 1
          return 0
        }
        player._nativeSetPositionOverrideForTesting = { _, _ in
          positionDispatches += 1
          return 0
        }

        let jumpAccepted = player.jump(by: .seconds(5))
        let request = player.requestJump(by: .seconds(5))
        let positionAccepted = player.seek(toPosition: PlaybackPosition(0.5))
        let requestOutcome = await request.outcome

        expectNoDifference(
          LenientSeekGateMirror(
            jumpAccepted: jumpAccepted,
            requestOutcome: requestOutcome,
            positionAccepted: positionAccepted,
            jumpDispatches: jumpDispatches,
            positionDispatches: positionDispatches
          ),
          LenientSeekGateMirror(
            jumpAccepted: false,
            requestOutcome: .rejected,
            positionAccepted: false,
            jumpDispatches: 0,
            positionDispatches: 0
          )
        )
      }
    }

    @Test
    func `Idle native state uses active intent fallback`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .idle,
        isPlaybackRequestedActive: true,
        currentTime: .seconds(10)
      )
      var dispatches = 0
      player._nativeJumpTimeOverrideForTesting = { _ in
        dispatches += 1
        return 0
      }

      #expect(player.jump(by: .seconds(5)))
      #expect(dispatches == 1)
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `seek immediately after play succeeds`() throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.twosecURL))
      // Same main-actor turn as play(): the event-fed `state` mirror is
      // still `.idle`. Pin the synchronous native observation to that same
      // ambiguous state: only `.idle` may use active playback intent as its
      // same-turn fallback; terminal native states remain rejected.
      player._nativePlaybackStateOverrideForTesting = .idle
      #expect(player.seek(toPosition: PlaybackPosition(0.1)) == true)
      player.stop()
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `seek after stop returns false`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      player.stop()
      // stop() publishes intent false synchronously, but the native
      // state read is racy in the same turn: libVLC processes
      // stop_async on its own thread and can keep reporting `.playing`
      // for a beat, so asserting the no-op immediately after stop()
      // would race that thread. Assert the documented contract instead:
      // once the stop lands, there is no session and the seek is a
      // rejected no-op.
      try #require(
        await poll(until: { player.state == .stopped }),
        "Waiting for: player.state == .stopped"
      )
      #expect(player.seek(toPosition: PlaybackPosition(0.5)) == false)
    }

    // MARK: - Lenient seeks during real playback

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `seek toPosition lands near half duration`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      try #require(
        await poll(until: { player.duration != nil }),
        "Waiting for: duration is known"
      )

      #expect(player.seek(toPosition: PlaybackPosition(0.5)) == true)

      let halfMs = try #require(player.duration).milliseconds / 2
      try #require(
        await poll(until: { abs(player.currentTime.milliseconds - halfMs) <= 400 }),
        "Waiting for: currentTime within 400ms of half duration"
      )
      #expect(player.position > 0.3)
      player.stop()
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `jump during playback returns true and advances currentTime`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      try #require(
        await poll(until: { player.currentTime > .zero }),
        "Waiting for: currentTime > 0"
      )

      let preJump = player.currentTime
      #expect(player.jump(by: .milliseconds(300)) == true)
      try #require(
        await poll(until: { player.currentTime > preJump }),
        "Waiting for: currentTime past the pre-jump value"
      )
      player.stop()
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `jump rewinds during playback`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.currentTime >= .milliseconds(800) }),
        "Waiting for: currentTime >= 800ms"
      )

      let preJump = player.currentTime
      #expect(player.jump(by: .milliseconds(-500)) == true)
      try #require(
        await poll(until: { player.currentTime < preJump }),
        "Waiting for: currentTime below the pre-jump value"
      )
      player.stop()
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `authoritative jump settles from the post-seek native timer point`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.currentTime >= .milliseconds(800) }),
        "Waiting for: currentTime >= 800ms"
      )

      let preJump = player.currentTime
      let request = player.requestJump(by: .milliseconds(-500))

      #expect(request.initialOutcome == .pending)
      #expect(await request.outcome == .settled)
      #expect(player.currentTime < preJump)
      player.stop()
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `jump publishes currentTime immediately while paused`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )
      player.pause()
      try #require(
        await poll(until: { player.state == .paused }),
        "Waiting for: player.state == .paused"
      )

      let preJump = player.currentTime
      #expect(player.jump(by: .milliseconds(300)) == true)
      // Read immediately: libVLC emits no timeChanged while paused, so
      // the best-effort shadow published by jump(by:) itself is the only
      // thing that can move the clock here.
      #expect(player.currentTime == preJump + .milliseconds(300))
      player.stop()
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `fast and precise strict seeks both land within tolerance`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing && player.isSeekable }),
        "Waiting for: playing and seekable"
      )

      try player.seek(to: .seconds(1), fast: true)
      try #require(
        await poll(until: { abs(player.currentTime.milliseconds - 1000) <= 400 }),
        "Waiting for: fast seek lands within 400ms of 1s"
      )

      try player.seek(to: .seconds(1), fast: false)
      try #require(
        await poll(until: { abs(player.currentTime.milliseconds - 1000) <= 400 }),
        "Waiting for: precise seek lands within 400ms of 1s"
      )
      player.stop()
    }

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `fast seek snaps to the prior keyframe where precise seek lands on target`() async throws {
      // sparse.mp4 has keyframes only at ~0s and ~10s, so a 9s target
      // separates the two modes by ~9 seconds: precise decodes forward
      // from the 0s keyframe and lands on target, fast stops at the
      // keyframe itself.
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(Media(url: TestMedia.sparseURL))
      try #require(
        await poll(timeout: .seconds(10), until: { player.state == .playing && player.isSeekable }),
        "Waiting for: playing and seekable"
      )

      try player.seek(to: .seconds(9), fast: false)
      // seek(to:) publishes the 9000ms shadow synchronously; wait for a
      // native sample past it to observe where the demuxer landed.
      try #require(
        await poll(until: { player.currentTime > .milliseconds(9000) }),
        "Waiting for: native time event after the precise seek"
      )
      let preciseLanding = player.currentTime.milliseconds
      #expect(preciseLanding <= 9600, "precise seek should land within tolerance of 9s")

      try player.seek(to: .seconds(9), fast: true)
      // The discriminating assertion: the native clock must snap back to
      // the prior keyframe region. If the fast flag stops being plumbed
      // through, the seek behaves precisely, time stays at ~9s+, and
      // this poll times out.
      try #require(
        await poll(until: { player.currentTime < .milliseconds(8500) }),
        "Waiting for: fast seek snapping below the 9s target"
      )
      let fastLanding = player.currentTime.milliseconds
      // Observed on the pinned binary: the fast seek resumes from the 0s
      // keyframe (~400ms by the time the first event lands).
      #expect(fastLanding >= 0)
      #expect(fastLanding < 2000, "fast seek should land in the 0s-keyframe region")
      // Fast may be at most as precise as the precise seek.
      #expect(abs(fastLanding - 9000) >= abs(preciseLanding - 9000))
      player.stop()
    }

    // MARK: - Position publication for paused players

    @Test(.enabled(if: TestCondition.canPlayMedia), .timeLimit(.minutes(1)))
    func `strict seek publishes position while paused without waiting for events`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing && player.isSeekable }),
        "Waiting for: playing and seekable"
      )
      try #require(
        await poll(until: { player.duration != nil }),
        "Waiting for: duration is known"
      )

      player.pause()
      try #require(
        await poll(until: { player.state == .paused }),
        "Waiting for: player.state == .paused"
      )

      try player.seek(to: .milliseconds(500))
      // Read immediately: the position shadow must be published by the
      // seek itself, not by a later positionChanged event (libVLC emits
      // none while paused).
      let durationMs = try #require(player.duration).milliseconds
      let expected = Double(500) / Double(durationMs)
      #expect(abs(player.position - expected) < 0.01)
      #expect(abs(player.position - 0.25) < 0.05)
      player.stop()
    }
  }
}
