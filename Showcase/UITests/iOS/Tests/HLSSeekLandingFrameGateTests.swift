import XCTest

final class HLSSeekLandingFrameGateTests: XCTestCase {
  func testFrameBeforeLandingCannotSatisfyRecovery() {
    var gate = HLSSeekLandingFrameGate()

    XCTAssertFalse(
      gate.observe(
        nativeTimeMilliseconds: 4000,
        expectedTimeMilliseconds: 12000,
        toleranceMilliseconds: 1500,
        displayedPictures: 11
      )
    )
    XCTAssertNil(gate.displayedPicturesAtLanding)

    XCTAssertFalse(
      gate.observe(
        nativeTimeMilliseconds: 12050,
        expectedTimeMilliseconds: 12000,
        toleranceMilliseconds: 1500,
        displayedPictures: 11
      )
    )
    XCTAssertEqual(gate.landingNativeTimeMilliseconds, 12050)
    XCTAssertEqual(gate.displayedPicturesAtLanding, 11)

    XCTAssertFalse(
      gate.observe(
        nativeTimeMilliseconds: 12100,
        expectedTimeMilliseconds: 12000,
        toleranceMilliseconds: 1500,
        displayedPictures: 11
      )
    )
    XCTAssertTrue(
      gate.observe(
        nativeTimeMilliseconds: 12150,
        expectedTimeMilliseconds: 12000,
        toleranceMilliseconds: 1500,
        displayedPictures: 12
      )
    )
  }

  func testFrameAfterRecordedLandingMayRecoverAfterClockLeavesTolerance() {
    var gate = HLSSeekLandingFrameGate()

    XCTAssertFalse(
      gate.observe(
        nativeTimeMilliseconds: 9950,
        expectedTimeMilliseconds: 10000,
        toleranceMilliseconds: 100,
        displayedPictures: 20
      )
    )
    XCTAssertTrue(
      gate.observe(
        nativeTimeMilliseconds: 10150,
        expectedTimeMilliseconds: 10000,
        toleranceMilliseconds: 100,
        displayedPictures: 21
      )
    )
  }
}
