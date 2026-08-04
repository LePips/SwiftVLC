import XCTest

/// Candidate-bound proof of the bounded deferred-pause state machine through
/// the exact AVKit command entry point and a Release-build fault injector.
final class PiPDeferredPauseDeviceUITests: ShowcaseIOSTestCase {
  func test_deferredPauseRejectionAndCancellationStayTruthful() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_DEFERRED_PAUSE_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_DEFERRED_PAUSE_DEVICE=YES for candidate-bound hardware runs")
    }

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    launch(route: .pipDeferredPauseValidation)
    app.tap()

    let state = element(AccessibilityID.PiPDeferredPauseValidation.stateLabel)
    let possible = element(AccessibilityID.PiPDeferredPauseValidation.possibleLabel)
    let active = element(AccessibilityID.PiPDeferredPauseValidation.activeLabel)
    let result = element(AccessibilityID.PiPDeferredPauseValidation.resultLabel)
    let toggle = app.buttons[AccessibilityID.PiPDeferredPauseValidation.toggleButton]
    let run = app.buttons[AccessibilityID.PiPDeferredPauseValidation.runButton]
    let error = element(AccessibilityID.PiPDeferredPauseValidation.errorLabel)

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(possible, equals: "yes", timeout: 15)
    reveal(toggle)
    toggle.tap()
    waitForLabel(active, equals: "yes", timeout: 10)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("Deferred-pause PiP motion failed before command testing: \(failure)")
    }
    app.activate()
    waitForLabel(active, equals: "yes", timeout: 10)

    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForPrefix(result, prefix: "pass:", timeout: 40)
    XCTAssertFalse(error.exists, "Validation surface reported: \(error.label)")

    let evidence = try decodeEvidence(result.label)
    XCTAssertEqual(value(at: ["permanentCase", "outcome"], in: evidence) as? String, "rejected")
    XCTAssertEqual(value(at: ["transientCase", "outcome"], in: evidence) as? String, "issued")
    XCTAssertEqual(evidence["cancellationCases"] as? String, "pass")
    XCTAssertEqual(evidence["endlessTaskCount"] as? Int, 0)
    XCTAssertEqual(evidence["duplicatePauseCount"] as? Int, 0)
    XCTAssertEqual(evidence["truthfulControls"] as? Bool, true)
    attachQualificationEvidence(evidence, scenario: "deferred-pause-rejection")
    assertNoLibraryErrors()
    #endif
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let encoded = String(label.dropFirst(prefix.count))
    let data = try XCTUnwrap(Data(base64Encoded: encoded))
    return try XCTUnwrap(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )
  }

  private func value(at path: [String], in root: [String: Any]) -> Any? {
    path.reduce(root as Any?) { value, key in
      (value as? [String: Any])?[key]
    }
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

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }
}
