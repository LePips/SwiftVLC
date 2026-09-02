import UIKit

/// Converts an already-cropped video surface into the exact RGB byte stream
/// hashed by `VideoSurfaceMotionEvidenceAnalyzer`.
func makeCanonicalVideoSurfaceFrame(
  from image: UIImage
) -> VideoSurfaceCanonicalFrame? {
  guard let cgImage = image.cgImage else { return nil }
  let width = VideoSurfaceCanonicalFrame.width
  let height = VideoSurfaceCanonicalFrame.height
  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var rgba = [UInt8](repeating: 0, count: height * bytesPerRow)
  guard
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
    let context = CGContext(
      data: &rgba,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )
  else { return nil }

  context.interpolationQuality = .low
  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
  var rgb: [UInt8] = []
  rgb.reserveCapacity(VideoSurfaceCanonicalFrame.byteCount)
  for offset in stride(from: 0, to: rgba.count, by: bytesPerPixel) {
    rgb.append(rgba[offset])
    rgb.append(rgba[offset + 1])
    rgb.append(rgba[offset + 2])
  }
  return VideoSurfaceCanonicalFrame(rgb: rgb)
}

/// Converts an XCTest screenshot into the deterministic row-major frame used
/// by `VideoOracleAnalyzer`. Downsampling bounds release-run cost while keeping
/// the seek marker wider than several sampled columns.
func makeVideoOracleFrame(
  from image: UIImage,
  maximumDimension: Int = 320
) -> PiPMotionFrame? {
  guard let cgImage = image.cgImage, maximumDimension > 0 else { return nil }
  let sourceWidth = cgImage.width
  let sourceHeight = cgImage.height
  guard sourceWidth > 0, sourceHeight > 0 else { return nil }

  let scale = min(
    1,
    Double(maximumDimension) / Double(max(sourceWidth, sourceHeight))
  )
  let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
  let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
  guard
    let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder32Big.rawValue
    )
  else { return nil }

  context.interpolationQuality = .low
  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
  var pixels: [PiPMotionPixel] = []
  pixels.reserveCapacity(width * height)
  for y in 0..<height {
    for x in 0..<width {
      let offset = y * bytesPerRow + x * bytesPerPixel
      pixels.append(
        PiPMotionPixel(
          red: bytes[offset],
          green: bytes[offset + 1],
          blue: bytes[offset + 2]
        )
      )
    }
  }
  return PiPMotionFrame(width: width, height: height, pixels: pixels)
}
