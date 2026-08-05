import XCTest

/// Candidate-bound VOD transport qualification across libVLC-native and
/// direct sample-buffer PiP while the real system window is active.
final class PiPVODControlsDeviceUITests: ShowcaseIOSTestCase {
  func test_vodControlsAcrossNativeAndDirectBackends() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_VOD_CONTROLS_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_VOD_CONTROLS_DEVICE=YES for candidate-bound hardware runs")
    }

    let native = try runControls(renderingPath: "native")
    let direct = try runControls(renderingPath: "direct")
    let unexpectedStops = try unexpectedStopCount(in: native)
      + unexpectedStopCount(in: direct)
    XCTAssertEqual(unexpectedStops, 0)
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "vod-controls",
        "events": [
          "started": true,
          "unexpectedStopCount": unexpectedStops,
          "order": "pass"
        ],
        "controls": [
          "play": "pass",
          "pause": "pass",
          "scrub": "pass",
          "skipForward": "pass",
          "skipBackward": "pass"
        ],
        "backendResults": [
          "native": native,
          "direct": direct
        ],
        "systemPiPMotion": [
          "native": "pass",
          "direct": "pass"
        ]
      ],
      scenario: "vod-controls"
    )
    #endif
  }

  private func runControls(renderingPath: String) throws -> [String: Any] {
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: renderingPath)
    launch(route: .pipVODControlsValidation)
    app.tap()

    let state = element(AccessibilityID.PiPVODControlsValidation.stateLabel)
    let possible = element(AccessibilityID.PiPVODControlsValidation.possibleLabel)
    let active = element(AccessibilityID.PiPVODControlsValidation.activeLabel)
    let result = element(AccessibilityID.PiPVODControlsValidation.resultLabel)
    let run = app.buttons[AccessibilityID.PiPVODControlsValidation.runButton]
    let stop = app.buttons[AccessibilityID.PiPVODControlsValidation.stopButton]
    let error = element(AccessibilityID.PiPVODControlsValidation.errorLabel)

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(possible, equals: "yes", timeout: 15)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForLabel(result, equals: "ready-for-motion-check", timeout: 45)
    waitForLabel(active, equals: "yes", timeout: 5)
    XCTAssertFalse(error.exists, "\(renderingPath) controls failed: \(error.label)")

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(renderingPath) VOD controls PiP motion failed: \(failure)")
    }
    app.activate()
    waitForLabel(active, equals: "yes", timeout: 10)
    reveal(stop)
    XCTAssertTrue(stop.isEnabled)
    stop.tap()
    waitForPrefix(result, prefix: "pass:", timeout: 15)
    waitForLabel(active, equals: "no", timeout: 10)
    XCTAssertFalse(error.exists, "\(renderingPath) finalization failed: \(error.label)")
    assertNoLibraryErrors()

    let evidence = try decodeEvidence(result.label)
    XCTAssertEqual(evidence["backend"] as? String, renderingPath)
    let controls = try XCTUnwrap(evidence["controls"] as? [String: Any])
    for control in ["play", "pause", "scrub", "skipForward", "skipBackward"] {
      XCTAssertEqual(controls[control] as? String, "pass", "\(renderingPath) \(control)")
    }
    return evidence
  }

  private func unexpectedStopCount(in evidence: [String: Any]) throws -> Int {
    let events = try XCTUnwrap(evidence["events"] as? [String: Any])
    XCTAssertEqual(events["started"] as? Bool, true)
    XCTAssertEqual(events["order"] as? String, "pass")
    return try XCTUnwrap(events["unexpectedStopCount"] as? Int)
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let encoded = String(label.dropFirst(prefix.count))
    let data = try XCTUnwrap(Data(base64Encoded: encoded))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func waitForPrefix(
    _ element: XCUIElement,
    prefix: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      element.exists && element.label.hasPrefix(prefix)
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected prefix \(prefix), got: \(element.label)"
    )
  }

  private func replaceLaunchArgument(_ name: String, with value: String) {
    while let index = app.launchArguments.firstIndex(of: name) {
      app.launchArguments.remove(at: index)
      if index < app.launchArguments.endIndex {
        app.launchArguments.remove(at: index)
      }
    }
    app.launchArguments += [name, value]
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }
}
