import UIKit

func makePiPMotionFrame(
  from image: UIImage,
  maximumDimension: Int = 240
) -> PiPMotionFrame? {
  guard let cgImage = image.cgImage else { return nil }

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
  let colorSpace = CGColorSpaceCreateDeviceRGB()
  let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
    | CGBitmapInfo.byteOrder32Big.rawValue
  var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)

  guard
    let context = CGContext(
      data: &bytes,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: colorSpace,
      bitmapInfo: bitmapInfo
    )
  else { return nil }

  context.interpolationQuality = .low
  let bounds = CGRect(x: 0, y: 0, width: width, height: height)
  context.draw(cgImage, in: bounds)

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

func croppedPiPMotionRegion(
  _ image: UIImage,
  region: PiPMotionRegion,
  frameWidth: Int,
  frameHeight: Int
) -> UIImage? {
  guard
    let cgImage = image.cgImage,
    frameWidth > 0,
    frameHeight > 0
  else { return nil }

  let scaleX = Double(cgImage.width) / Double(frameWidth)
  let scaleY = Double(cgImage.height) / Double(frameHeight)
  let imageBounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
  let pixelRegion = CGRect(
    x: Double(region.x) * scaleX,
    y: Double(region.y) * scaleY,
    width: Double(region.width) * scaleX,
    height: Double(region.height) * scaleY
  ).integral.intersection(imageBounds)
  guard pixelRegion.width > 0, pixelRegion.height > 0 else { return nil }
  guard let cropped = cgImage.cropping(to: pixelRegion) else { return nil }
  return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}

func croppedSystemPictureInPictureRegion(
  _ image: UIImage,
  region: SystemPictureInPictureWindowRegion
) -> UIImage? {
  guard let cgImage = image.cgImage else { return nil }
  let bounds = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)
  let crop = CGRect(
    x: Double(cgImage.width) * region.normalizedX,
    y: Double(cgImage.height) * region.normalizedY,
    width: Double(cgImage.width) * region.normalizedWidth,
    height: Double(cgImage.height) * region.normalizedHeight
  ).integral.intersection(bounds)
  guard crop.width > 0, crop.height > 0, let cropped = cgImage.cropping(to: crop) else {
    return nil
  }
  return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}

func pictureInPicturePixelSummary(
  _ image: UIImage
) -> SystemPictureInPicturePixelSummary? {
  guard let frame = makePiPMotionFrame(from: image) else { return nil }
  let pixels = frame.pixels
  guard !pixels.isEmpty else { return nil }
  var bright = 0
  var saturated = 0
  var yellow = 0
  var green = 0
  var nonGray = 0
  var redTotal: UInt64 = 0
  var greenTotal: UInt64 = 0
  var blueTotal: UInt64 = 0
  for pixel in pixels {
    let red = Int(pixel.red)
    let greenValue = Int(pixel.green)
    let blue = Int(pixel.blue)
    let maximum = max(red, greenValue, blue)
    let minimum = min(red, greenValue, blue)
    if minimum >= 220 {
      bright += 1
    }
    if maximum >= 150, maximum - minimum >= 80 {
      saturated += 1
    }
    if red >= 180, greenValue >= 160, blue <= 140 {
      yellow += 1
    }
    if greenValue >= 140, greenValue >= red + 35, greenValue >= blue + 20 {
      green += 1
    }
    if maximum - minimum >= 30 {
      nonGray += 1
    }
    redTotal += UInt64(pixel.red)
    greenTotal += UInt64(pixel.green)
    blueTotal += UInt64(pixel.blue)
  }
  let count = Double(pixels.count)
  return SystemPictureInPicturePixelSummary(
    sampledPixels: pixels.count,
    brightPixelRatio: Double(bright) / count,
    saturatedPixelRatio: Double(saturated) / count,
    yellowPixelRatio: Double(yellow) / count,
    greenPixelRatio: Double(green) / count,
    nonGrayPixelRatio: Double(nonGray) / count,
    meanRed: Double(redTotal) / count,
    meanGreen: Double(greenTotal) / count,
    meanBlue: Double(blueTotal) / count
  )
}

func systemPiPMotionDiagnostics(_ analysis: PiPMotionRegionAnalysis) -> String {
  let regionDescription = analysis.region.map {
    "x=\($0.x),y=\($0.y),w=\($0.width),h=\($0.height)"
  } ?? "none"
  let pairMotion = analysis.pairMotionRatios
    .map { String(format: "%.4f", $0) }
    .joined(separator: ",")
  let nonBlack = analysis.frameNonBlackRatios
    .map { String(format: "%.4f", $0) }
    .joined(separator: ",")

  return """
  result=\(analysis.failure?.rawValue ?? "pass")
  frame=\(analysis.frameWidth)x\(analysis.frameHeight)
  region=\(regionDescription)
  region.source=\(analysis.candidateSource?.rawValue ?? "none")
  geometry.area=\(String(format: "%.4f", analysis.regionAreaRatio))
  geometry.aspect=\(String(format: "%.4f", analysis.regionAspectRatio))
  geometry.persistentFill=\(String(format: "%.4f", analysis.persistentFillRatio))
  persistent.components=\(analysis.persistentComponentCount)
  persistent.largestArea=\(String(format: "%.4f", analysis.largestPersistentComponentAreaRatio))
  pairs.matching=\(analysis.matchingPairCount)/\(analysis.requiredPairCount)
  pairs.sustainedMotion=\(analysis.sustainedMotionPairCount)/\(analysis.requiredPairCount)
  pairs.motionRatios=[\(pairMotion)]
  frames.nonBlack=\(analysis.nonBlackFrameCount)/\(analysis.requiredNonBlackFrameCount) required
  frames.nonBlackRatios=[\(nonBlack)]
  drift.horizontal=\(String(format: "%.4f", analysis.horizontalCenterDriftRatio))
  drift.vertical=\(String(format: "%.4f", analysis.verticalCenterDriftRatio))
  """
}
