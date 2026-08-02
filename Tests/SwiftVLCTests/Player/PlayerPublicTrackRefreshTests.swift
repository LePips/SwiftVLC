import SwiftVLC
import Testing

@Suite(.tags(.mainActor))
@MainActor struct PlayerPublicTrackRefreshTests {
  @Test
  func `refreshTracks without media leaves public track lists empty`() {
    let player = Player()

    player.refreshTracks()

    #expect(player.audioTracks.isEmpty)
    #expect(player.videoTracks.isEmpty)
    #expect(player.subtitleTracks.isEmpty)
  }
}
