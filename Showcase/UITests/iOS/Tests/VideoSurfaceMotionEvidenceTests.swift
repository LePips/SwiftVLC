import XCTest

final class VideoSurfaceMotionEvidenceTests: XCTestCase {
  func testCanonicalHashIncludesTheDomainDimensionsAndRGBBytes() {
    let frame = VideoSurfaceCanonicalFrame(
      rgb: [UInt8](repeating: 0, count: VideoSurfaceCanonicalFrame.byteCount)
    )

    XCTAssertEqual(
      VideoSurfaceMotionEvidenceAnalyzer.hash(frame),
      "bd4967f5561762781920d2bfe6ae1461891b3101d5cf3104092e845788532826"
    )
  }

  func testEveryAdjacentPairContributesAndTheWeakestPairIsTheScore() throws {
    let black = [UInt8](repeating: 0, count: VideoSurfaceCanonicalFrame.byteCount)
    var firstChange = black
    var secondChange = firstChange
    // Change 24 of 2304 pixels in the first transition.
    for pixel in 0..<24 {
      firstChange[pixel * 3] = 12
      secondChange[pixel * 3] = 12
    }
    // Change only 12 more pixels in the second transition.
    for pixel in 24..<36 {
      secondChange[pixel * 3 + 1] = 255
    }

    let evidence = try XCTUnwrap(VideoSurfaceMotionEvidenceAnalyzer.analyze([
      VideoSurfaceCanonicalFrame(rgb: black),
      VideoSurfaceCanonicalFrame(rgb: firstChange),
      VideoSurfaceCanonicalFrame(rgb: secondChange)
    ]))

    XCTAssertEqual(evidence.frameHashes.count, 3)
    XCTAssertEqual(Set(evidence.frameHashes).count, 3)
    XCTAssertEqual(evidence.adjacentChangedPixelRatios, [24.0 / 2304.0, 12.0 / 2304.0])
    XCTAssertEqual(evidence.changedPixelScore, 12.0 / 2304.0)
  }

  func testALaterFreezeCannotBeHiddenByAnEarlierTransition() throws {
    let black = VideoSurfaceCanonicalFrame(
      rgb: [UInt8](repeating: 0, count: VideoSurfaceCanonicalFrame.byteCount)
    )
    let white = VideoSurfaceCanonicalFrame(
      rgb: [UInt8](repeating: 255, count: VideoSurfaceCanonicalFrame.byteCount)
    )

    let evidence = try XCTUnwrap(
      VideoSurfaceMotionEvidenceAnalyzer.analyze([black, white, white])
    )

    XCTAssertEqual(evidence.adjacentChangedPixelRatios, [1, 0])
    XCTAssertEqual(evidence.changedPixelScore, 0)
    XCTAssertEqual(Set(evidence.frameHashes).count, 2)
  }

  func testDeltaThresholdIsInclusiveAndFewerThanThreeFramesFailClosed() {
    let base = [UInt8](repeating: 100, count: VideoSurfaceCanonicalFrame.byteCount)
    var below = base
    var exact = base
    below[0] = 111
    exact[0] = 112

    XCTAssertEqual(
      VideoSurfaceMotionEvidenceAnalyzer.changedPixelRatio(
        VideoSurfaceCanonicalFrame(rgb: base),
        VideoSurfaceCanonicalFrame(rgb: below)
      ), 0
    )
    XCTAssertEqual(
      VideoSurfaceMotionEvidenceAnalyzer.changedPixelRatio(
        VideoSurfaceCanonicalFrame(rgb: base),
        VideoSurfaceCanonicalFrame(rgb: exact)
      ), 1.0 / 2304.0
    )
    XCTAssertNil(
      VideoSurfaceMotionEvidenceAnalyzer.analyze([
        VideoSurfaceCanonicalFrame(rgb: base),
        VideoSurfaceCanonicalFrame(rgb: exact)
      ])
    )
  }
}
