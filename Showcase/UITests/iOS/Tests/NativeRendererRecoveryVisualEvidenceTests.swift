import XCTest

final class NativeRendererRecoveryVisualEvidenceTests: XCTestCase {
  func test_replayDerivesMotionOnlyFromRetainedCanonicalFrames() throws {
    let frames = movingFrames()
    let binding = NativeRendererRecoveryVisualCaptureBinding(
      captureSystemUptimeSeconds: [101.0, 101.35, 101.7],
      frames: frames
    )

    let replayed = try NativeRendererRecoveryVisualReplayEvaluator.replay(binding)
    let direct = try XCTUnwrap(VideoSurfaceMotionEvidenceAnalyzer.analyze(frames))

    XCTAssertEqual(replayed, direct)
    XCTAssertEqual(binding.frameCount, 3)
    XCTAssertEqual(binding.bytesPerFrame, 6912)
    XCTAssertEqual(binding.canonicalRGB8Base64.count, 3)
    for (encoded, frame) in zip(binding.canonicalRGB8Base64, frames) {
      XCTAssertEqual(Data(base64Encoded: encoded), Data(frame.rgb))
    }
  }

  func test_exactJSONSchemaRetainsReplayableFramesAndUptime() throws {
    let oracle = try NativeRendererRecoveryVisualOracleEvidence.evaluated(
      binding: validBinding(),
      minimumChangedPixelScore: 0.01
    )
    let data = try JSONEncoder().encode(oracle)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    XCTAssertEqual(Set(object.keys), [
      "formatVersion",
      "status",
      "reason",
      "surface",
      "captureBinding",
      "frameHashes",
      "adjacentChangedPixelRatios",
      "changedPixelScore",
      "distinctFrameHashes",
      "minimumChangedPixelScore"
    ])
    let binding = try XCTUnwrap(object["captureBinding"] as? [String: Any])
    XCTAssertEqual(Set(binding.keys), [
      "formatVersion",
      "method",
      "encoding",
      "frameWidthPixels",
      "frameHeightPixels",
      "channelCount",
      "bytesPerFrame",
      "frameCount",
      "captureSystemUptimeSeconds",
      "canonicalRGB8Base64"
    ])
    XCTAssertEqual(binding["frameWidthPixels"] as? Int, 64)
    XCTAssertEqual(binding["frameHeightPixels"] as? Int, 36)
    XCTAssertEqual(binding["channelCount"] as? Int, 3)
    XCTAssertEqual(binding["bytesPerFrame"] as? Int, 6912)
    XCTAssertEqual(binding["frameCount"] as? Int, 3)
    XCTAssertEqual(
      binding["captureSystemUptimeSeconds"] as? [Double],
      [101.0, 101.35, 101.7]
    )
  }

  func test_replayRejectsMalformedDeclaredFrameCount() {
    let valid = validBinding()
    let malformed = copy(valid, frameCount: 2)

    XCTAssertThrowsError(
      try NativeRendererRecoveryVisualReplayEvaluator.replay(malformed)
    ) { error in
      XCTAssertEqual(
        error as? NativeRendererRecoveryVisualReplayError,
        .invalidFrameCount(declared: 2, timestamps: 3, frames: 3)
      )
    }
  }

  func test_replayRejectsMissingTimestamp() {
    let valid = validBinding()
    let malformed = copy(valid, captureSystemUptimeSeconds: [101.0, 101.35])

    XCTAssertThrowsError(
      try NativeRendererRecoveryVisualReplayEvaluator.replay(malformed)
    ) { error in
      XCTAssertEqual(
        error as? NativeRendererRecoveryVisualReplayError,
        .invalidFrameCount(declared: 3, timestamps: 2, frames: 3)
      )
    }
  }

  func test_replayRejectsNonIncreasingUptime() {
    let valid = validBinding()
    let malformed = copy(
      valid,
      captureSystemUptimeSeconds: [101.0, 101.0, 101.7]
    )

    XCTAssertThrowsError(
      try NativeRendererRecoveryVisualReplayEvaluator.replay(malformed)
    ) { error in
      XCTAssertEqual(
        error as? NativeRendererRecoveryVisualReplayError,
        .timestampsNotStrictlyIncreasing
      )
    }
  }

  func test_replayRejectsMalformedBase64() {
    let valid = validBinding()
    var encoded = valid.canonicalRGB8Base64
    encoded[1] = "not-base64!"
    let malformed = copy(valid, canonicalRGB8Base64: encoded)

    XCTAssertThrowsError(
      try NativeRendererRecoveryVisualReplayEvaluator.replay(malformed)
    ) { error in
      XCTAssertEqual(
        error as? NativeRendererRecoveryVisualReplayError,
        .invalidBase64(index: 1)
      )
    }
  }

  func test_replayRejectsFrameWithWrongByteLength() {
    let valid = validBinding()
    var encoded = valid.canonicalRGB8Base64
    encoded[2] = Data(repeating: 0, count: 6911).base64EncodedString()
    let malformed = copy(valid, canonicalRGB8Base64: encoded)

    XCTAssertThrowsError(
      try NativeRendererRecoveryVisualReplayEvaluator.replay(malformed)
    ) { error in
      XCTAssertEqual(
        error as? NativeRendererRecoveryVisualReplayError,
        .invalidFrameByteCount(index: 2, observed: 6911)
      )
    }
  }

  func test_notRunOracleCannotBeMistakenForVisualPass() {
    let oracle = NativeRendererRecoveryVisualOracleEvidence.notRun(
      reason: "os-resource-revocation-not-observed"
    )

    XCTAssertEqual(oracle.status, .notRun)
    XCTAssertEqual(oracle.captureBinding.frameCount, 0)
    XCTAssertTrue(oracle.captureBinding.canonicalRGB8Base64.isEmpty)
    XCTAssertThrowsError(
      try NativeRendererRecoveryVisualReplayEvaluator.replay(oracle.captureBinding)
    )
  }

  private func validBinding() -> NativeRendererRecoveryVisualCaptureBinding {
    NativeRendererRecoveryVisualCaptureBinding(
      captureSystemUptimeSeconds: [101.0, 101.35, 101.7],
      frames: movingFrames()
    )
  }

  private func movingFrames() -> [VideoSurfaceCanonicalFrame] {
    let first = [UInt8](repeating: 0, count: VideoSurfaceCanonicalFrame.byteCount)
    var second = first
    var third = first
    for pixel in 0..<100 {
      let offset = pixel * 3
      second[offset] = 20
      second[offset + 1] = 20
      second[offset + 2] = 20
    }
    for pixel in 0..<200 {
      let offset = pixel * 3
      third[offset] = 40
      third[offset + 1] = 40
      third[offset + 2] = 40
    }
    return [first, second, third].map(VideoSurfaceCanonicalFrame.init(rgb:))
  }

  private func copy(
    _ binding: NativeRendererRecoveryVisualCaptureBinding,
    frameCount: Int? = nil,
    captureSystemUptimeSeconds: [Double]? = nil,
    canonicalRGB8Base64: [String]? = nil
  ) -> NativeRendererRecoveryVisualCaptureBinding {
    NativeRendererRecoveryVisualCaptureBinding(
      formatVersion: binding.formatVersion,
      method: binding.method,
      encoding: binding.encoding,
      frameWidthPixels: binding.frameWidthPixels,
      frameHeightPixels: binding.frameHeightPixels,
      channelCount: binding.channelCount,
      bytesPerFrame: binding.bytesPerFrame,
      frameCount: frameCount ?? binding.frameCount,
      captureSystemUptimeSeconds: captureSystemUptimeSeconds
        ?? binding.captureSystemUptimeSeconds,
      canonicalRGB8Base64: canonicalRGB8Base64 ?? binding.canonicalRGB8Base64
    )
  }
}
