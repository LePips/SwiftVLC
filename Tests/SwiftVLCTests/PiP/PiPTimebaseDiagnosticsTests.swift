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
    let rendererBefore = controller.renderer.telemetrySnapshot
    let snapshot = controller.timebaseDiagnosticSnapshot()
    let rendererAfter = controller.renderer.telemetrySnapshot

    #expect(snapshot.playbackGeneration == 0)
    #expect(snapshot.isPlaybackActive == false)
    #expect(snapshot.isPictureInPictureActive == false)
    #expect(snapshot.mediaTimeSeconds == 0)
    #expect(snapshot.controlTimebaseSeconds == before)
    #expect(snapshot.controlTimebaseRate == 0)
    #expect(snapshot.decodedFrameCount == 0)
    #expect(snapshot.decodedContentChangeCount == 0)
    #expect(snapshot.lastDecodedContentFingerprint == nil)
    #expect(snapshot.renderGeneration == rendererBefore.renderGeneration)
    #expect(snapshot.presentationCopyRequired == false)
    #expect(snapshot.presentationCopyFrameCount == 0)
    #expect(snapshot.presentationCopyFailureCount == 0)
    #expect(
      snapshot.displayLayerFlushRequestCount
        == rendererBefore.displayLayerFlushRequestCount
    )
    #expect(snapshot.decodePoolAllocationFailureCount == 0)
    #expect(snapshot.lastDecodePoolAllocationStatus == nil)
    #expect(snapshot.renderPoolAllocationFailureCount == 0)
    #expect(snapshot.lastRenderPoolAllocationStatus == nil)
    #expect(snapshot.vmemLockAttemptCount == 0)
    #expect(snapshot.vmemLockSuccessCount == 0)
    #expect(snapshot.vmemPoolUnavailableCount == 0)
    #expect(snapshot.vmemBaseAddressLockFailureCount == 0)
    #expect(snapshot.vmemPendingInstallFailureCount == 0)
    #expect(snapshot.vmemUnlockCallbackCount == 0)
    #expect(snapshot.vmemDisplayCallbackCount == 0)
    #expect(snapshot.vmemDisplayConsumeFailureCount == 0)
    #expect(snapshot.deliveredFrameCount == 0)
    #expect(snapshot.displayLayerStatus == "unknown")
    #expect(snapshot.displayLayerError == nil)
    #expect(snapshot.lastDeliveredSamplePlaybackGeneration == nil)
    #expect(snapshot.correctionCount >= 1)
    #expect(controller._controlTimebaseSecondsForTesting() == before)
    #expect(rendererAfter == rendererBefore)
    _ = try JSONEncoder().encode(snapshot)
  }

  @Test
  func `Every timebase write is emitted with a monotonic sequence`() async throws {
    let player = Player()
    let controller = PiPController(player: player)
    let stream = controller.timebaseCorrections
    var iterator = stream.makeAsyncIterator()

    controller.syncTimebase(playing: false, reason: .playbackStateTransition)
    let firstTime = try #require(await iterator.next())
    let firstRate = try #require(await iterator.next())
    controller.syncTimebase(playing: false, reason: .initialSynchronization)
    let secondTime = try #require(await iterator.next())
    let secondRate = try #require(await iterator.next())

    #expect(firstTime.reason == .playbackStateTransition)
    #expect(firstRate.reason == .playbackStateTransition)
    #expect(secondTime.reason == .initialSynchronization)
    #expect(secondRate.reason == .initialSynchronization)
    #expect(firstRate.sequence == firstTime.sequence + 1)
    #expect(secondTime.sequence == firstRate.sequence + 1)
    #expect(secondRate.sequence == secondTime.sequence + 1)
    #expect(firstTime.playbackGeneration == 0)
    #expect(firstTime.correctedTimebaseSeconds == firstTime.mediaTimeSeconds)
    #expect(firstTime.correctedTimebaseRate == nil)
    #expect(firstRate.previousTimebaseRate != nil)
    #expect(firstRate.correctedTimebaseRate == 0)
    #expect(firstRate.systemUptime >= firstTime.systemUptime)
    #expect(secondRate.systemUptime >= firstRate.systemUptime)
    _ = try JSONEncoder().encode([firstTime, firstRate, secondTime, secondRate])
  }

  @Test
  func `A rate-only write is independently recorded`() async throws {
    let player = Player()
    let controller = PiPController(player: player)
    var iterator = controller.timebaseCorrections.makeAsyncIterator()

    controller.setTimebaseRate(
      0.5,
      reason: .playbackRateTransition,
      mediaTimeSeconds: 12
    )
    let correction = try #require(await iterator.next())

    #expect(correction.reason == .playbackRateTransition)
    #expect(correction.correctedTimebaseRate == 0.5)
    #expect(correction.previousTimebaseRate != nil)
    #expect(correction.mediaTimeSeconds == 12)
  }
}
#endif
