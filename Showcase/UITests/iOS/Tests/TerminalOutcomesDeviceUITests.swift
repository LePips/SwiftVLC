import XCTest

/// Candidate-bound proof that every v1.1.0 terminal transition publishes one
/// generation-scoped, immutable pre-reset payload to independent subscribers.
final class TerminalOutcomesDeviceUITests: ShowcaseIOSTestCase {
  private let expectedCauses: [(action: String, cause: String)] = [
    ("clean-eof", "naturalEnd"),
    ("explicit-stop", "requestedStop"),
    ("replacement", "replacement"),
    ("server-close", "failure:source"),
    ("malformed", "failure:demux"),
    ("decode-failure", "failure:decoder"),
    ("renderer-failure", "failure:renderer"),
    ("output-failure", "failure:output"),
    ("network-loss", "failure:source")
  ]

  func test_terminalOutcomeMatrixIsGenerationScopedAndPreReset() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Terminal failure attribution requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_TERMINAL_OUTCOMES_DEVICE"] == "YES"
    else {
      throw XCTSkip(
        "Set SWIFTVLC_TERMINAL_OUTCOMES_DEVICE=YES for candidate-bound hardware runs"
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
    var finalTimelines: [String: Any] = [:]
    var failureClassifications: [String: String] = [:]
    var maximumOutcomeCount = 0
    var unattributedStopNaturalEndCount = 0
    for expected in expectedCauses {
      let evidence = try runAction(expected.action, baseLogPath: baseLogPath)
      let outcome = try XCTUnwrap(evidence["outcome"] as? [String: Any])
      let cause = try XCTUnwrap(outcome["cause"] as? String)
      XCTAssertEqual(cause, expected.cause)
      XCTAssertEqual(evidence["subscriberPayloadsIdentical"] as? Bool, true)
      let libraryErrors = try XCTUnwrap(evidence["libraryErrors"] as? [[String: Any]])
      if expected.cause.hasPrefix("failure:") {
        XCTAssertFalse(
          libraryErrors.isEmpty,
          "Expected failure action \(expected.action) emitted no error-level native diagnostics"
        )
      } else {
        XCTAssertTrue(
          libraryErrors.isEmpty,
          "Non-failure action \(expected.action) emitted error-level native diagnostics"
        )
      }
      let count = try XCTUnwrap(evidence["outcomeCountPerSubscriber"] as? Int)
      XCTAssertEqual(count, 1)
      maximumOutcomeCount = max(maximumOutcomeCount, count)
      if cause == "naturalEnd", expected.action != "clean-eof" {
        unattributedStopNaturalEndCount += 1
      }
      if let classification = outcome["failureClassification"] as? String {
        failureClassifications[classification] = classification
      }
      cases[expected.action] = evidence
      finalTimelines[expected.action] = try XCTUnwrap(
        outcome["finalTimeline"] as? [String: Any]
      )
    }

    let replacement = try XCTUnwrap(cases["replacement"] as? [String: Any])
    XCTAssertEqual(replacement["generationIsolation"] as? Bool, true)
    XCTAssertEqual(Set(failureClassifications.keys), [
      "source", "demux", "decoder", "renderer", "output"
    ])
    XCTAssertEqual(maximumOutcomeCount, 1)
    XCTAssertEqual(unattributedStopNaturalEndCount, 0)

    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "terminal-outcomes",
        "cases": cases,
        "finalTimelines": finalTimelines,
        "generationIsolation": true,
        "failureClassifications": failureClassifications,
        "maximumTerminalOutcomesPerGeneration": maximumOutcomeCount,
        "unattributedStopNaturalEndCount": unattributedStopNaturalEndCount,
        "subscriberPayloadsIdentical": true,
        "expectedFailureLogsPreserved": true,
        "processIsolation": "one-launch-per-transition"
      ],
      scenario: "terminal-outcomes"
    )
    #endif
  }

  private func runAction(_ action: String, baseLogPath: String) throws -> [String: Any] {
    app.terminate()
    replaceLaunchArgument(
      LaunchArguments.route,
      with: UITestRoute.terminalOutcomesValidation.rawValue
    )
    replaceLaunchArgument(LaunchArguments.terminalOutcomeAction, with: action)
    replaceLaunchArgument(
      LaunchArguments.terminalOutcomeToken,
      with: "terminal-outcome-\(action)-\(UUID().uuidString.lowercased())"
    )
    replaceLaunchArgument(
      LaunchArguments.logPath,
      with: perCaseLogPath(action, baseLogPath: baseLogPath)
    )
    app.launch()
    app.tap()

    let actionLabel = element(AccessibilityID.TerminalOutcomesValidation.actionLabel)
    let result = element(AccessibilityID.TerminalOutcomesValidation.resultLabel)
    let run = app.buttons[AccessibilityID.TerminalOutcomesValidation.runButton]
    let error = element(AccessibilityID.TerminalOutcomesValidation.errorLabel)
    waitForLabel(actionLabel, equals: action, timeout: 10)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    guard waitForCompletion(result, timeout: 120) else {
      throw TerminalOutcomeDeviceFailure(
        "Terminal action \(action) did not complete; result was \(result.label)"
      )
    }
    guard result.label.hasPrefix("pass:") else {
      reveal(error)
      throw TerminalOutcomeDeviceFailure(
        "Terminal action \(action) failed: \(error.label)"
      )
    }
    let evidence = try decodeEvidence(result.label)
    XCTAssertEqual(evidence["action"] as? String, action)
    return evidence
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let encoded = String(label.dropFirst(prefix.count))
    let data = try XCTUnwrap(Data(base64Encoded: encoded))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func perCaseLogPath(_ action: String, baseLogPath: String) -> String {
    (baseLogPath as NSString).deletingPathExtension
      + "-terminal-outcomes-\(action).jsonl"
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

  private func waitForCompletion(
    _ element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    let predicate = NSPredicate { _, _ in
      element.exists
        && (element.label.hasPrefix("pass:") || element.label == "failed")
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
    XCTAssertEqual(
      result,
      .completed,
      "Expected a terminal validation result, got: \(element.label)"
    )
    return result == .completed
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }
}

private struct TerminalOutcomeDeviceFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
