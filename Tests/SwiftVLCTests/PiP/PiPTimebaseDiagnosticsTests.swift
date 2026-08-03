#if os(iOS) || os(macOS)
import Foundation
import Testing
@_spi(Qualification) @testable import SwiftVLC

@MainActor
@Suite(.serialized)
struct PiPTimebaseDiagnosticsTests {
  @Test
  func `Snapshot reports the direct renderer and clock without mutating either`() throws {
    let player = Player()
    let controller = PiPController(player: player)

    let before = controller._controlTimebaseSecondsForTesting()
    let snapshot = controller.timebaseDiagnosticSnapshot()

    #expect(snapshot.playbackGeneration == 0)
    #expect(snapshot.isPlaybackActive == false)
    #expect(snapshot.mediaTimeSeconds == 0)
    #expect(snapshot.controlTimebaseSeconds == before)
    #expect(snapshot.controlTimebaseRate == 0)
    #expect(snapshot.decodedFrameCount == 0)
    #expect(snapshot.deliveredFrameCount == 0)
    #expect(snapshot.correctionCount >= 1)
    #expect(controller._controlTimebaseSecondsForTesting() == before)
    _ = try JSONEncoder().encode(snapshot)
  }

  @Test
  func `Every timebase write is emitted with a monotonic sequence`() async throws {
    let player = Player()
    let controller = PiPController(player: player)
    let stream = controller.timebaseCorrections
    var iterator = stream.makeAsyncIterator()

    controller.syncTimebase(playing: false, reason: .playbackStateTransition)
    let first = try #require(await iterator.next())
    controller.syncTimebase(playing: false, reason: .initialSynchronization)
    let second = try #require(await iterator.next())

    #expect(first.reason == .playbackStateTransition)
    #expect(second.reason == .initialSynchronization)
    #expect(second.sequence == first.sequence + 1)
    #expect(first.playbackGeneration == 0)
    #expect(first.correctedTimebaseSeconds == first.mediaTimeSeconds)
    _ = try JSONEncoder().encode([first, second])
  }
}
#endif
