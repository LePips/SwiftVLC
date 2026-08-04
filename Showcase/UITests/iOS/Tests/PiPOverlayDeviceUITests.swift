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

    openMatrixH()
    let stopPiP = startPictureInPicture()

    let marquee = app.switches["validation.matrixH.marquee"]
    reveal(marquee, swiping: .up)
    XCTAssertTrue(marquee.isHittable)
    marquee.tap()
    let marqueeEnabled = NSPredicate { _, _ in marquee.value as? String == "1" }
    let marqueeExpectation = expectation(for: marqueeEnabled, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [marqueeExpectation], timeout: 3),
      .completed,
      "Marquee switch did not become enabled"
    )

    for title in ["Seek +10 seconds", "Seek −10 seconds", "Reload same media"] {
      let transition = app.buttons[title]
      reveal(transition, swiping: .up)
      XCTAssertTrue(transition.isHittable)
      transition.tap()
    }

    XCTAssertTrue(stopPiP.exists, "Native PiP stopped during overlay transitions")
    assertNoLibraryErrors()
    #endif
  }

  func test_nativePiPHLSSeekAndReloadRemainActive() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_SEEK_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_SEEK_DEVICE=YES with a seekable Matrix H HLS stream")
    }

    openMatrixH()
    _ = startPictureInPicture()

    let active = app.descendants(matching: .any)[AccessibilityID.MatrixHValidation.activeLabel]
    let state = app.descendants(matching: .any)[AccessibilityID.MatrixHValidation.stateLabel]
    let displayedPictures = app.descendants(matching: .any)[
      AccessibilityID.MatrixHValidation.displayedPicturesLabel
    ]
    let unexpectedStops = app.descendants(matching: .any)[
      AccessibilityID.MatrixHValidation.unexpectedStopCountLabel
    ]
    waitForLabel(active, equals: "yes", timeout: 10)
    waitForLabel(state, equals: "playing", timeout: 20)
    var displayed = waitForIntegerLabel(displayedPictures, greaterThan: 0, timeout: 10)
    var maximumVideoGapMilliseconds = 0

    let transitions = [
      (
        "forward",
        AccessibilityID.MatrixHValidation.seekForwardButton,
        AccessibilityID.MatrixHValidation.forwardResultLabel
      ),
      (
        "backward",
        AccessibilityID.MatrixHValidation.seekBackwardButton,
        AccessibilityID.MatrixHValidation.backwardResultLabel
      ),
      (
        "absolute",
        AccessibilityID.MatrixHValidation.seekAbsoluteButton,
        AccessibilityID.MatrixHValidation.absoluteResultLabel
      )
    ]
    for (name, identifier, resultIdentifier) in transitions {
      let transition = app.buttons[identifier]
      reveal(transition, swiping: .up)
      XCTAssertTrue(transition.isHittable)
      let started = ContinuousClock.now
      transition.tap()
      let seekResult = app.descendants(matching: .any)[resultIdentifier]
      waitForLabel(seekResult, equals: "accepted", timeout: 3)
      displayed = waitForIntegerLabel(
        displayedPictures,
        greaterThan: displayed,
        timeout: 5
      )
      let elapsed = started.duration(to: .now)
      let gapMilliseconds = Int(elapsed / .milliseconds(1))
      maximumVideoGapMilliseconds = max(maximumVideoGapMilliseconds, gapMilliseconds)
      waitForLabel(active, equals: "yes", timeout: 5)

      XCUIDevice.shared.press(.home)
      if let failure = captureSystemPictureInPictureMotion() {
        XCTFail("\(name) seek PiP motion failed: \(failure)")
      }
      app.activate()
      waitForLabel(state, equals: "playing", timeout: 10)
      waitForLabel(active, equals: "yes", timeout: 10)
    }

    XCTAssertEqual(Int(unexpectedStops.label), 0, "Native PiP stopped during a seek")
    XCTAssertLessThanOrEqual(
      maximumVideoGapMilliseconds,
      5000,
      "Video did not resume within the 5-second continuity budget"
    )
    assertNoLibraryErrors()
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "native-hls-seek-continuity",
        "seekResults": [
          "forward": "pass",
          "backward": "pass",
          "absolute": "pass"
        ],
        "events": ["unexpectedStopCount": 0],
        "pipMotion": "pass",
        "inlineRecovery": "pass",
        "measurements": [
          "maximumVideoGapMilliseconds": maximumVideoGapMilliseconds
        ],
        "videoContinuityWithinBudget": maximumVideoGapMilliseconds <= 5000,
        "controls": "pass",
        "libraryErrorCount": 0
      ],
      scenario: "native-hls-seek-continuity"
    )
    #endif
  }

  private func openMatrixH() {
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }

    launch(route: .harnessHome)
    app.tap()

    let matrix = app.buttons["(h) Native PiP subtitles + OSD"]
    reveal(matrix, swiping: .up)
    XCTAssertTrue(matrix.waitForExistence(timeout: 5))
    matrix.tap()

    let overlaySupport = app.descendants(matching: .any)["validation.matrixH.overlaySupport"]
    reveal(overlaySupport, swiping: .up)
    XCTAssertTrue(overlaySupport.waitForExistence(timeout: 10))
    XCTAssertTrue(
      overlaySupport.label.contains("composited"),
      "The linked engine does not advertise native PiP overlay composition"
    )
  }

  private func startPictureInPicture() -> XCUIElement {
    let startPiP = app.buttons["Start PiP"]
    reveal(startPiP, swiping: .down)
    waitUntilEnabled(startPiP, timeout: 20)
    startPiP.tap()

    let stopPiP = app.buttons["Stop PiP"]
    XCTAssertTrue(stopPiP.waitForExistence(timeout: 10), "Native PiP did not become active")
    return stopPiP
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
