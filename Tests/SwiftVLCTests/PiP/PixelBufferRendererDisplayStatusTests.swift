#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CLibVLC
import CoreMedia
import CoreVideo
import CustomDump
import Foundation
import Synchronization
import Testing

extension Integration.PixelBufferRendererCallbackTests {
  enum DisplayPreparationFailure: CaseIterable, CustomStringConvertible, Sendable {
    case output
    case formatDescription
    case sampleBuffer

    var description: String {
      switch self {
      case .output: "output pixel buffer"
      case .formatDescription: "format description"
      case .sampleBuffer: "sample buffer"
      }
    }
  }

  enum DisplayReadinessFailure: CaseIterable, CustomStringConvertible, Sendable {
    case backpressure
    case flushThenBackpressure

    var description: String {
      switch self {
      case .backpressure: "plain backpressure"
      case .flushThenBackpressure: "flush followed by backpressure"
      }
    }
  }

  @Test
  func `Status callback matches the imported v4 C ABI`() {
    let callback: swiftvlc_video_display_status_cb = pixelBufferDisplayStatusCallback
    #expect(callback(nil, nil) < 0)
  }

  @Test
  func `Status callback rejects missing context picture and ownership`() throws {
    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe()
    let renderer = PixelBufferRenderer(displayLayer: layer, displayLayerAPI: probe.api)
    renderer.beginPlaybackGeneration(0)
    probe.reset()
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }

    let nonnilPicture = try #require(UnsafeMutableRawPointer(bitPattern: 0x1))
    #expect(pixelBufferDisplayStatusCallback(opaque: nil, picture: nonnilPicture) < 0)
    #expect(
      pixelBufferDisplayStatusCallback(
        opaque: lease.handleOpaque,
        picture: nonnilPicture
      ) < 0
    )
    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: nil) < 0)
    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: nonnilPicture) < 0)

    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)
    #expect(lease.handleContext.setDisplayRenderer(nil))
    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture) < 0)
    expectNoDifference(probe.snapshot.enqueueCount, 0)
  }

  @MainActor
  @Test
  func `Status callback rejects a missing output layer`() throws {
    let renderer = PixelBufferRenderer()
    renderer.beginPlaybackGeneration(0)
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)

    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture) < 0)
    expectNoDifference(
      renderer.enqueueSnapshotForTesting,
      PixelBufferEnqueueSnapshot(
        pendingCount: 0,
        isDrainScheduled: false,
        scheduledDrainCount: 0,
        drainedSampleCount: 0,
        replacementCount: 0
      )
    )
  }

  @MainActor
  @Test(arguments: DisplayPreparationFailure.allCases)
  func `Status callback rejects every frame preparation failure`(
    _ failure: DisplayPreparationFailure
  )
    throws {
    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe()
    let renderer = PixelBufferRenderer(
      displayLayer: layer,
      displayLayerAPI: probe.api,
      displayPreparationAPI: preparationAPI(failing: failure)
    )
    renderer.beginPlaybackGeneration(0)
    probe.reset()
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)

    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture) < 0)
    expectNoDifference(probe.snapshot.enqueueCount, 0)
    expectNoDifference(renderer.telemetrySnapshot.enqueuedFrameCount, UInt64(0))
  }

  @MainActor
  @Test
  func `Status callback rejects a stale playback generation`() throws {
    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe()
    let renderer = PixelBufferRenderer(displayLayer: layer, displayLayerAPI: probe.api)
    renderer.beginPlaybackGeneration(1)
    let lease = CallbackLease(displayRenderer: renderer, playbackGeneration: { 1 })
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)

    renderer.beginPlaybackGeneration(2)
    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture) < 0)
    expectNoDifference(probe.snapshot.enqueueCount, 0)
    expectNoDifference(renderer.telemetrySnapshot.enqueuedFrameCount, UInt64(0))
  }

  @MainActor
  @Test(arguments: DisplayReadinessFailure.allCases)
  func `Status callback never reports queued or deferred backpressure as submission`(
    _ failure: DisplayReadinessFailure
  )
    throws {
    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe(
      requiresFlush: failure == .flushThenBackpressure,
      isReady: false
    )
    let renderer = PixelBufferRenderer(displayLayer: layer, displayLayerAPI: probe.api)
    renderer.beginPlaybackGeneration(0)
    probe.reset()
    probe.setRequiresFlush(failure == .flushThenBackpressure)
    probe.setStatus(failure == .flushThenBackpressure ? .failed : .rendering)
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)

    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture) < 0)
    expectNoDifference(
      probe.snapshot,
      DisplayStatusProbe.Snapshot(
        flushCount: failure == .flushThenBackpressure ? 1 : 0,
        readinessCheckCount: 1,
        enqueueCount: 0
      )
    )
    expectNoDifference(
      renderer.enqueueSnapshotForTesting,
      PixelBufferEnqueueSnapshot(
        pendingCount: 0,
        isDrainScheduled: false,
        scheduledDrainCount: 0,
        drainedSampleCount: 0,
        replacementCount: 0
      )
    )
  }

  @MainActor
  @Test
  func `Status callback rejects a permanent display failure without flushing`() throws {
    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe(status: .failed)
    let renderer = PixelBufferRenderer(displayLayer: layer, displayLayerAPI: probe.api)
    renderer.beginPlaybackGeneration(0)
    probe.reset()
    probe.setStatus(.failed)
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)

    #expect(pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture) < 0)
    expectNoDifference(
      probe.snapshot,
      DisplayStatusProbe.Snapshot(
        flushCount: 0,
        readinessCheckCount: 0,
        enqueueCount: 0
      )
    )
    expectNoDifference(renderer.telemetrySnapshot.status, .failed)
    expectNoDifference(renderer.telemetrySnapshot.flushRecoveryFailureCount, UInt64(1))
  }

  @MainActor
  @Test
  func `Status callback returns zero only after synchronous output submission`() throws {
    let layer = AVSampleBufferDisplayLayer()
    let rendererBox = Mutex<PixelBufferRenderer?>(nil)
    let probe = DisplayStatusProbe {
      // Re-enter a lifecycle mutation from the final backend call. The
      // recursive submission gate must not deadlock or hold renderer mutexes.
      rendererBox.withLock { $0 }?.setDisplayLayer(nil)
    }
    let renderer = PixelBufferRenderer(displayLayer: layer, displayLayerAPI: probe.api)
    renderer.beginPlaybackGeneration(0)
    probe.reset()
    rendererBox.withLock { $0 = renderer }
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)

    expectNoDifference(
      pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture),
      CInt(0)
    )
    expectNoDifference(
      probe.snapshot,
      DisplayStatusProbe.Snapshot(flushCount: 0, readinessCheckCount: 1, enqueueCount: 1)
    )
    expectNoDifference(renderer.telemetrySnapshot.presentedFrameCount, UInt64(1))
    expectNoDifference(
      renderer.enqueueSnapshotForTesting,
      PixelBufferEnqueueSnapshot(
        pendingCount: 0,
        isDrainScheduled: false,
        scheduledDrainCount: 0,
        drainedSampleCount: 0,
        replacementCount: 0
      )
    )
  }

  @MainActor
  @Test
  func `Playback generation flush completes before a new exact submission`() throws {
    let playbackGeneration = Mutex<UInt64>(0)
    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe()
    let renderer = PixelBufferRenderer(displayLayer: layer, displayLayerAPI: probe.api)
    renderer.beginPlaybackGeneration(0)
    let lease = CallbackLease(
      displayRenderer: renderer,
      playbackGeneration: { playbackGeneration.withLock { $0 } }
    )
    playbackGeneration.withLock { $0 = 1 }
    lease.handleContext.beginPlaybackGeneration(1)
    probe.reset()

    renderer.beginPlaybackGeneration(1)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)
    expectNoDifference(
      pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture),
      CInt(0)
    )

    expectNoDifference(probe.events, [.flush, .enqueue])
  }

  @MainActor
  @Test
  func `Render size flush completes before a resized exact submission`() throws {
    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe()
    let renderer = PixelBufferRenderer(displayLayer: layer, displayLayerAPI: probe.api)
    renderer.beginPlaybackGeneration(0)
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }
    probe.reset()

    #expect(renderer.setRenderSize(CMVideoDimensions(width: 4, height: 4)))
    let buffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let picture = try installUnlockedPicture(buffer, on: vout)
    expectNoDifference(
      pixelBufferDisplayStatusCallback(opaque: vout.opaque, picture: picture),
      CInt(0)
    )

    expectNoDifference(probe.events, [.flush, .enqueue])
  }

  @MainActor
  @Test
  func `Successor status submission cancels queued predecessor and tombstones retired vout`() throws {
    let enqueueQueue = DispatchQueue(label: "org.swiftvlc.tests.status-successor")
    let blocker = DisplayStatusQueueBlocker(queue: enqueueQueue)
    defer { blocker.release() }
    #expect(blocker.waitUntilStarted() == .success)

    let layer = AVSampleBufferDisplayLayer()
    let probe = DisplayStatusProbe()
    let renderer = PixelBufferRenderer(
      displayLayer: layer,
      enqueueQueue: enqueueQueue,
      displayLayerAPI: probe.api
    )
    renderer.beginPlaybackGeneration(0)
    probe.reset()
    let lease = CallbackLease(displayRenderer: renderer)
    let predecessor = try lease.negotiate(width: 2, height: 2)
    let successor = try lease.negotiate(width: 2, height: 2)
    defer {
      lease.close(predecessor)
      lease.close(successor)
    }

    let oldBuffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let oldPicture = try installUnlockedPicture(oldBuffer, on: predecessor)
    pixelBufferDisplayCallback(opaque: predecessor.opaque, picture: oldPicture)
    #expect(renderer.enqueueSnapshotForTesting.pendingCount == 1)

    let newBuffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let newPicture = try installUnlockedPicture(newBuffer, on: successor)
    expectNoDifference(
      pixelBufferDisplayStatusCallback(opaque: successor.opaque, picture: newPicture),
      CInt(0)
    )
    #expect(renderer.enqueueSnapshotForTesting.pendingCount == 0)

    let retiredBuffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let retiredPicture = try installUnlockedPicture(retiredBuffer, on: predecessor)
    #expect(
      pixelBufferDisplayStatusCallback(
        opaque: predecessor.opaque,
        picture: retiredPicture
      ) < 0
    )

    blocker.release()
    #expect(waitUntilIdle(enqueueQueue) == .success)
    expectNoDifference(probe.snapshot.enqueueCount, 1)
    expectNoDifference(renderer.telemetrySnapshot.voutGeneration, successor.context.voutGeneration)
  }

  private func preparationAPI(
    failing failure: DisplayPreparationFailure
  ) -> PixelBufferDisplayPreparationAPI {
    let live = PixelBufferDisplayPreparationAPI.live
    return PixelBufferDisplayPreparationAPI(
      outputPixelBuffer: { renderer, source in
        failure == .output ? nil : live.outputPixelBuffer(renderer, source)
      },
      formatDescription: { renderer, buffer, generation in
        failure == .formatDescription
          ? nil
          : live.formatDescription(renderer, buffer, generation)
      },
      makeSampleBuffer: { buffer, description, timing in
        failure == .sampleBuffer
          ? nil
          : live.makeSampleBuffer(buffer, description, timing)
      }
    )
  }

  private func waitUntilIdle(_ queue: DispatchQueue) -> DispatchTimeoutResult {
    let completed = DispatchSemaphore(value: 0)
    queue.async { completed.signal() }
    return completed.wait(timeout: .now() + 5)
  }
}

private final class DisplayStatusProbe: @unchecked Sendable {
  enum Event: Equatable {
    case flush
    case enqueue
  }

  struct Snapshot: Equatable {
    let flushCount: Int
    let readinessCheckCount: Int
    let enqueueCount: Int
  }

  private struct State {
    var status: AVQueuedSampleBufferRenderingStatus
    var requiresFlush: Bool
    var isReady: Bool
    var flushCount = 0
    var readinessCheckCount = 0
    var enqueueCount = 0
    var events: [Event] = []
  }

  private let state: Mutex<State>
  private let onEnqueue: @Sendable () -> Void

  init(
    status: AVQueuedSampleBufferRenderingStatus = .rendering,
    requiresFlush: Bool = false,
    isReady: Bool = true,
    onEnqueue: @escaping @Sendable () -> Void = {}
  ) {
    state = Mutex(State(status: status, requiresFlush: requiresFlush, isReady: isReady))
    self.onEnqueue = onEnqueue
  }

  var api: PixelBufferDisplayLayerAPI {
    PixelBufferDisplayLayerAPI(
      status: { [self] _ in state.withLock { $0.status } },
      requiresFlush: { [self] _ in state.withLock { $0.requiresFlush } },
      flush: { [self] _ in
        state.withLock {
          $0.requiresFlush = false
          $0.status = .rendering
          $0.flushCount += 1
          $0.events.append(.flush)
        }
      },
      isReadyForMoreMediaData: { [self] _ in
        state.withLock {
          $0.readinessCheckCount += 1
          return $0.isReady
        }
      },
      enqueue: { [self] _, _ in
        state.withLock {
          $0.enqueueCount += 1
          $0.events.append(.enqueue)
        }
        onEnqueue()
      }
    )
  }

  var snapshot: Snapshot {
    state.withLock {
      Snapshot(
        flushCount: $0.flushCount,
        readinessCheckCount: $0.readinessCheckCount,
        enqueueCount: $0.enqueueCount
      )
    }
  }

  var events: [Event] {
    state.withLock { $0.events }
  }

  func reset() {
    state.withLock {
      $0.flushCount = 0
      $0.readinessCheckCount = 0
      $0.enqueueCount = 0
      $0.events = []
    }
  }

  func setRequiresFlush(_ requiresFlush: Bool) {
    state.withLock { $0.requiresFlush = requiresFlush }
  }

  func setStatus(_ status: AVQueuedSampleBufferRenderingStatus) {
    state.withLock { $0.status = status }
  }
}

private final class DisplayStatusQueueBlocker: @unchecked Sendable {
  private let started = DispatchSemaphore(value: 0)
  private let releaseSemaphore = DispatchSemaphore(value: 0)
  private let wasReleased = Mutex(false)

  init(queue: DispatchQueue) {
    queue.async { [started, releaseSemaphore] in
      started.signal()
      releaseSemaphore.wait()
    }
  }

  func waitUntilStarted() -> DispatchTimeoutResult {
    started.wait(timeout: .now() + 5)
  }

  func release() {
    let shouldSignal = wasReleased.withLock { released -> Bool in
      guard !released else { return false }
      released = true
      return true
    }
    if shouldSignal {
      releaseSemaphore.signal()
    }
  }
}
#endif
