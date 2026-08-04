#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import CoreVideo
import CustomDump
import Synchronization
import Testing

extension Integration.PixelBufferRendererCallbackTests {
  // MARK: - Display callback

  /// Synthesize a BGRA `CVPixelBuffer`, hand it to the display callback,
  /// and verify the function wraps it into a `CMSampleBuffer` and
  /// enqueues it onto the attached display layer without crashing.
  ///
  /// Runs on `@MainActor` because `AVSampleBufferDisplayLayer` is not
  /// `Sendable` — the layer and the renderer must be allocated on the
  /// same actor. The callback itself is invoked synchronously; the
  /// renderer's async enqueue is awaited via a short `Task.sleep`.
  @MainActor
  @Test
  func `Display callback enqueues a sample onto the display layer`() async throws {
    let displayLayer = AVSampleBufferDisplayLayer()
    let renderer = PixelBufferRenderer(displayLayer: displayLayer)
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }

    let pb = try makeBGRAImageBuffer(width: 2, height: 2)

    let pictureHandle = try installUnlockedPicture(pb, on: vout)

    pixelBufferDisplayCallback(opaque: vout.opaque, picture: pictureHandle)

    // Give the renderer's async enqueue queue a moment to settle.
    try? await Task.sleep(for: .milliseconds(20))
  }

  @MainActor
  @Test
  func `Display callback rejects a vout created before a media boundary`() throws {
    let generation = Mutex<UInt64>(1)
    let displayLayer = AVSampleBufferDisplayLayer()
    let renderer = PixelBufferRenderer(displayLayer: displayLayer)
    renderer.beginPlaybackGeneration(1)
    let lease = CallbackLease(
      displayRenderer: renderer,
      playbackGeneration: { generation.withLock { $0 } }
    )
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }

    let staleBuffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let stalePicture = try installUnlockedPicture(staleBuffer, on: vout)

    generation.withLock { $0 = 2 }
    lease.handleContext.beginPlaybackGeneration(2)
    renderer.beginPlaybackGeneration(2)
    pixelBufferDisplayCallback(opaque: vout.opaque, picture: stalePicture)

    let afterStaleFrame = renderer.telemetrySnapshot
    #expect(afterStaleFrame.playbackGeneration == 2)
    #expect(afterStaleFrame.decodedFrameCount == 0)
    #expect(afterStaleFrame.enqueuedFrameCount == 0)

    let stillStaleBuffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let stillStalePicture = try installUnlockedPicture(stillStaleBuffer, on: vout)
    pixelBufferDisplayCallback(opaque: vout.opaque, picture: stillStalePicture)
    #expect(renderer.telemetrySnapshot.decodedFrameCount == 0)

    let currentVout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(currentVout) }
    let currentBuffer = try makeBGRAImageBuffer(width: 2, height: 2)
    let currentPicture = try installUnlockedPicture(currentBuffer, on: currentVout)
    pixelBufferDisplayCallback(opaque: currentVout.opaque, picture: currentPicture)

    let afterCurrentFrame = renderer.telemetrySnapshot
    #expect(afterCurrentFrame.playbackGeneration == 2)
    #expect(afterCurrentFrame.decodedFrameCount == 1)
    #expect(afterCurrentFrame.enqueuedFrameCount == 1)
  }

  @MainActor
  @Test
  func `Display callback does not mutate source frame bytes`() throws {
    let displayLayer = AVSampleBufferDisplayLayer()
    let renderer = PixelBufferRenderer(displayLayer: displayLayer)
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 3, height: 2)
    defer { lease.close(vout) }

    let pb = try makeBGRAImageBuffer(width: 3, height: 2, alpha: 37)
    let expectedAlphaBytes = try alphaBytes(in: pb)

    let pictureHandle = try installUnlockedPicture(pb, on: vout)
    pixelBufferDisplayCallback(opaque: vout.opaque, picture: pictureHandle)

    try expectNoDifference(alphaBytes(in: pb), expectedAlphaBytes)
  }

  @MainActor
  @Test
  func `Display callback uses configured timebase for presentation time`() throws {
    let displayLayer = AVSampleBufferDisplayLayer()
    let renderer = PixelBufferRenderer(displayLayer: displayLayer)
    let lease = CallbackLease(displayRenderer: renderer)
    let vout = try lease.negotiate(width: 2, height: 2)
    defer { lease.close(vout) }

    let clock = CMClockGetHostTimeClock()
    var timebase: CMTimebase?
    let status = CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: clock,
      timebaseOut: &timebase
    )
    #expect(status == noErr)
    let tb = try #require(timebase)
    CMTimebaseSetTime(tb, time: CMTime(seconds: 3, preferredTimescale: 1000))
    renderer.setTimebase(tb)

    let pb = try makeBGRAImageBuffer(width: 2, height: 2)
    let pictureHandle = try installUnlockedPicture(pb, on: vout)

    pixelBufferDisplayCallback(opaque: vout.opaque, picture: pictureHandle)
  }

  /// A nil `opaque` guards-out early.
  @Test
  func `Display callback with nil opaque is a no-op`() {
    pixelBufferDisplayCallback(opaque: nil, picture: nil)
  }

  /// A non-nil `opaque` with a nil `picture` also guards-out without
  /// touching the display layer.
  @MainActor
  @Test
  func `Display callback with nil picture is a no-op`() {
    let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
    let retained = makeRetainedContext(renderer: renderer)
    defer { retained.release() }

    pixelBufferDisplayCallback(opaque: retained.toOpaque(), picture: nil)
  }

  // MARK: - Pool floor / deferred retirement

  /// Drive the format callback and read back the negotiated pool's
  /// minimum buffer count via its attributes.
  private func formatCallbackPoolFloor(
    lease: CallbackLease,
    width: UInt32,
    height: UInt32
  )
    throws -> (successCount: UInt32, poolFloor: Int) {
    let vout = try lease.negotiate(width: width, height: height)
    defer { lease.close(vout) }
    let pool = try #require(vout.context.decodeRenderer.state.withLock { $0.pool })
    let attrs = try #require(CVPixelBufferPoolGetAttributes(pool) as? [String: Any])
    let minNumber = try #require(
      attrs[kCVPixelBufferPoolMinimumBufferCountKey as String] as? NSNumber
    )
    return (vout.successCount, minNumber.intValue)
  }

  /// The resident pool floor is byte-budgeted: 4K drains down to a small
  /// floor while SD keeps the full recycled floor. The format return reports
  /// the single allocation proven during negotiation, not decoder headroom.
  @Test
  func `Pool floor is byte-budgeted independently of format success count`() throws {
    let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
    let lease = CallbackLease(displayRenderer: renderer)

    let uhd = try formatCallbackPoolFloor(
      lease: lease,
      width: 3840,
      height: 2160
    )
    #expect(uhd.successCount == 1)
    #expect(uhd.poolFloor >= 3)
    #expect(uhd.poolFloor <= 4)

    let sd = try formatCallbackPoolFloor(
      lease: lease,
      width: 320,
      height: 240
    )
    #expect(sd.successCount == 1)
    #expect(sd.poolFloor == 12)
  }

  /// Three 32 MiB BGRA buffers exactly fit the 96 MiB resident budget. One
  /// pixel column beyond that deterministic boundary must switch the floor
  /// to a single buffer instead of pinning three oversized frames.
  @Test
  func `Pool floor drops to one immediately above the large-frame threshold`() throws {
    let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
    let lease = CallbackLease(displayRenderer: renderer)

    let atBoundary = try formatCallbackPoolFloor(
      lease: lease,
      width: 4096,
      height: 2048
    )
    #expect(atBoundary.successCount == 1)
    #expect(atBoundary.poolFloor == 3)

    let aboveBoundary = try formatCallbackPoolFloor(
      lease: lease,
      width: 4097,
      height: 2048
    )
    #expect(aboveBoundary.successCount == 1)
    #expect(aboveBoundary.poolFloor == 1)
  }

  /// Clearing the media-player callback variables does not update a vout
  /// that is concurrently opening and may already have copied the opaque.
  /// `voutOpen == false` therefore cannot prove that the opaque is safe to
  /// release: the format callback may simply not have arrived yet.
  @Test
  func `Retired opaque remains callable until native handle lifetime ends`() throws {
    weak var weakContext: PixelBufferRendererCallbackContext?
    var opaque: UnsafeMutableRawPointer?

    do {
      let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      let context = PixelBufferRendererCallbackContext(renderer: renderer)
      weakContext = context
      opaque = Unmanaged.passRetained(context).toOpaque()
      context.requestRetirement()
    }

    #expect(weakContext != nil)
    let handleOpaque = try #require(opaque)
    var voutOpaque: UnsafeMutableRawPointer? = handleOpaque
    var chroma = [CChar](repeating: 0, count: 4)
    var width: UInt32 = 96
    var height: UInt32 = 54
    var pitch: UInt32 = 0
    var lines: UInt32 = 0
    let result = withUnsafeMutablePointer(to: &voutOpaque) { opaquePointer in
      chroma.withUnsafeMutableBufferPointer { chromaBuffer in
        pixelBufferFormatCallback(
          opaque: opaquePointer,
          chroma: chromaBuffer.baseAddress,
          width: &width,
          height: &height,
          pitches: &pitch,
          lines: &lines
        )
      }
    }
    #expect(result == 1)
    let negotiatedOpaque = try #require(voutOpaque)
    #expect(negotiatedOpaque != handleOpaque)

    var plane: UnsafeMutableRawPointer?
    let lateLock = withUnsafeMutablePointer(to: &plane) {
      pixelBufferLockCallback(opaque: negotiatedOpaque, planes: $0)
    }
    #expect(lateLock != nil)
    #expect(plane != nil)
    pixelBufferUnlockCallback(
      opaque: negotiatedOpaque,
      picture: lateLock,
      planes: nil
    )
    pixelBufferDisplayCallback(opaque: negotiatedOpaque, picture: lateLock)
    pixelBufferCleanupCallback(opaque: negotiatedOpaque)
    #expect(weakContext != nil)

    weakContext?.nativePlayerHandleDidRelease(opaque: handleOpaque)

    #expect(weakContext == nil)
  }
}
#endif
