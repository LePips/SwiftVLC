import UIKit
import XCTest

final class VideoOracleAnalyzerTests: XCTestCase {
  private let analyzer = VideoOracleAnalyzer()

  func testSeekOracleDecodesEveryBandAndMovingMarker() throws {
    for band in 0..<6 {
      let observation = try XCTUnwrap(
        analyzer.seekObservation(in: seekFrame(band: band, secondsIntoBand: 3.5))
      )
      XCTAssertEqual(observation.bandIndex, band)
      XCTAssertEqual(observation.secondsIntoBand, 3.5, accuracy: 0.15)
      XCTAssertEqual(observation.timelineSeconds, Double(band * 10) + 3.5, accuracy: 0.15)
      XCTAssertGreaterThan(observation.markerContrast, 50)
    }
  }

  func testSeekOracleRejectsClockOnlyFrameWithoutMarker() {
    let color = pixel(VideoOracleRGB(red: 0x20, green: 0x40, blue: 0xC0))
    let frame = PiPMotionFrame(
      width: 160,
      height: 90,
      pixels: [PiPMotionPixel](repeating: color, count: 160 * 90)
    )

    XCTAssertNil(analyzer.seekObservation(in: frame))
  }

  func testAllIntraOracleDecodesExactFrameWithColorConversionNoise() {
    for index in [0, 1, 4, 5, 42, 73, 119] {
      let color = VideoOracleAnalyzer.frameColor(index: index)
      let shifted = VideoOracleRGB(
        red: color.red + 5,
        green: color.green - 4,
        blue: color.blue + 3
      )
      XCTAssertEqual(analyzer.allIntraFrameIndex(in: solidFrame(color: shifted)), index)
    }
  }

  func testAllIntraOracleRejectsAmbiguousMidpoint() {
    let first = VideoOracleAnalyzer.frameColor(index: 0)
    let second = VideoOracleAnalyzer.frameColor(index: 1)
    let midpoint = VideoOracleRGB(
      red: (first.red + second.red) / 2,
      green: (first.green + second.green) / 2,
      blue: (first.blue + second.blue) / 2
    )

    XCTAssertNil(analyzer.allIntraFrameIndex(in: solidFrame(color: midpoint)))
  }

  func testScreenshotAdapterPreservesColorAndBoundsWork() throws {
    let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 360))
    let image = renderer.image { context in
      UIColor(red: 32 / 255, green: 64 / 255, blue: 192 / 255, alpha: 1).setFill()
      context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
    }

    let frame = try XCTUnwrap(makeVideoOracleFrame(from: image, maximumDimension: 160))

    XCTAssertEqual(frame.width, 160)
    XCTAssertEqual(frame.height, 90)
    let sample = frame.pixels[frame.pixels.count / 2]
    XCTAssertEqual(sample.red, 32, accuracy: 2)
    XCTAssertEqual(sample.green, 64, accuracy: 2)
    XCTAssertEqual(sample.blue, 192, accuracy: 2)
  }

  private func seekFrame(band: Int, secondsIntoBand: Double) -> PiPMotionFrame {
    let width = 160
    let height = 90
    let colors = [
      VideoOracleRGB(red: 0xC0, green: 0x20, blue: 0x20),
      VideoOracleRGB(red: 0x20, green: 0xA0, blue: 0x40),
      VideoOracleRGB(red: 0x20, green: 0x40, blue: 0xC0),
      VideoOracleRGB(red: 0xC0, green: 0xA0, blue: 0x20),
      VideoOracleRGB(red: 0xA0, green: 0x20, blue: 0xA0),
      VideoOracleRGB(red: 0x20, green: 0xA0, blue: 0xA0)
    ]
    var pixels = [PiPMotionPixel](
      repeating: pixel(colors[band]),
      count: width * height
    )
    let markerStart = Int(((40 + secondsIntoBand * 56) / 640 * Double(width)).rounded())
    let markerWidth = max(1, Int((24.0 / 640 * Double(width)).rounded()))
    let markerYStart = Int((80.0 / 360 * Double(height)).rounded())
    let markerYEnd = Int((280.0 / 360 * Double(height)).rounded())
    for y in markerYStart..<markerYEnd {
      for x in markerStart..<min(width, markerStart + markerWidth) {
        pixels[y * width + x] = PiPMotionPixel(red: 255, green: 255, blue: 255)
      }
    }
    return PiPMotionFrame(width: width, height: height, pixels: pixels)
  }

  private func solidFrame(color: VideoOracleRGB) -> PiPMotionFrame {
    let value = pixel(color)
    return PiPMotionFrame(
      width: 64,
      height: 36,
      pixels: [PiPMotionPixel](repeating: value, count: 64 * 36)
    )
  }

  private func pixel(_ color: VideoOracleRGB) -> PiPMotionPixel {
    PiPMotionPixel(
      red: UInt8(clamping: Int(color.red.rounded())),
      green: UInt8(clamping: Int(color.green.rounded())),
      blue: UInt8(clamping: Int(color.blue.rounded()))
    )
  }
}
