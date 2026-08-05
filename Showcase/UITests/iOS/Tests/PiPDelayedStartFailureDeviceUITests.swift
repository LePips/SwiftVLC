import XCTest

/// Candidate-bound proof that a real accepted AVKit start followed by a
/// deterministic delayed delegate failure keeps ordered controller/media
/// attribution.
final class PiPDelayedStartFailureDeviceUITests: ShowcaseIOSTestCase {
  func test_acceptedStartRetainsAttributionThroughDelayedFailure() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_DELAYED_START_FAILURE_DEVICE"] == "YES" else {
      throw XCTSkip(
        "Set SWIFTVLC_PIP_DELAYED_START_FAILURE_DEVICE=YES for candidate-bound hardware runs"
      )
    }

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    launch(route: .pipDelayedStartFailureValidation)
    app.tap()

    let state = element(AccessibilityID.PiPDelayedStartFailureValidation.stateLabel)
    let possible = element(AccessibilityID.PiPDelayedStartFailureValidation.possibleLabel)
    let result = element(AccessibilityID.PiPDelayedStartFailureValidation.resultLabel)
    let run = app.buttons[AccessibilityID.PiPDelayedStartFailureValidation.runButton]
    let error = element(AccessibilityID.PiPDelayedStartFailureValidation.errorLabel)

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(possible, equals: "yes", timeout: 15)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForPrefix(result, prefix: "pass:", timeout: 15)
    XCTAssertFalse(error.exists, "Validation surface reported: \(error.label)")

    let evidence = try decodeEvidence(result.label)
    XCTAssertEqual(evidence["startResult"] as? String, "accepted")
    XCTAssertEqual(evidence["orderedAttribution"] as? Bool, true)
    XCTAssertEqual(
      evidence["controllerGeneration"] as? Int,
      evidence["expectedControllerGeneration"] as? Int
    )
    XCTAssertEqual(
      evidence["mediaGeneration"] as? Int,
      evidence["expectedMediaGeneration"] as? Int
    )
    let events = try XCTUnwrap(evidence["orderedEvents"] as? [String])
    let failedToStartCount = events.filter { $0 == "failedToStart" }.count
    let didStartCount = events.filter { $0 == "didStart" }.count
    XCTAssertEqual(failedToStartCount, 1)
    XCTAssertEqual(didStartCount, 0)
    XCTAssertEqual(evidence["quiescenceMilliseconds"] as? Int, 3000)
    XCTAssertEqual(evidence["controllerActiveAfterCleanup"] as? Bool, false)
    XCTAssertEqual(
      evidence["failureDomain"] as? String,
      "SwiftVLC.Qualification.DelayedPiPStartFailure"
    )
    try attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "failed-start",
        "events": [
          "failedToStartCount": failedToStartCount,
          "didStartCount": didStartCount,
          "order": "pass"
        ],
        "failureSurfaced": true,
        "orderedEvents": events,
        "failureDomain": XCTUnwrap(evidence["failureDomain"] as? String),
        "failureCode": XCTUnwrap(evidence["failureCode"] as? Int)
      ],
      scenario: "failed-start"
    )
    attachQualificationEvidence(evidence, scenario: "accepted-start-delayed-failure")
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
