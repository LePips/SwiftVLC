import Foundation

/// Recovery-local binding between three system-PiP capture times and the
/// canonical pixels used to make the post-recovery motion claim. The raw
/// frames let release policy independently replay every hash and ratio.
struct NativeRendererRecoveryVisualCaptureBinding: Codable, Equatable {
  static let formatVersion = 1
  static let encoding = "base64-rgb8-row-major"
  static let requiredFrameCount = 3

  let formatVersion: Int
  let method: String
  let encoding: String
  let frameWidthPixels: Int
  let frameHeightPixels: Int
  let channelCount: Int
  let bytesPerFrame: Int
  let frameCount: Int
  let captureSystemUptimeSeconds: [Double]
  let canonicalRGB8Base64: [String]

  init(
    captureSystemUptimeSeconds: [Double],
    frames: [VideoSurfaceCanonicalFrame]
  ) {
    formatVersion = Self.formatVersion
    method = VideoSurfaceMotionEvidence.method
    encoding = Self.encoding
    frameWidthPixels = VideoSurfaceCanonicalFrame.width
    frameHeightPixels = VideoSurfaceCanonicalFrame.height
    channelCount = 3
    bytesPerFrame = VideoSurfaceCanonicalFrame.byteCount
    frameCount = frames.count
    self.captureSystemUptimeSeconds = captureSystemUptimeSeconds
    canonicalRGB8Base64 = frames.map { Data($0.rgb).base64EncodedString() }
  }

  init(
    formatVersion: Int,
    method: String,
    encoding: String,
    frameWidthPixels: Int,
    frameHeightPixels: Int,
    channelCount: Int,
    bytesPerFrame: Int,
    frameCount: Int,
    captureSystemUptimeSeconds: [Double],
    canonicalRGB8Base64: [String]
  ) {
    self.formatVersion = formatVersion
    self.method = method
    self.encoding = encoding
    self.frameWidthPixels = frameWidthPixels
    self.frameHeightPixels = frameHeightPixels
    self.channelCount = channelCount
    self.bytesPerFrame = bytesPerFrame
    self.frameCount = frameCount
    self.captureSystemUptimeSeconds = captureSystemUptimeSeconds
    self.canonicalRGB8Base64 = canonicalRGB8Base64
  }

  static var empty: Self {
    Self(captureSystemUptimeSeconds: [], frames: [])
  }
}

enum NativeRendererRecoveryVisualReplayError: Error, Equatable {
  case contractChanged
  case invalidFrameCount(declared: Int, timestamps: Int, frames: Int)
  case invalidTimestamp(index: Int)
  case timestampsNotStrictlyIncreasing
  case invalidBase64(index: Int)
  case noncanonicalBase64(index: Int)
  case invalidFrameByteCount(index: Int, observed: Int)
}

enum NativeRendererRecoveryVisualReplayEvaluator {
  /// Strictly replays a retained binding. This is intentionally the only path
  /// the device row uses to derive its hashes and adjacent-pixel ratios.
  static func replay(
    _ binding: NativeRendererRecoveryVisualCaptureBinding
  )
    throws -> VideoSurfaceMotionEvidence {
    guard
      binding.formatVersion == NativeRendererRecoveryVisualCaptureBinding.formatVersion,
      binding.method == VideoSurfaceMotionEvidence.method,
      binding.encoding == NativeRendererRecoveryVisualCaptureBinding.encoding,
      binding.frameWidthPixels == VideoSurfaceCanonicalFrame.width,
      binding.frameHeightPixels == VideoSurfaceCanonicalFrame.height,
      binding.channelCount == 3,
      binding.bytesPerFrame == VideoSurfaceCanonicalFrame.byteCount
    else {
      throw NativeRendererRecoveryVisualReplayError.contractChanged
    }

    guard
      binding.frameCount == NativeRendererRecoveryVisualCaptureBinding.requiredFrameCount,
      binding.captureSystemUptimeSeconds.count
      == NativeRendererRecoveryVisualCaptureBinding.requiredFrameCount,
      binding.canonicalRGB8Base64.count
      == NativeRendererRecoveryVisualCaptureBinding.requiredFrameCount
    else {
      throw NativeRendererRecoveryVisualReplayError.invalidFrameCount(
        declared: binding.frameCount,
        timestamps: binding.captureSystemUptimeSeconds.count,
        frames: binding.canonicalRGB8Base64.count
      )
    }

    for (index, timestamp) in binding.captureSystemUptimeSeconds.enumerated() {
      guard timestamp.isFinite, timestamp >= 0 else {
        throw NativeRendererRecoveryVisualReplayError.invalidTimestamp(index: index)
      }
    }
    let timestampsIncrease = zip(
      binding.captureSystemUptimeSeconds,
      binding.captureSystemUptimeSeconds.dropFirst()
    ).allSatisfy { previous, current in previous < current }
    guard timestampsIncrease else {
      throw NativeRendererRecoveryVisualReplayError.timestampsNotStrictlyIncreasing
    }

    let frames = try binding.canonicalRGB8Base64.enumerated().map { index, encoded in
      guard let data = Data(base64Encoded: encoded) else {
        throw NativeRendererRecoveryVisualReplayError.invalidBase64(index: index)
      }
      guard data.base64EncodedString() == encoded else {
        throw NativeRendererRecoveryVisualReplayError.noncanonicalBase64(index: index)
      }
      guard data.count == VideoSurfaceCanonicalFrame.byteCount else {
        throw NativeRendererRecoveryVisualReplayError.invalidFrameByteCount(
          index: index,
          observed: data.count
        )
      }
      return VideoSurfaceCanonicalFrame(rgb: Array(data))
    }
    guard let evidence = VideoSurfaceMotionEvidenceAnalyzer.analyze(frames) else {
      throw NativeRendererRecoveryVisualReplayError.invalidFrameCount(
        declared: binding.frameCount,
        timestamps: binding.captureSystemUptimeSeconds.count,
        frames: frames.count
      )
    }
    return evidence
  }
}

enum NativeRendererRecoveryVisualOracleStatus: String, Codable, Equatable {
  case pass
  case failed
  case notRun = "not-run"
}

struct NativeRendererRecoveryVisualOracleEvidence: Codable, Equatable {
  let formatVersion: Int
  let status: NativeRendererRecoveryVisualOracleStatus
  let reason: String
  let surface: String
  let captureBinding: NativeRendererRecoveryVisualCaptureBinding
  let frameHashes: [String]
  let adjacentChangedPixelRatios: [Double]
  let changedPixelScore: Double
  let distinctFrameHashes: Int
  let minimumChangedPixelScore: Double

  static func evaluated(
    binding: NativeRendererRecoveryVisualCaptureBinding,
    minimumChangedPixelScore: Double
  )
    throws -> Self {
    let motion = try NativeRendererRecoveryVisualReplayEvaluator.replay(binding)
    let distinctFrameHashes = Set(motion.frameHashes).count
    let passed = motion.changedPixelScore >= minimumChangedPixelScore
      && distinctFrameHashes == NativeRendererRecoveryVisualCaptureBinding.requiredFrameCount
    return Self(
      formatVersion: 1,
      status: passed ? .pass : .failed,
      reason: passed
        ? "moving-system-pip-pixels-observed"
        : "system-pip-pixels-frozen-or-duplicated",
      surface: "system-picture-in-picture",
      captureBinding: binding,
      frameHashes: motion.frameHashes,
      adjacentChangedPixelRatios: motion.adjacentChangedPixelRatios,
      changedPixelScore: motion.changedPixelScore,
      distinctFrameHashes: distinctFrameHashes,
      minimumChangedPixelScore: minimumChangedPixelScore
    )
  }

  static func notRun(
    status: NativeRendererRecoveryVisualOracleStatus = .notRun,
    reason: String
  ) -> Self {
    precondition(status != .pass)
    return Self(
      formatVersion: 1,
      status: status,
      reason: reason,
      surface: "system-picture-in-picture",
      captureBinding: .empty,
      frameHashes: [],
      adjacentChangedPixelRatios: [],
      changedPixelScore: 0,
      distinctFrameHashes: 0,
      minimumChangedPixelScore: 0.01
    )
  }
}
