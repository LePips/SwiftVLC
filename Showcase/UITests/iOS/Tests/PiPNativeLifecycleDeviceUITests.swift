import XCTest

/// Candidate-bound proof for every native-drawable lifecycle transition in
/// the v1.1.0 matrix. Each transition gets a fresh app process so terminal
/// state from one case cannot make a later case pass.
final class PiPNativeLifecycleDeviceUITests: ShowcaseIOSTestCase {
  private enum Affordance: String {
    case restore
    case close

    var expectedReason: String {
      switch self {
      case .restore: "restoreRequested"
      case .close: "userClosed"
      }
    }
  }

  func test_nativeLifecyclePublishesAuthoritativeOrderedEvents() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Native Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_NATIVE_LIFECYCLE_DEVICE"] == "YES"
    else {
      throw XCTSkip(
        "Set SWIFTVLC_PIP_NATIVE_LIFECYCLE_DEVICE=YES for candidate-bound hardware runs"
      )
    }

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    let baseLogPath = try XCTUnwrap(
      launchArgumentValue(for: LaunchArguments.logPath),
      "Missing qualification log launch argument"
    )

    var cases: [String: Any] = [:]
    var orderedEvents: [String: [String]] = [:]
    for affordance in [Affordance.restore, .close] {
      let evidence = try runSystemCycle(affordance, baseLogPath: baseLogPath)
      let events = try XCTUnwrap(evidence["orderedEvents"] as? [String])
      cases[affordance.rawValue] = evidence
      orderedEvents[affordance.rawValue] = events
    }

    let expectedActions: [(action: String, reason: String?)] = [
      ("failed-start", nil),
      ("programmatic", "programmatic"),
      ("media-end", "mediaEnded"),
      ("failure", "failure"),
      ("recast", "controllerReplaced"),
      ("replacement", "controllerReplaced")
    ]
    var bridgeChecks: [Bool] = []
    for expected in expectedActions {
      let actionResult = try runAction(
        expected.action,
        terminalReason: expected.reason,
        baseLogPath: baseLogPath
      )
      let bridge = try XCTUnwrap(actionResult.evidence["bridge"] as? [String: Any])
      try bridgeChecks.append(validateBridge(bridge))
      cases[expected.action] = actionResult.evidence
      orderedEvents[expected.action] = actionResult.names
    }

    XCTAssertEqual(cases.count, 8)
    XCTAssertEqual(bridgeChecks.count, 6)
    XCTAssertTrue(bridgeChecks.allSatisfy(\.self))
    let restore = try XCTUnwrap(cases[Affordance.restore.rawValue] as? [String: Any])
    XCTAssertEqual(restore["restoreCallbackCount"] as? Int, 1)

    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "native-lifecycle",
        "bridgeProbe": true,
        "cases": cases,
        "orderedEvents": orderedEvents,
        "authoritativeStopReasons": true,
        "restoreExactlyOnce": true,
        "unsupportedBridgeVisible": true,
        "unsupportedBridgeVisibility": "typed-probe-required",
        "unsupportedRevisionExercised": false,
        "processIsolation": "one-launch-per-transition"
      ],
      scenario: "native-lifecycle"
    )
    #endif
  }

  private func runAction(
    _ action: String,
    terminalReason: String?,
    baseLogPath: String
  )
    throws -> (evidence: [String: Any], names: [String]) {
    app.terminate()
    replaceLaunchArgument(
      LaunchArguments.route,
      with: UITestRoute.pipNativeLifecycleValidation.rawValue
    )
    replaceLaunchArgument(LaunchArguments.pipNativeLifecycleAction, with: action)
    replaceLaunchArgument(
      LaunchArguments.pipNativeLifecycleToken,
      with: "native-lifecycle-\(action)-\(UUID().uuidString.lowercased())"
    )
    replaceLaunchArgument(
      LaunchArguments.logPath,
      with: perCaseLogPath(action, baseLogPath: baseLogPath)
    )
    app.launch()
    app.tap()

    let state = element(AccessibilityID.PiPNativeLifecycleValidation.stateLabel)
    let possible = element(AccessibilityID.PiPNativeLifecycleValidation.possibleLabel)
    let result = element(AccessibilityID.PiPNativeLifecycleValidation.resultLabel)
    let run = app.buttons[AccessibilityID.PiPNativeLifecycleValidation.runButton]
    let error = element(AccessibilityID.PiPNativeLifecycleValidation.errorLabel)

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(possible, equals: "yes", timeout: 15)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForPrefix(result, prefix: "pass:", timeout: actionTimeout(action))
    XCTAssertFalse(error.exists, "Native lifecycle \(action) failed: \(error.label)")

    let evidence = try decodeEvidence(result.label)
    XCTAssertEqual(evidence["action"] as? String, action)
    let events = try XCTUnwrap(evidence["orderedEvents"] as? [[String: Any]])
    let names = try events.map { try XCTUnwrap($0["name"] as? String) }
    if action == "failed-start" {
      XCTAssertEqual(names, ["willStart", "failedToStart"])
      XCTAssertFalse(names.contains("didStart"))
    } else {
      let reason = try XCTUnwrap(terminalReason)
      XCTAssertEqual(
        names,
        ["willStart", "didStart", "willStop:\(reason)", "didStop:\(reason)"]
      )
    }
    return (evidence, names)
  }

  private func runSystemCycle(
    _ affordance: Affordance,
    baseLogPath: String
  )
    throws -> [String: Any] {
    app.terminate()
    replaceLaunchArgument(
      LaunchArguments.route,
      with: UITestRoute.pipDismissalValidation.rawValue
    )
    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: "native")
    replaceLaunchArgument(
      LaunchArguments.logPath,
      with: perCaseLogPath(affordance.rawValue, baseLogPath: baseLogPath)
    )
    app.launch()
    app.tap()

    let state = element(AccessibilityID.PiPDismissalValidation.stateLabel)
    let possible = element(AccessibilityID.PiPDismissalValidation.possibleLabel)
    let active = element(AccessibilityID.PiPDismissalValidation.activeLabel)
    let lifecycle = element(AccessibilityID.PiPDismissalValidation.lifecycleEventsLabel)
    let restoreCount = element(AccessibilityID.PiPDismissalValidation.restoreCountLabel)
    let start = app.buttons[AccessibilityID.PiPDismissalValidation.startButton]
    let error = element(AccessibilityID.PiPDismissalValidation.errorLabel)

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(possible, equals: "yes", timeout: 15)
    reveal(start)
    XCTAssertTrue(start.isEnabled)
    start.tap()
    waitForLabel(active, equals: "yes", timeout: 10)
    waitForLifecyclePrefix(lifecycle, prefix: "willStart|didStart", timeout: 10)

    XCUIDevice.shared.press(.home)
    let region = try locateSystemPictureInPictureWindow()
    let systemAffordances = try locateSystemPictureInPictureAffordances(
      in: region,
      attachmentName: "native-lifecycle-\(affordance.rawValue)"
    )
    switch affordance {
    case .restore:
      systemAffordances.restore.tap()
    case .close:
      systemAffordances.close.tap()
    }
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    if app.state != .runningForeground {
      app.activate()
    }

    waitForLabel(active, equals: "no", timeout: 10)
    let expected = [
      "willStart",
      "didStart",
      "willStop:\(affordance.expectedReason)",
      "didStop:\(affordance.expectedReason)"
    ]
    waitForLifecyclePrefix(lifecycle, prefix: expected.joined(separator: "|"), timeout: 10)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertFalse(error.exists, "Native \(affordance.rawValue) failed: \(error.label)")
    let actual = lifecycle.label.split(separator: "|").map(String.init)
    XCTAssertEqual(actual, expected)
    let count = Int(restoreCount.label) ?? -1
    XCTAssertEqual(count, affordance == .restore ? 1 : 0)
    return [
      "actionOutcome": affordance.rawValue,
      "orderedEvents": actual,
      "restoreCallbackCount": count,
      "systemPiPMotion": "pass"
    ]
  }

  private func validateBridge(_ bridge: [String: Any]) throws -> Bool {
    XCTAssertEqual(bridge["hasAVController"] as? Bool, true)
    XCTAssertEqual(bridge["hasLifecycleDelegateBridge"] as? Bool, true)
    XCTAssertNotNil(bridge["windowControllerClassName"] as? String)
    XCTAssertNotNil(bridge["delegateClassName"] as? String)
    let selectors = try XCTUnwrap(bridge["delegateResponds"] as? [String: Bool])
    let required = [
      "pictureInPictureControllerWillStartPictureInPicture:",
      "pictureInPictureControllerDidStartPictureInPicture:",
      "pictureInPictureController:failedToStartPictureInPictureWithError:",
      "pictureInPictureControllerWillStopPictureInPicture:",
      "pictureInPictureControllerDidStopPictureInPicture:",
      "pictureInPictureController:restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:"
    ]
    XCTAssertTrue(required.allSatisfy { selectors[$0] == true })
    return required.allSatisfy { selectors[$0] == true }
      && bridge["hasAVController"] as? Bool == true
      && bridge["hasLifecycleDelegateBridge"] as? Bool == true
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let encoded = String(label.dropFirst(prefix.count))
    let data = try XCTUnwrap(Data(base64Encoded: encoded))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func actionTimeout(_ action: String) -> TimeInterval {
    switch action {
    case "failure", "media-end": 40
    default: 20
    }
  }

  private func perCaseLogPath(_ name: String, baseLogPath: String) -> String {
    (baseLogPath as NSString).deletingPathExtension
      + "-native-lifecycle-\(name).jsonl"
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
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

  private func launchArgumentValue(for name: String) -> String? {
    guard
      let index = app.launchArguments.lastIndex(of: name),
      app.launchArguments.indices.contains(index + 1)
    else { return nil }
    return app.launchArguments[index + 1]
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

  private func waitForLifecyclePrefix(
    _ element: XCUIElement,
    prefix: String,
    timeout: TimeInterval
  ) {
    waitForPrefix(element, prefix: prefix, timeout: timeout)
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }
}
