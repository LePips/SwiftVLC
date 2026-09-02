@testable import SwiftVLC
import Foundation
import Testing

/// `stopAndWaitForOutcome()` must report output safety truthfully.
///
/// The whole point of the API is to give callers a moment after which nothing
/// is still draining — it is what you call before
/// `AVAudioSession.setActive(false, …)` or before detaching a drawable. A
/// result that reads as success while an audio output is alive is worse than
/// no result at all, so these tests pin the cases where that could happen:
///
/// - A native error is **not** completion. libVLC emits the error first and
///   the stopped state that actually releases the outputs afterwards, so
///   returning on `.error` would promise safety mid-drain.
/// - Concurrent callers must join one stop and all see the same answer.
/// - Repeated play/stop/detach cycles must stay safe.
extension Integration {
  @Suite(.tags(.mainActor, .async), .timeLimit(.minutes(2)))
  @MainActor struct PlayerStopOutcomeTests {
    @Test
    func `Version 1 stopAndWait remains a Void method reference`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let stopAndWait: () async -> Void = player.stopAndWait

      await stopAndWait()
    }

    /// An idle player has nothing draining, so the result is immediately
    /// output-safe.
    @Test
    func `Idle player reports an output-safe stop`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())

      let outcome = await player.stopAndWaitForOutcome()

      #expect(outcome == .stopped)
      #expect(outcome.isOutputSafe)
    }

    /// An unopenable media drives libVLC to `.error`, and the `.stopped` that
    /// actually releases the outputs only arrives afterwards. This pins the
    /// invariant that falls out of no longer treating `.error` as terminal:
    /// an output-safe answer is never returned while the native handle is
    /// still sitting in error.
    ///
    /// The error is awaited as an *event* rather than polled as a resting
    /// state — libVLC moves through error to stopped faster than any poll
    /// interval reliably catches.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Native error does not report output-safe completion early`() async throws {
      let missingPath = "/nonexistent/swiftvlc-\(UUID().uuidString).mp4"
      let player = Player(instance: TestInstance.makePlayback())
      let events = player.events(policy: .unbounded, filter: nil)

      try player.play(Media(path: missingPath))

      let sawError = Task.detached { @Sendable in
        for await event in events {
          if case .encounteredError = event {
            return true
          }
          if case .stateChanged(.stopped) = event {
            return false
          }
        }
        return false
      }
      // Asserted, not discarded: if the error is never observed the player
      // took some other path and the invariant below would pass vacuously.
      try #require(
        await sawError.value,
        "the unopenable media never reported an error, so the post-error path was not exercised"
      )

      let outcome = await player.stopAndWaitForOutcome()

      // Either the stop landed (the normal case, since `.stopped` follows the
      // error) or we are explicitly told the drain never finished. What must
      // never happen is an output-safe answer while the handle sits in error.
      if outcome.isOutputSafe {
        #expect(
          player.nativePlaybackState != .error,
          "reported output-safe while the native handle was still in error"
        )
      } else {
        #expect(outcome == .failedButStillDraining || outcome == .timedOut)
      }
    }

    /// Concurrent callers join one in-flight stop, so none of them can be
    /// told the outputs are free on the strength of someone else's request.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Concurrent callers receive the same terminal result`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      var callers: [Task<PlayerStopOutcome, Never>] = []
      for _ in 0..<6 {
        callers.append(Task { @MainActor in await player.stopAndWaitForOutcome() })
      }

      var outcomes: [PlayerStopOutcome] = []
      for caller in callers {
        await outcomes.append(caller.value)
      }

      #expect(outcomes.count == 6)
      #expect(
        Set(outcomes).count == 1,
        "concurrent callers disagreed about output safety: \(outcomes)"
      )
      #expect(outcomes.first == .stopped)
    }

    /// A native handle is not a playback episode. Replay on the same pointer
    /// must invalidate the predecessor's waiter, and a later waiter must issue
    /// its own Stop instead of joining the old operation and inheriting its
    /// eventual Stopped callback.
    @Test
    func `Same-handle replay forces a fresh stop episode`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativePlaybackStateOverrideForTesting = .playing
      var nativeStopCount = 0
      player._nativeStopOverrideForTesting = {
        nativeStopCount += 1
      }

      let predecessor = Task { @MainActor in
        await player.stopAndWaitForOutcome()
      }
      try #require(
        await poll(timeout: .seconds(1)) {
          nativeStopCount == 1
            && player.stopAndWaitOperation?.episode.requiresExplicitStopBarrier == true
        },
        "the predecessor Stop was never reserved and dispatched"
      )
      let predecessorEpisode = try #require(
        player.stopAndWaitOperation?.episode
      )

      player._nativePlayOverrideForTesting = { 0 }
      try player.play()
      #expect(player.isPlaybackRequestedActive)

      let successor = Task { @MainActor in
        await player.stopAndWaitForOutcome()
      }
      try #require(
        await poll(timeout: .seconds(1)) {
          nativeStopCount == 2
            && player.stopAndWaitOperation?.episode != predecessorEpisode
        },
        "the successor waiter joined the predecessor Stop"
      )
      let successorEpisode = try #require(
        player.stopAndWaitOperation?.episode
      )

      player.eventBridge._broadcastForTesting(
        .stateChanged(.stopped),
        nativeHandleGeneration: predecessorEpisode.nativeHandleGeneration,
        playbackGeneration: predecessorEpisode.playbackGeneration,
        lifecycleControlEpoch: predecessorEpisode.lifecycleControlEpoch
      )
      #expect(await predecessor.value == .timedOut)
      #expect(
        player.stopAndWaitOperation?.episode == successorEpisode,
        "the stale predecessor task cleared the successor operation"
      )

      player._nativePlaybackStateOverrideForTesting = .stopped
      player.eventBridge._broadcastForTesting(
        .stateChanged(.stopped),
        nativeHandleGeneration: successorEpisode.nativeHandleGeneration,
        playbackGeneration: successorEpisode.playbackGeneration,
        lifecycleControlEpoch: successorEpisode.lifecycleControlEpoch
      )
      #expect(await successor.value == .stopped)
      #expect(nativeStopCount == 2)
    }

    /// Reservation and native dispatch must happen in the caller's
    /// pre-suspension prefix. A Play already queued on the main actor is newer
    /// only after Stop has crossed into native code; delegating reservation to
    /// a child Task reverses that order and lets the older Stop kill playback.
    @Test
    func `Stop reservation precedes an already queued Play`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativePlaybackStateOverrideForTesting = .playing
      var dispatchOrder: [String] = []
      player._nativeStopOverrideForTesting = {
        dispatchOrder.append("stop")
        player._nativePlaybackStateOverrideForTesting = .stopped
        player.eventBridge._broadcastForTesting(
          .stateChanged(.stopped),
          nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration,
          playbackGeneration: player.eventBridge.currentPlaybackGeneration,
          lifecycleControlEpoch: player.eventBridge.currentLifecycleControlEpoch
        )
      }
      player._nativePlayOverrideForTesting = {
        dispatchOrder.append("play")
        player._nativePlaybackStateOverrideForTesting = .playing
        return 0
      }

      let queuedPlay = Task { @MainActor in
        try? player.play()
      }
      let outcome = await player.stopAndWaitForOutcome()
      await queuedPlay.value

      #expect(dispatchOrder == ["stop", "play"])
      #expect(outcome == .timedOut)
      #expect(player.isPlaybackRequestedActive)
    }

    /// A caller whose task is cancelled must still be told the truth. The
    /// drain is deliberately not abandoned, so the reported state stays
    /// accurate rather than becoming indistinguishable from success.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Cancelled caller still receives an accurate result`() async throws {
      let player = Player(instance: TestInstance.makePlayback())
      try player.play(url: TestMedia.twosecURL)
      try #require(
        await poll(until: { player.state == .playing }),
        "Waiting for: player.state == .playing"
      )

      let caller = Task { @MainActor in await player.stopAndWaitForOutcome() }
      caller.cancel()
      let outcome = await caller.value

      #expect(outcome == .stopped)
      #expect(
        player.nativePlaybackState == .stopped,
        "drain was abandoned on cancellation: \(player.nativePlaybackState)"
      )
    }

    // MARK: - Wait logic, driven without live playback

    //
    // CI cannot reach `.playing` (`TestCondition.canPlayMedia`), so the
    // decision logic is exercised directly against a synthetic event stream.
    // These cover the branches the playback tests can only reach on a
    // developer machine.

    /// A stop for the awaited handle ends the wait as output-safe.
    @Test
    func `A stopped event for the awaited generation reports stopped`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(
          nativeHandleGeneration: 7,
          playbackGeneration: 0,
          event: .stateChanged(.stopped)
        )
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        nativeHandleGeneration: 7,
        timeout: .seconds(5)
      )

      #expect(outcome == .stopped)
    }

    /// The core of the fix: an error is not a stop. It must not end the wait,
    /// so a stream carrying only an error times out rather than reporting the
    /// outputs released.
    @Test
    func `An error event alone never reports output-safe`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(
          nativeHandleGeneration: 7,
          playbackGeneration: 0,
          event: .stateChanged(.error)
        )
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        nativeHandleGeneration: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
      #expect(!outcome.isOutputSafe)
    }

    /// An error followed by the stop that actually releases the outputs is
    /// the real libVLC ordering, and must resolve as output-safe.
    @Test
    func `An error followed by a stop reports stopped`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(
          nativeHandleGeneration: 7,
          playbackGeneration: 0,
          event: .stateChanged(.error)
        ),
        SourcedPlayerEvent(
          nativeHandleGeneration: 7,
          playbackGeneration: 0,
          event: .stateChanged(.stopped)
        )
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        nativeHandleGeneration: 7,
        timeout: .seconds(5)
      )

      #expect(outcome == .stopped)
    }

    /// A stop belonging to a different native handle must be ignored: it says
    /// nothing about the handle this caller is waiting on.
    @Test
    func `A stop from another generation is ignored`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(
          nativeHandleGeneration: 99,
          playbackGeneration: 0,
          event: .stateChanged(.stopped)
        )
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        nativeHandleGeneration: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
    }

    /// Non-state events must not be mistaken for a terminal transition.
    @Test
    func `Unrelated events do not end the wait`() async {
      let stream = Self.eventStream([
        SourcedPlayerEvent(
          nativeHandleGeneration: 7,
          playbackGeneration: 0,
          event: .timeChanged(.seconds(1))
        ),
        SourcedPlayerEvent(
          nativeHandleGeneration: 7,
          playbackGeneration: 0,
          event: .stateChanged(.playing)
        )
      ])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        nativeHandleGeneration: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
    }

    /// Nothing arriving at all resolves as a timeout rather than hanging.
    @Test
    func `An empty stream times out`() async {
      let stream = Self.eventStream([])

      let outcome = await Player.awaitOutputSafeStop(
        on: stream,
        nativeHandleGeneration: 7,
        timeout: .milliseconds(50)
      )

      #expect(outcome == .timedOut)
    }

    /// A ceiling reached while the handle sits in error is reported as the
    /// error it is, not as a bare timeout — the two mean different things to
    /// a caller deciding whether to retry or surface a failure.
    @Test
    func `A timeout with the handle in error reports failedButStillDraining`() {
      #expect(
        Player.resolveStopOutcome(waitOutcome: .timedOut, nativeState: .error)
          == .failedButStillDraining
      )
    }

    /// A timeout with no error stays a timeout.
    @Test
    func `A timeout without an error stays a timeout`() {
      #expect(
        Player.resolveStopOutcome(waitOutcome: .timedOut, nativeState: .stopped)
          == .timedOut
      )
      #expect(
        Player.resolveStopOutcome(waitOutcome: .timedOut, nativeState: .playing)
          == .timedOut
      )
    }

    /// A Stopped callback is output-safe only while its exact transport
    /// episode remains current and the native handle still rests at stopped.
    /// A same-handle successor can already be opening or playing by the time
    /// the predecessor callback reaches the waiter.
    @Test
    func `An observed stop is revalidated against current transport`() {
      #expect(
        Player.resolveStopOutcome(waitOutcome: .stopped, nativeState: .error)
          == .timedOut
      )
      #expect(
        Player.resolveStopOutcome(waitOutcome: .stopped, nativeState: .stopped)
          == .stopped
      )
      #expect(
        Player.resolveStopOutcome(
          waitOutcome: .stopped,
          nativeState: .stopped,
          episodeIsCurrent: false
        ) == .timedOut
      )
    }

    @Test
    func `Observable stop wait drains an older stopping publication first`() async {
      let statuses = Self.statusStream([
        PlaybackStatus(state: .stopping, generation: PlaybackGeneration(4)),
        PlaybackStatus(state: .stopped, generation: PlaybackGeneration(4))
      ])

      let mirrored = await Player.awaitPlaybackMirror(
        .stopped,
        generation: PlaybackGeneration(4),
        on: statuses,
        timeout: .seconds(1)
      )

      #expect(mirrored)
    }

    @Test
    func `Observable stop wait rejects a successor generation`() async {
      let statuses = Self.statusStream([
        PlaybackStatus(state: .stopping, generation: PlaybackGeneration(4)),
        PlaybackStatus(state: .playing, generation: PlaybackGeneration(5))
      ])

      let mirrored = await Player.awaitPlaybackMirror(
        .stopped,
        generation: PlaybackGeneration(4),
        on: statuses,
        timeout: .seconds(1)
      )

      #expect(!mirrored)
    }

    /// Builds a finite stream of the given events. The stream finishes after
    /// the last one, which also exercises the "source ended without a stop"
    /// path.
    private static func eventStream(
      _ events: [SourcedPlayerEvent]
    )
      -> AsyncStream<SourcedPlayerEvent> {
      AsyncStream { continuation in
        for event in events {
          continuation.yield(event)
        }
        continuation.finish()
      }
    }

    private static func statusStream(
      _ statuses: [PlaybackStatus]
    ) -> AsyncStream<PlaybackStatus> {
      AsyncStream { continuation in
        for status in statuses {
          continuation.yield(status)
        }
        continuation.finish()
      }
    }

    /// The result has to stay trustworthy across repeated cycles, since that
    /// is how it is used in practice: stop, tear down outputs, play again.
    @Test(.enabled(if: TestCondition.canPlayMedia))
    func `Repeated play and stop cycles stay output-safe`() async throws {
      let player = Player(instance: TestInstance.makePlayback())

      for cycle in 0..<3 {
        try player.play(url: TestMedia.twosecURL)
        try #require(
          await poll(until: { player.state == .playing }),
          "Waiting for: player.state == .playing (cycle \(cycle))"
        )

        let outcome = await player.stopAndWaitForOutcome()

        #expect(outcome == .stopped, "cycle \(cycle) was not output-safe")
        #expect(player.nativePlaybackState == .stopped, "cycle \(cycle)")
      }
    }
  }
}
