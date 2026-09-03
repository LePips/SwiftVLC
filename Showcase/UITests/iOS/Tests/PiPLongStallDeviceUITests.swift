import XCTest

/// Candidate-bound sustained source-stall and recovery qualification across
/// native and direct PiP while the real system window remains active.
final class PiPLongStallDeviceUITests: ShowcaseIOSTestCase {
  func test_longStallRecoversAcrossNativeAndDirectBackends() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_LONG_STALL_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_LONG_STALL_DEVICE=YES for candidate-bound hardware runs")
    }

    let native = try runStall(renderingPath: "native")
    let direct = try runStall(renderingPath: "direct")
    let unexpectedStops = try unexpectedStopCount(in: native)
      + unexpectedStopCount(in: direct)
    XCTAssertEqual(unexpectedStops, 0)
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "long-stall",
        "events": [
          "started": true,
          "unexpectedStopCount": unexpectedStops,
          "order": "pass"
        ],
        "recoveryOutcome": "recovered",
        "boundedMemory": true,
        "stall": [
          "sustained": "pass",
          "recovered": "pass",
          "activeAfterRecovery": true
        ],
        "memory": [
          "bounded": "pass",
          "limitBytes": 96 * 1_048_576
        ],
        "backendResults": [
          "native": native,
          "direct": direct
        ],
        "systemPiPMotionAfterRecovery": [
          "native": "pass",
          "direct": "pass"
        ]
      ],
      scenario: "long-stall"
    )
    #endif
  }

  private func runStall(renderingPath: String) throws -> [String: Any] {
    let encodedURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SWIFTVLC_PIP_LONG_STALL_URL_BASE64"]
    )
    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: renderingPath)
    replaceLaunchArgument(LaunchArguments.pipLiveURLBase64, with: encodedURL)
    launch(route: .pipLongStallValidation)

    let state = element(AccessibilityID.PiPLongStallValidation.stateLabel)
    let possible = element(AccessibilityID.PiPLongStallValidation.possibleLabel)
    let active = element(AccessibilityID.PiPLongStallValidation.activeLabel)
    let result = element(AccessibilityID.PiPLongStallValidation.resultLabel)
    let run = app.buttons[AccessibilityID.PiPLongStallValidation.runButton]
    let trigger = app.buttons[AccessibilityID.PiPLongStallValidation.triggerButton]
    let stop = app.buttons[AccessibilityID.PiPLongStallValidation.stopButton]
    let error = element(AccessibilityID.PiPLongStallValidation.errorLabel)

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(possible, equals: "yes", timeout: 15)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForLabel(result, equals: "armed", timeout: 20)
    waitForLabel(active, equals: "yes", timeout: 5)

    reveal(trigger)
    XCTAssertTrue(trigger.isEnabled)
    trigger.tap()
    waitForLabel(result, equals: "triggered", timeout: 5)
    XCUIDevice.shared.press(.home)

    // The fixture withholds every active media connection for twelve seconds.
    // Allow the public two-second classifier, decoder refill, and presentation
    // recovery enough time to publish a paired transition before inspecting
    // real system-PiP pixels again.
    Thread.sleep(forTimeInterval: 20)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(renderingPath) PiP did not recover moving pixels: \(failure)")
    }

    app.activate()
    waitForLabel(active, equals: "yes", timeout: 10)
    waitForLabel(result, equals: "ready-for-stop", timeout: 15)
    reveal(stop)
    XCTAssertTrue(stop.isEnabled)
    stop.tap()
    waitForPrefix(result, prefix: "pass:", timeout: 15)
    waitForLabel(active, equals: "no", timeout: 10)
    XCTAssertFalse(error.exists, "\(renderingPath) stall recovery failed: \(error.label)")
    assertNoLibraryErrors()

    let evidence = try decodeEvidence(result.label)
    XCTAssertEqual(evidence["backend"] as? String, renderingPath)
    let stall = try XCTUnwrap(evidence["stall"] as? [String: Any])
    XCTAssertEqual(stall["activeAfterRecovery"] as? Bool, true)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(stall["durationMilliseconds"] as? Int), 2000)
    let memory = try XCTUnwrap(evidence["memory"] as? [String: Any])
    let growth = try XCTUnwrap(memory["growthBytes"] as? Int)
    let limit = try XCTUnwrap(memory["limitBytes"] as? Int)
    XCTAssertLessThanOrEqual(growth, limit)
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
