import XCTest

/// Physical-device proof that a native AVKit controller survives a media
/// replacement on the same Player. The local validation stream configuration
/// is intentionally not committed, so opt in explicitly when those URLs are
/// available to the device running the test.
final class PiPContinuityDeviceUITests: ShowcaseIOSTestCase {
  func test_nativePiPSurvivesSamePlayerReplacement() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_CONTINUITY_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_CONTINUITY_DEVICE=YES after configuring Matrix A streams")
    }

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }

    launch(route: .harnessHome)
    app.tap()

    let matrix = app.buttons["(a) PiP survival across load()"]
    XCTAssertTrue(matrix.waitForExistence(timeout: 5))
    matrix.tap()

    let initialMedia = app.buttons["Load vod"]
    reveal(initialMedia, swiping: .up)
    XCTAssertTrue(initialMedia.isHittable)
    initialMedia.tap()

    let startPiP = app.buttons["Start PiP"]
    reveal(startPiP, swiping: .down)
    waitUntilEnabled(startPiP, timeout: 20)
    startPiP.tap()

    let stopPiP = app.buttons["Stop PiP"]
    XCTAssertTrue(stopPiP.waitForExistence(timeout: 10), "Native PiP did not become active")

    let successorMedia = app.buttons["Load liveTS"]
    reveal(successorMedia, swiping: .up)
    XCTAssertTrue(successorMedia.isHittable)
    successorMedia.tap()

    let restored = app.descendants(matching: .any)["validation.matrixA.continuity"]
    let restoredPredicate = NSPredicate { _, _ in restored.label.contains("restored") }
    let restoredExpectation = expectation(for: restoredPredicate, evaluatedWith: NSObject())
    XCTAssertTrue(
      XCTWaiter.wait(for: [restoredExpectation], timeout: 10) == .completed,
      "No restored continuity event was recorded after same-player replacement"
    )
    XCTAssertTrue(stopPiP.exists, "The AVKit session stopped during media replacement")
    assertNoLibraryErrors()
    #endif
  }

  private enum ScrollDirection {
    case up
    case down
  }

  private func reveal(_ element: XCUIElement, swiping direction: ScrollDirection) {
    for _ in 0..<8 where !element.isHittable {
      switch direction {
      case .up: app.swipeUp()
      case .down: app.swipeDown()
      }
    }
  }

  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in element.exists && element.isEnabled }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }
}
