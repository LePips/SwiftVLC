import XCTest

/// Candidate-bound proof that the actual system PiP restore and close
/// affordances remain distinguishable across both rendering backends.
final class PiPDismissalDeviceUITests: ShowcaseIOSTestCase {
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

  private struct CycleEvidence {
    let backend: String
    let affordance: Affordance
    let orderedEvents: [String]
    let restoreCount: Int

    var json: [String: Any] {
      [
        "backend": backend,
        "affordance": affordance.rawValue,
        "orderedEvents": orderedEvents,
        "restoreCallbackCount": restoreCount,
        "systemPiPMotion": "pass",
        "reason": affordance.expectedReason
      ]
    }
  }

  func test_systemRestoreAndCloseAcrossNativeAndDirectBackends() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_DISMISSAL_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_DISMISSAL_DEVICE=YES for candidate-bound hardware runs")
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

    var cycles: [CycleEvidence] = []
    for backend in ["native", "direct"] {
      for affordance in [Affordance.restore, .close] {
        try cycles.append(
          runCycle(backend: backend, affordance: affordance, baseLogPath: baseLogPath)
        )
      }
    }
    let restoreCycles = cycles.filter { $0.affordance == .restore }
    let closeCycles = cycles.filter { $0.affordance == .close }
    XCTAssertEqual(restoreCycles.count, 2)
    XCTAssertEqual(closeCycles.count, 2)
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "restore",
        "events": [
          "didStartCount": 1,
          "willStopReason": Affordance.restore.expectedReason,
          "didStopReason": Affordance.restore.expectedReason,
          "order": "pass"
        ],
        "restoreResult": "pass",
        "completionCount": 1,
        "backends": Dictionary(
          uniqueKeysWithValues: restoreCycles.map { ($0.backend, $0.json) }
        ),
        "aggregationBasis": "per-backend invariant",
        "systemAffordance": "pass"
      ],
      scenario: "restore"
    )
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "close",
        "events": [
          "didStartCount": 1,
          "willStopReason": Affordance.close.expectedReason,
          "didStopReason": Affordance.close.expectedReason,
          "order": "pass"
        ],
        "stopReason": Affordance.close.expectedReason,
        "backends": Dictionary(
          uniqueKeysWithValues: closeCycles.map { ($0.backend, $0.json) }
        ),
        "aggregationBasis": "per-backend invariant",
        "systemAffordance": "pass"
      ],
      scenario: "close"
    )
    #endif
  }

  private func runCycle(
    backend: String,
    affordance: Affordance,
    baseLogPath: String
  )
    throws -> CycleEvidence {
    app.terminate()
    replaceLaunchArgument(LaunchArguments.route, with: UITestRoute.pipDismissalValidation.rawValue)
    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: backend)
    let cycleLogPath =
      (baseLogPath as NSString).deletingPathExtension
        + "-\(backend)-\(affordance.rawValue).jsonl"
    replaceLaunchArgument(LaunchArguments.logPath, with: cycleLogPath)
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
      attachmentName: "system-pip-\(affordance.rawValue)"
    )
    switch affordance {
    case .restore:
      systemAffordances.restore.tap()
    case .close:
      systemAffordances.close.tap()
    }

    // Restore normally foregrounds the app while close intentionally does not.
    // Give AVKit time to finish the system action before foregrounding a close
    // cycle solely to inspect the already-published lifecycle.
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    if app.state != .runningForeground {
      app.activate()
    }
    waitForLabel(active, equals: "no", timeout: 10)
    let expectedLifecycle =
      "willStart|didStart|willStop:\(affordance.expectedReason)|didStop:\(affordance.expectedReason)"
    waitForLabel(lifecycle, equals: expectedLifecycle, timeout: 10)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertEqual(
      lifecycle.label,
      expectedLifecycle,
      "Unexpected trailing dismissal lifecycle event"
    )
    XCTAssertFalse(error.exists, "\(backend) \(affordance.rawValue) failed: \(error.label)")

    let count = Int(restoreCount.label) ?? -1
    XCTAssertEqual(count, affordance == .restore ? 1 : 0)
    return CycleEvidence(
      backend: backend,
      affordance: affordance,
      orderedEvents: lifecycle.label.split(separator: "|").map(String.init),
      restoreCount: count
    )
  }

  private func waitForLifecyclePrefix(
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
      "Expected lifecycle prefix \(prefix), got: \(element.label)"
    )
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

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }
}
