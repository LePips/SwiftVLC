import XCTest

/// Device-only transition coverage for native PiP subtitle/OSD composition.
/// Visual subtitle fidelity, HDR/color behavior, and energy impact still
/// require the Matrix H operator record on the target hardware.
final class PiPOverlayDeviceUITests: ShowcaseIOSTestCase {
  func test_nativePiPOverlayTransitionsRemainOperational() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_OVERLAY_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_OVERLAY_DEVICE=YES with a subtitled Matrix H stream")
    }

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }

    launch(route: .harnessHome)
    app.tap()

    let matrix = app.buttons["(h) Native PiP subtitles + OSD"]
    XCTAssertTrue(matrix.waitForExistence(timeout: 5))
    matrix.tap()

    let overlaySupport = app.descendants(matching: .any)["validation.matrixH.overlaySupport"]
    reveal(overlaySupport, swiping: .up)
    XCTAssertTrue(overlaySupport.waitForExistence(timeout: 10))
    XCTAssertTrue(
      overlaySupport.label.contains("composited"),
      "The linked engine does not advertise native PiP overlay composition"
    )

    let startPiP = app.buttons["Start PiP"]
    reveal(startPiP, swiping: .down)
    waitUntilEnabled(startPiP, timeout: 20)
    startPiP.tap()

    let stopPiP = app.buttons["Stop PiP"]
    XCTAssertTrue(stopPiP.waitForExistence(timeout: 10), "Native PiP did not become active")

    let marquee = app.switches["validation.matrixH.marquee"]
    reveal(marquee, swiping: .up)
    XCTAssertTrue(marquee.isHittable)
    marquee.tap()
    XCTAssertEqual(marquee.value as? String, "1")

    for title in ["Seek +10 seconds", "Seek −10 seconds", "Reload same media"] {
      let transition = app.buttons[title]
      reveal(transition, swiping: .down)
      XCTAssertTrue(transition.isHittable)
      transition.tap()
    }

    XCTAssertTrue(stopPiP.exists, "Native PiP stopped during overlay transitions")
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
