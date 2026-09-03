import XCTest

/// Device-only transition coverage for native PiP subtitle/OSD composition.
/// Visual subtitle fidelity, HDR/color behavior, and energy impact still
/// require the Matrix H operator record on the target hardware.
final class PiPOverlayDeviceUITests: ShowcaseIOSTestCase {
  private struct PiPOutputIdentityEvidence: Decodable, Equatable {
    let nativeHandleIdentity: UInt64
    let playbackGeneration: UInt64
    let outputIdentity: UInt64

    var qualificationObject: [String: Any] {
      [
        "nativeHandleIdentity": nativeHandleIdentity,
        "playbackGeneration": playbackGeneration,
        "outputIdentity": outputIdentity
      ]
    }
  }

  private struct HLSSeekEvidence: Decodable {
    let formatVersion: Int
    let command: String
    let outcome: String
    let accepted: Bool
    let mediaGeneration: UInt64?
    let durationMilliseconds: Int64?
    let baselineNativeTimeMilliseconds: Int64?
    let expectedTimeMilliseconds: Int64?
    let landingToleranceMilliseconds: Int64?
    let landingNativeTimeMilliseconds: Int64?
    let postCommandDisplayedPictures: UInt64
    let displayedPicturesAtLanding: UInt64?
    let finalDisplayedPictures: UInt64
    let commandToRecoveryMilliseconds: Int?
    let baselinePiPOutputIdentity: PiPOutputIdentityEvidence?
    let landingPiPOutputIdentity: PiPOutputIdentityEvidence?
    let failure: String?

    var qualificationObject: [String: Any] {
      [
        "formatVersion": formatVersion,
        "command": command,
        "outcome": outcome,
        "accepted": accepted,
        "mediaGeneration": mediaGeneration ?? 0,
        "durationMilliseconds": durationMilliseconds ?? -1,
        "baselineNativeTimeMilliseconds": baselineNativeTimeMilliseconds ?? -1,
        "expectedTimeMilliseconds": expectedTimeMilliseconds ?? -1,
        "landingToleranceMilliseconds": landingToleranceMilliseconds ?? -1,
        "landingNativeTimeMilliseconds": landingNativeTimeMilliseconds ?? -1,
        "postCommandDisplayedPictures": postCommandDisplayedPictures,
        "displayedPicturesAtLanding": displayedPicturesAtLanding ?? 0,
        "finalDisplayedPictures": finalDisplayedPictures,
        "commandToRecoveryMilliseconds": commandToRecoveryMilliseconds ?? -1,
        "baselinePiPOutputIdentity": baselinePiPOutputIdentity?.qualificationObject ?? [:],
        "landingPiPOutputIdentity": landingPiPOutputIdentity?.qualificationObject ?? [:]
      ]
    }
  }

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

  func test_nativePiPHLSSeeksRemainActive() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_SEEK_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_SEEK_DEVICE=YES with a seekable Matrix H HLS stream")
    }

    openMatrixH(requiresOverlayComposition: false)
    _ = startPictureInPicture()

    let active = app.descendants(matching: .any)[AccessibilityID.MatrixHValidation.activeLabel]
    let state = app.descendants(matching: .any)[AccessibilityID.MatrixHValidation.stateLabel]
    let displayedPictures = app.descendants(matching: .any)[
      AccessibilityID.MatrixHValidation.displayedPicturesLabel
    ]
    let unexpectedStops = app.descendants(matching: .any)[
      AccessibilityID.MatrixHValidation.unexpectedStopCountLabel
    ]
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)
    revealMeasurement(state, swiping: .up)
    waitForAccessibilityValue(state, equals: "playing", timeout: 20)
    revealMeasurement(displayedPictures, swiping: .up)
    _ = waitForIntegerAccessibilityValue(displayedPictures, greaterThan: 0, timeout: 10)
    var maximumVideoGapMilliseconds = 0
    var commandEvidence: [String: Any] = [:]

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
      transition.tap()
      let seekResult = app.descendants(matching: .any)[resultIdentifier]
      revealMeasurement(seekResult, swiping: .down)
      let result = try waitForHLSSeekEvidence(seekResult, timeout: 10)
      guard result.outcome == "pass" else {
        XCTFail("\(name) HLS seek failed: \(result.failure ?? "unknown failure")")
        return
      }
      XCTAssertEqual(result.formatVersion, 1)
      XCTAssertEqual(result.command, name)
      XCTAssertTrue(result.accepted)
      let generation = try XCTUnwrap(result.mediaGeneration)
      XCTAssertGreaterThan(generation, 0)
      let baselinePiPOutput = try XCTUnwrap(result.baselinePiPOutputIdentity)
      let landingPiPOutput = try XCTUnwrap(result.landingPiPOutputIdentity)
      XCTAssertGreaterThan(baselinePiPOutput.nativeHandleIdentity, 0)
      XCTAssertGreaterThan(baselinePiPOutput.outputIdentity, 0)
      XCTAssertEqual(baselinePiPOutput.playbackGeneration, generation)
      XCTAssertEqual(
        landingPiPOutput,
        baselinePiPOutput,
        "\(name) seek rebuilt or relabelled the native PiP output"
      )
      let duration = try XCTUnwrap(result.durationMilliseconds)
      XCTAssertGreaterThan(duration, 0)
      let baselineTime = try XCTUnwrap(result.baselineNativeTimeMilliseconds)
      let expectedTime = try XCTUnwrap(result.expectedTimeMilliseconds)
      let landingTime = try XCTUnwrap(result.landingNativeTimeMilliseconds)
      let tolerance = try XCTUnwrap(result.landingToleranceMilliseconds)
      switch name {
      case "forward":
        XCTAssertEqual(expectedTime, min(duration, baselineTime + 10000))
        XCTAssertEqual(expectedTime - baselineTime, 10000)
        XCTAssertGreaterThan(landingTime, baselineTime)
      case "backward":
        XCTAssertEqual(expectedTime, max(0, baselineTime - 10000))
        XCTAssertEqual(baselineTime - expectedTime, 10000)
        XCTAssertLessThan(landingTime, baselineTime)
      case "absolute":
        XCTAssertEqual(expectedTime, duration / 2)
        XCTAssertGreaterThan(
          abs(expectedTime - baselineTime),
          tolerance + 5000,
          "Absolute target was close enough for ordinary playback to fake a landing"
        )
      default:
        XCTFail("Unexpected HLS seek command \(name)")
      }
      XCTAssertLessThanOrEqual(abs(landingTime - expectedTime), tolerance)
      let displayedAtLanding = try XCTUnwrap(result.displayedPicturesAtLanding)
      XCTAssertGreaterThanOrEqual(
        displayedAtLanding,
        result.postCommandDisplayedPictures,
        "\(name) seek landing regressed the cumulative display counter"
      )
      XCTAssertGreaterThan(
        result.finalDisplayedPictures,
        displayedAtLanding,
        "\(name) seek published no strictly post-landing displayed frame"
      )
      let gapMilliseconds = try XCTUnwrap(result.commandToRecoveryMilliseconds)
      XCTAssertGreaterThanOrEqual(gapMilliseconds, 0)
      XCTAssertNil(result.failure)
      maximumVideoGapMilliseconds = max(maximumVideoGapMilliseconds, gapMilliseconds)
      commandEvidence[name] = result.qualificationObject
      revealMeasurement(active, swiping: .down)
      waitForAccessibilityValue(active, equals: "yes", timeout: 5)

      XCUIDevice.shared.press(.home)
      if let failure = captureSystemPictureInPictureMotion() {
        XCTFail("\(name) seek PiP motion failed: \(failure)")
      }
      app.activate()
      revealMeasurement(state, swiping: .down)
      waitForAccessibilityValue(state, equals: "playing", timeout: 10)
      revealMeasurement(active, swiping: .up)
      waitForAccessibilityValue(active, equals: "yes", timeout: 10)
    }

    revealMeasurement(unexpectedStops, swiping: .up)
    XCTAssertEqual(
      Int(accessibilityValue(of: unexpectedStops)),
      0,
      "Native PiP stopped during a seek"
    )
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
        "commandEvidence": commandEvidence,
        "events": ["unexpectedStopCount": 0],
        "pipMotion": "pass",
        "inlineRecovery": "pass",
        "measurements": [
          "maximumVideoGapMilliseconds": maximumVideoGapMilliseconds
        ],
        "videoContinuityWithinBudget": maximumVideoGapMilliseconds <= 5000,
        "nativeOutputIdentityStable": true,
        "controls": "pass",
        "libraryErrorCount": 0
      ],
      scenario: "native-hls-seek-continuity"
    )
    #endif
  }

  private func openMatrixH(requiresOverlayComposition: Bool = true) {
    launch(route: .harnessHome)

    let matrix = app.buttons["(h) Native PiP subtitles + OSD"]
    reveal(matrix, swiping: .up)
    XCTAssertTrue(matrix.waitForExistence(timeout: 5))
    matrix.tap()

    let overlaySupport = app.descendants(matching: .any)["validation.matrixH.overlaySupport"]
    revealMeasurement(overlaySupport, swiping: .up)
    if requiresOverlayComposition {
      XCTAssertTrue(
        accessibilityValue(of: overlaySupport).contains("composited"),
        "The linked engine does not advertise native PiP overlay composition"
      )
    }
  }

  private func waitForHLSSeekEvidence(
    _ element: XCUIElement,
    timeout: TimeInterval
  )
    throws -> HLSSeekEvidence {
    let predicate = NSPredicate { _, _ in
      let value = self.accessibilityValue(of: element)
      return element.exists && (value.hasPrefix("pass:") || value.hasPrefix("failed:"))
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected typed HLS seek evidence, got: \(accessibilityValue(of: element))"
    )
    let value = accessibilityValue(of: element)
    let prefix = try XCTUnwrap(
      ["pass:", "failed:"].first(where: { value.hasPrefix($0) }),
      "HLS seek row did not publish a recognized typed-evidence prefix: \(value)"
    )
    let data = try XCTUnwrap(Data(base64Encoded: String(value.dropFirst(prefix.count))))
    let evidence = try JSONDecoder().decode(HLSSeekEvidence.self, from: data)
    XCTAssertEqual(
      value.hasPrefix("\(evidence.outcome):"),
      true,
      "Typed HLS outcome did not match its accessibility prefix"
    )
    return evidence
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
