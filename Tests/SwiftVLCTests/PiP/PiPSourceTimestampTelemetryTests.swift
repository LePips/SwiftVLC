#if os(iOS) || os(macOS)
@_spi(Qualification) @testable import SwiftVLC
import Dispatch
import Foundation
import Testing

extension Logic {
  @Suite(.serialized)
  struct PiPSourceTimestampTelemetryTests {
    @Test
    func `Every CFR floor and ceiling interval maps to its exact source bucket`() {
      let cases: [(Int64, NativePictureIntervalBucket)] = [
        (41708, .fps23_976), (41709, .fps23_976),
        (41666, .fps24), (41667, .fps24),
        (40000, .fps25),
        (33366, .fps29_97), (33367, .fps29_97),
        (33333, .fps30), (33334, .fps30),
        (20000, .fps50),
        (16683, .fps59_94), (16684, .fps59_94),
        (16666, .fps60), (16667, .fps60)
      ]

      for (delta, expected) in cases {
        #expect(
          NativePictureTimestampTelemetry.classify(deltaMicroseconds: delta)
            == expected
        )
      }
      #expect(
        NativePictureTimestampTelemetry.classify(deltaMicroseconds: 41700)
          == .other
      )
    }

    @Test
    func `Rational rounding alternation is cumulative without rate conflation`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 4)
      telemetry.setAvailable(true)
      let deltas: [Int64] = [
        41708, 41709,
        41666, 41667,
        40000,
        33366, 33367,
        33333, 33334,
        20000,
        16683, 16684,
        16666, 16667
      ]
      var pts: Int64 = 1_000_000
      telemetry.record(picturePTSUS: pts, playbackGeneration: 4, voutGeneration: 9)
      for delta in deltas {
        pts += delta
        telemetry.record(picturePTSUS: pts, playbackGeneration: 4, voutGeneration: 9)
      }

      let snapshot = telemetry.snapshot
      #expect(snapshot.callbackCount == UInt64(deltas.count + 1))
      #expect(snapshot.validTimestampCount == UInt64(deltas.count + 1))
      #expect(snapshot.counters.fps23_976 == 2)
      #expect(snapshot.counters.fps24 == 2)
      #expect(snapshot.counters.fps25 == 1)
      #expect(snapshot.counters.fps29_97 == 2)
      #expect(snapshot.counters.fps30 == 2)
      #expect(snapshot.counters.fps50 == 1)
      #expect(snapshot.counters.fps59_94 == 2)
      #expect(snapshot.counters.fps60 == 2)
      #expect(snapshot.counters.other == 0)
    }

    @Test
    func `VFR source records both native regimes`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 1)
      telemetry.setAvailable(true)
      var pts: Int64 = 0
      telemetry.record(picturePTSUS: pts, playbackGeneration: 1, voutGeneration: 1)
      let deltas: [Int64] = [41667, 16666, 41666, 16667]
      for delta in deltas {
        pts += delta
        telemetry.record(picturePTSUS: pts, playbackGeneration: 1, voutGeneration: 1)
      }

      let snapshot = telemetry.snapshot
      #expect(snapshot.counters.fps24 == 2)
      #expect(snapshot.counters.fps60 == 2)
      #expect(snapshot.counters.other == 0)
    }

    @Test
    func `Invalid native timing is preserved and breaks the interval baseline`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 2)
      telemetry.setAvailable(true)
      telemetry.record(picturePTSUS: 100, playbackGeneration: 2, voutGeneration: 3)
      telemetry.record(
        picturePTSUS: NativePictureTimestampTelemetry.invalidPicturePTSUS,
        playbackGeneration: 2,
        voutGeneration: 3
      )
      telemetry.record(picturePTSUS: 40100, playbackGeneration: 2, voutGeneration: 3)
      telemetry.record(picturePTSUS: 80100, playbackGeneration: 2, voutGeneration: 3)

      let snapshot = telemetry.snapshot
      #expect(snapshot.callbackCount == 4)
      #expect(snapshot.validTimestampCount == 3)
      #expect(snapshot.invalidTimestampCount == 1)
      #expect(snapshot.counters.fps25 == 1)
      #expect(snapshot.counters.other == 0)
      #expect(snapshot.lastPicturePTSUS == 80100)
    }

    @Test
    func `Discontinuity is counted once and the following CFR interval recovers`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 5)
      telemetry.setAvailable(true)
      let timestamps: [Int64] = [0, 40000, 1_000_000, 1_040_000]
      for pts in timestamps {
        telemetry.record(picturePTSUS: pts, playbackGeneration: 5, voutGeneration: 2)
      }

      let snapshot = telemetry.snapshot
      #expect(snapshot.counters.fps25 == 2)
      #expect(snapshot.counters.other == 1)
      #expect(snapshot.discontinuityCount == 1)
    }

    @Test
    func `Playback and newer vout generations reset while stale callbacks cannot rewind`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 10)
      telemetry.setAvailable(true)
      telemetry.record(picturePTSUS: 0, playbackGeneration: 10, voutGeneration: 1)
      telemetry.record(picturePTSUS: 40000, playbackGeneration: 10, voutGeneration: 1)
      telemetry.record(picturePTSUS: 1000, playbackGeneration: 10, voutGeneration: 2)
      telemetry.record(picturePTSUS: 80000, playbackGeneration: 10, voutGeneration: 1)

      var snapshot = telemetry.snapshot
      #expect(snapshot.playbackGeneration == 10)
      #expect(snapshot.voutGeneration == 2)
      #expect(snapshot.callbackCount == 1)
      #expect(snapshot.counters.fps25 == 0)

      telemetry.beginPlaybackGeneration(11)
      telemetry.record(picturePTSUS: 41000, playbackGeneration: 10, voutGeneration: 3)
      telemetry.record(picturePTSUS: 2000, playbackGeneration: 11, voutGeneration: 3)
      telemetry.record(picturePTSUS: 42000, playbackGeneration: 11, voutGeneration: 3)
      snapshot = telemetry.snapshot
      #expect(snapshot.playbackGeneration == 11)
      #expect(snapshot.voutGeneration == 3)
      #expect(snapshot.callbackCount == 2)
      #expect(snapshot.counters.fps25 == 1)

      telemetry.beginPlaybackGeneration(10)
      telemetry.record(picturePTSUS: 0, playbackGeneration: 10, voutGeneration: 4)
      snapshot = telemetry.snapshot
      #expect(snapshot.playbackGeneration == 11)
      #expect(snapshot.callbackCount == 2)
    }

    @Test
    func `Concurrent stale-vout callbacks cannot contaminate the current segment`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 20)
      telemetry.setAvailable(true)
      telemetry.record(
        picturePTSUS: NativePictureTimestampTelemetry.invalidPicturePTSUS,
        playbackGeneration: 20,
        voutGeneration: 2
      )

      DispatchQueue.concurrentPerform(iterations: 1000) { index in
        telemetry.record(
          picturePTSUS: NativePictureTimestampTelemetry.invalidPicturePTSUS,
          playbackGeneration: 20,
          voutGeneration: index.isMultiple(of: 2) ? 2 : 1
        )
      }

      let snapshot = telemetry.snapshot
      #expect(snapshot.voutGeneration == 2)
      #expect(snapshot.callbackCount == 501)
      #expect(snapshot.invalidTimestampCount == 501)
      #expect(snapshot.counters == NativePictureIntervalCounters())
    }

    @Test
    func `Unavailable v6 ABI exposes neither zero counts nor provenance`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 8)
      telemetry.record(picturePTSUS: 0, playbackGeneration: 8, voutGeneration: 1)

      let snapshot = telemetry.snapshot
      #expect(!snapshot.isAvailable)
      #expect(snapshot.sourceIntervalCounts == nil)
      #expect(snapshot.sourceTimestampProvenance == nil)
      #expect(snapshot.callbackCount == 0)
    }

    @Test
    func `V6 callback captures the exact timestamp before picture rejection`() throws {
      let renderer = PixelBufferRenderer()
      let handleContext = PixelBufferRendererCallbackContext(
        renderer: renderer,
        playbackGeneration: 31
      )
      handleContext.setNativePictureTimestampCallbacksAvailable(true)
      let handleOpaque = Unmanaged.passUnretained(handleContext).toOpaque()
      let vout = try #require(
        handleContext.makeVoutContext(
          handleOpaque: handleOpaque,
          decodeRenderer: PixelBufferRenderer(),
          sourceGeometry: PixelBufferSourceGeometry(fullFrameWidth: 2, height: 2)
        )
      )
      let voutOpaque = Unmanaged.passRetained(vout).toOpaque()

      let result = pixelBufferDisplayStatusV2Callback(
        opaque: voutOpaque,
        picture: nil,
        picturePTSUS: -9_223_372_036_854_000_000
      )

      #expect(result < 0)
      let snapshot = handleContext.sourceTimestampTelemetrySnapshot
      #expect(snapshot.callbackCount == 1)
      #expect(snapshot.validTimestampCount == 1)
      #expect(snapshot.lastPicturePTSUS == -9_223_372_036_854_000_000)
      #expect(snapshot.submittedCount == 0)
      #expect(snapshot.swiftRejectedCount == 1)
      #expect(snapshot.inFlightCount == 0)
      #expect(
        snapshot.callbackCount
          == snapshot.submittedCount + snapshot.swiftRejectedCount
          + snapshot.inFlightCount
      )
      pixelBufferCleanupCallback(opaque: voutOpaque)
    }

    @Test
    func `Raw histogram preserves duplicate backward and exact multiple deltas`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 41)
      telemetry.setAvailable(true)
      let values: [(pts: Int64, submitted: Bool)] = [
        (100, true),
        (100, false),
        (90, true),
        (40090, false),
        (120_090, true)
      ]
      for value in values {
        #expect(
          telemetry.record(
            picturePTSUS: value.pts,
            playbackGeneration: 41,
            voutGeneration: 6
          )
        )
        telemetry.recordSubmissionResult(
          submitted: value.submitted,
          playbackGeneration: 41,
          voutGeneration: 6
        )
      }

      let snapshot = telemetry.snapshot
      #expect(snapshot.firstPicturePTSUS == 100)
      #expect(snapshot.lastPicturePTSUS == 120_090)
      #expect(snapshot.firstValidPicturePTSUS == 100)
      #expect(snapshot.lastValidPicturePTSUS == 120_090)
      #expect(snapshot.duplicateTimestampCount == 1)
      #expect(snapshot.backwardTimestampCount == 1)
      #expect(snapshot.deltaOverflowCount == 0)
      #expect(snapshot.counters.fps25 == 1)
      #expect(snapshot.counters.other == 1)
      #expect(
        snapshot.deltaHistogram == [
          PiPVmemOutputPTSDeltaCount(deltaMicroseconds: -10, count: 1),
          PiPVmemOutputPTSDeltaCount(deltaMicroseconds: 0, count: 1),
          PiPVmemOutputPTSDeltaCount(deltaMicroseconds: 40000, count: 1),
          PiPVmemOutputPTSDeltaCount(deltaMicroseconds: 80000, count: 1)
        ]
      )
      #expect(snapshot.callbackCount == 5)
      #expect(snapshot.submittedCount == 3)
      #expect(snapshot.swiftRejectedCount == 2)
      #expect(snapshot.inFlightCount == 0)
    }

    @Test
    func `Representable delta overflow is explicit rather than fabricated`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 42)
      telemetry.setAvailable(true)
      telemetry.record(
        picturePTSUS: Int64.min + 1,
        playbackGeneration: 42,
        voutGeneration: 1
      )
      telemetry.record(
        picturePTSUS: Int64.max,
        playbackGeneration: 42,
        voutGeneration: 1
      )

      let snapshot = telemetry.snapshot
      #expect(snapshot.deltaOverflowCount == 1)
      #expect(snapshot.deltaHistogram.isEmpty)
      #expect(snapshot.counters.other == 1)
    }

    @Test
    func `New vout reset cannot let an old outcome break conservation`() {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 43)
      telemetry.setAvailable(true)
      #expect(
        telemetry.record(
          picturePTSUS: 0,
          playbackGeneration: 43,
          voutGeneration: 1
        )
      )
      #expect(
        telemetry.record(
          picturePTSUS: 1000,
          playbackGeneration: 43,
          voutGeneration: 2
        )
      )
      telemetry.recordSubmissionResult(
        submitted: true,
        playbackGeneration: 43,
        voutGeneration: 1
      )
      telemetry.recordSubmissionResult(
        submitted: false,
        playbackGeneration: 43,
        voutGeneration: 2
      )

      let snapshot = telemetry.snapshot
      #expect(snapshot.voutGeneration == 2)
      #expect(snapshot.callbackCount == 1)
      #expect(snapshot.submittedCount == 0)
      #expect(snapshot.swiftRejectedCount == 1)
      #expect(snapshot.inFlightCount == 0)
    }

    @Test
    func `Qualification interval JSON has exactly the nine stable field names`() throws {
      let telemetry = NativePictureTimestampTelemetry(playbackGeneration: 1)
      telemetry.setAvailable(true)
      let counts = try #require(telemetry.snapshot.sourceIntervalCounts)
      let object = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode(counts)) as? [String: Any]
      )
      #expect(
        Set(object.keys)
          == Set([
            "fps23_976", "fps24", "fps25", "fps29_97", "fps30",
            "fps50", "fps59_94", "fps60", "other"
          ])
      )
    }
  }
}
#endif
