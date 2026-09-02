import XCTest

extension VideoSurfaceMotionEvidenceTests {
  func testRationalFloorCeilingAndMultiplesRemainDistinct() {
    let result = PiPCadenceProbeDeltaAnalyzer.classify(
      profile: .fps5994,
      histogram: [
        .init(deltaMicroseconds: 16683, count: 1),
        .init(deltaMicroseconds: 16684, count: 1),
        .init(deltaMicroseconds: 33366, count: 1),
        .init(deltaMicroseconds: 33367, count: 1)
      ],
      deltaOverflowCount: 0
    )

    XCTAssertEqual(result.exactIntervalCount, 2)
    XCTAssertEqual(result.multipleIntervalCount, 2)
    XCTAssertEqual(result.estimatedSkippedPictureCount, 2)
    XCTAssertEqual(result.unclassifiedIntervalCount, 0)
  }

  func testVFRChoosesTheSmallestTruthfulFixtureMultiple() {
    let result = PiPCadenceProbeDeltaAnalyzer.classify(
      profile: .vfr,
      histogram: [
        .init(deltaMicroseconds: 41667, count: 1),
        .init(deltaMicroseconds: 16667, count: 1),
        .init(deltaMicroseconds: 83333, count: 1)
      ],
      deltaOverflowCount: 0
    )

    XCTAssertEqual(result.exactIntervalCount, 2)
    XCTAssertEqual(result.multipleIntervalCount, 1)
    XCTAssertEqual(result.estimatedSkippedPictureCount, 1)
    XCTAssertEqual(result.unclassifiedIntervalCount, 0)
  }

  func testDuplicateBackwardOverflowAndUnknownAreNotHiddenAsCadence() {
    let result = PiPCadenceProbeDeltaAnalyzer.classify(
      profile: .fps30,
      histogram: [
        .init(deltaMicroseconds: -1, count: 2),
        .init(deltaMicroseconds: 0, count: 3),
        .init(deltaMicroseconds: 12345, count: 4)
      ],
      deltaOverflowCount: 5
    )

    XCTAssertEqual(result.redisplayCount, 3)
    XCTAssertEqual(result.backwardCount, 2)
    XCTAssertEqual(result.unclassifiedIntervalCount, 4)
    XCTAssertEqual(result.deltaOverflowCount, 5)
    XCTAssertEqual(result.exactIntervalCount, 0)
    XCTAssertEqual(result.multipleIntervalCount, 0)
  }
}
