import CryptoKit
import Foundation

/// Canonical pixels used by release-qualification visual evidence.
///
/// The adapter must crop the exact video surface before scaling it to this
/// fixed 64x36 grid. Keeping this type independent of UIKit makes the hash and
/// adjacent-frame math deterministic and directly unit testable.
struct VideoSurfaceCanonicalFrame: Equatable {
  static let width = 64
  static let height = 36
  static let byteCount = width * height * 3

  let rgb: [UInt8]

  init(rgb: [UInt8]) {
    precondition(rgb.count == Self.byteCount)
    self.rgb = rgb
  }
}

/// Raw, independently recomputable proof that one captured video surface kept
/// changing throughout a sampling window.
struct VideoSurfaceMotionEvidence: Codable, Equatable {
  static let method = "xcui-video-surface-rgb8-64x36-delta12-v1"

  let frameHashes: [String]
  let adjacentChangedPixelRatios: [Double]
  let changedPixelScore: Double
}

enum VideoSurfaceMotionEvidenceAnalyzer {
  private static let hashDomain = Array("swiftvlc-rgb8-64x36-v1\0".utf8)
  private static let pixelDeltaThreshold = 12

  /// Requires at least three captures so a single transition followed by a
  /// freeze cannot be reported as sustained motion. The minimum adjacent-pair
  /// ratio is retained as the score; qualification policy also verifies every
  /// raw ratio and recomputes this minimum.
  static func analyze(
    _ frames: [VideoSurfaceCanonicalFrame]
  ) -> VideoSurfaceMotionEvidence? {
    guard frames.count >= 3 else { return nil }
    let hashes = frames.map(hash)
    let ratios = zip(frames, frames.dropFirst()).map(changedPixelRatio)
    return VideoSurfaceMotionEvidence(
      frameHashes: hashes,
      adjacentChangedPixelRatios: ratios,
      changedPixelScore: ratios.min() ?? 0
    )
  }

  static func hash(_ frame: VideoSurfaceCanonicalFrame) -> String {
    var bytes = hashDomain
    bytes.append(UInt8((VideoSurfaceCanonicalFrame.width >> 8) & 0xFF))
    bytes.append(UInt8(VideoSurfaceCanonicalFrame.width & 0xFF))
    bytes.append(UInt8((VideoSurfaceCanonicalFrame.height >> 8) & 0xFF))
    bytes.append(UInt8(VideoSurfaceCanonicalFrame.height & 0xFF))
    bytes.append(contentsOf: frame.rgb)
    return SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
  }

  static func changedPixelRatio(
    _ first: VideoSurfaceCanonicalFrame,
    _ second: VideoSurfaceCanonicalFrame
  ) -> Double {
    var changedPixels = 0
    for offset in stride(from: 0, to: VideoSurfaceCanonicalFrame.byteCount, by: 3) {
      let redDelta = abs(Int(first.rgb[offset]) - Int(second.rgb[offset]))
      let greenDelta = abs(Int(first.rgb[offset + 1]) - Int(second.rgb[offset + 1]))
      let blueDelta = abs(Int(first.rgb[offset + 2]) - Int(second.rgb[offset + 2]))
      if max(redDelta, greenDelta, blueDelta) >= pixelDeltaThreshold {
        changedPixels += 1
      }
    }
    return Double(changedPixels)
      / Double(VideoSurfaceCanonicalFrame.width * VideoSurfaceCanonicalFrame.height)
  }
}
