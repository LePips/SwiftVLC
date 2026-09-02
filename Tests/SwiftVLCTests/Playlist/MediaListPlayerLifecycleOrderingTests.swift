@testable import SwiftVLC
import CLibVLC
import Testing

private enum InjectedMediaListStart: CaseIterable, Sendable {
  case play
  case playAt
  case playMedia
  case next
  case previous

  @MainActor func invoke(
    on listPlayer: MediaListPlayer,
    media: borrowing Media
  )
    throws(VLCError) {
    switch self {
    case .play:
      listPlayer.play()
    case .playAt:
      try listPlayer.play(at: 0)
    case .playMedia:
      try listPlayer.play(media)
    case .next:
      try listPlayer.next()
    case .previous:
      try listPlayer.previous()
    }
  }
}

private enum InjectedRejectableMediaListStart: CaseIterable, Sendable {
  case playAt
  case playMedia
  case next
  case previous

  @MainActor func invoke(
    on listPlayer: MediaListPlayer,
    media: borrowing Media
  )
    throws(VLCError) {
    switch self {
    case .playAt:
      try listPlayer.play(at: 0)
    case .playMedia:
      try listPlayer.play(media)
    case .next:
      try listPlayer.next()
    case .previous:
      try listPlayer.previous()
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct MediaListPlayerLifecycleOrderingTests {
    @Test(arguments: InjectedMediaListStart.allCases)
    fileprivate func `Every list start reserves callback ordering before native dispatch`(
      command: InjectedMediaListStart
    )
      async throws {
      let setup = try makeSetup()
      let player = setup.player
      let listPlayer = setup.listPlayer
      let playbackGeneration = player.sessionGeneration
      player._setStateForTesting(state: .idle, nativeState: .idle)
      player.clearPlaybackControlForExternalStop()
      let stopEpoch = player.eventBridge.currentLifecycleControlEpoch
      #expect(
        player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: playbackGeneration
        )
      )

      var callbackEpoch: UInt64?
      player._nativePlaybackStateOverrideForTesting = .playing
      listPlayer._nativeTransportDispatchOverrideForTesting = { _ in
        callbackEpoch = player.eventBridge.currentLifecycleControlEpoch
        player.eventBridge._emitNativeEventForTesting(
          mediaListPlayerStateEvent(libvlc_MediaPlayerPlaying.rawValue)
        )
        return 0
      }

      try command.invoke(on: listPlayer, media: setup.media)

      try #require(
        await poll(timeout: .seconds(1)) { player.state == .playing },
        "the synchronous Playing callback was discarded"
      )
      #expect(callbackEpoch != stopEpoch)
      #expect(player.isPlaybackRequestedActive)
      #expect(
        !player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: player.eventBridge.currentPlaybackGeneration
        )
      )
    }

    @Test(arguments: InjectedRejectableMediaListStart.allCases)
    fileprivate func `Rejected list starts settle and restore callback quarantine`(
      command: InjectedRejectableMediaListStart
    )
      async throws {
      let setup = try makeSetup()
      let player = setup.player
      let listPlayer = setup.listPlayer
      player._setStateForTesting(state: .idle, nativeState: .idle)
      player.clearPlaybackControlForExternalStop()
      let stopEpoch = player.eventBridge.currentLifecycleControlEpoch
      player._nativePlaybackStateOverrideForTesting = .idle
      listPlayer._nativeTransportDispatchOverrideForTesting = { _ in
        player.eventBridge._emitNativeEventForTesting(
          mediaListPlayerStateEvent(libvlc_MediaPlayerPlaying.rawValue)
        )
        return -1
      }

      #expect(throws: VLCError.self) {
        try command.invoke(on: listPlayer, media: setup.media)
      }
      for _ in 0..<10 {
        await Task.yield()
      }

      #expect(player.state == .idle)
      #expect(!player.isPlaybackRequestedActive)
      #expect(player.eventBridge.currentLifecycleControlEpoch > stopEpoch)
      #expect(
        player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: player.sessionGeneration
        )
      )
    }

    @Test
    func `List Stop establishes requested cause before synchronous callbacks`() async throws {
      let setup = try makeSetup()
      let player = setup.player
      let listPlayer = setup.listPlayer
      let playbackGeneration = player.sessionGeneration
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true
      )
      player._nativePlaybackStateOverrideForTesting = .playing
      var hadBarrierAtDispatch = false
      var causeAfterSynchronousCallback: PlaybackTerminalCause?
      listPlayer._nativeTransportDispatchOverrideForTesting = { command in
        guard case .stop = command else { return 0 }
        hadBarrierAtDispatch = player.eventBridge.hasExplicitStopBarrier(
          playbackGeneration: playbackGeneration
        )
        player.eventBridge._emitNativeEventForTesting(
          mediaListPlayerStateEvent(libvlc_MediaPlayerStopping.rawValue)
        )
        player._nativePlaybackStateOverrideForTesting = .stopped
        player.eventBridge._emitNativeEventForTesting(
          mediaListPlayerStateEvent(libvlc_MediaPlayerStopped.rawValue)
        )
        causeAfterSynchronousCallback = player.eventBridge.terminalCause(
          for: playbackGeneration
        )
        return 0
      }

      listPlayer.stop()

      #expect(hadBarrierAtDispatch)
      #expect(causeAfterSynchronousCallback == .requestedStop)
      #expect(!player.isPlaybackRequestedActive)
      try #require(
        await poll(timeout: .seconds(1)) { player.state == .stopped },
        "the callbacks emitted synchronously by list Stop were discarded"
      )
      #expect(
        player.eventBridge.terminalCause(for: playbackGeneration)
          == .requestedStop
      )
    }

    private func makeSetup() throws -> (
      player: Player,
      listPlayer: MediaListPlayer,
      media: Media
    ) {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let listPlayer = MediaListPlayer(instance: instance)
      let media = try Media(url: TestMedia.twosecURL)
      let list = MediaList()
      try list.append(media)
      listPlayer.mediaPlayer = player
      listPlayer.mediaList = list
      player.load(media)
      return (player, listPlayer, media)
    }
  }
}

private func mediaListPlayerStateEvent(_ type: UInt32) -> libvlc_event_t {
  var event = libvlc_event_t()
  event.type = Int32(type)
  return event
}
