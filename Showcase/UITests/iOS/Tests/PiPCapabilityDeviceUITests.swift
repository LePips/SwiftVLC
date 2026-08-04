import XCTest

/// Candidate-bound proof that PiP capability policy converges through native
/// polling even when raw length and seekability callbacks are suppressed.
final class PiPCapabilityDeviceUITests: ShowcaseIOSTestCase {
  private struct BackendEvidence {
    let suppressedLengthEvents: Int
    let suppressedSeekableEvents: Int
  }

  func test_capabilityConvergenceAcrossNativeAndDirectBackends() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_CAPABILITY_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_CAPABILITY_DEVICE=YES for candidate-bound hardware runs")
    }

    let native = try runCapabilityTransitions(renderingPath: "native")
    let direct = try runCapabilityTransitions(renderingPath: "direct")
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "capability-convergence",
        "backendResults": [
          "native": "pass",
          "direct": "pass"
        ],
        "transitions": "pass",
        "skipControls": "pass",
        "faultInjection": [
          "rawEventsSuppressed": true,
          "nativeLengthEvents": native.suppressedLengthEvents,
          "nativeSeekableEvents": native.suppressedSeekableEvents,
          "directLengthEvents": direct.suppressedLengthEvents,
          "directSeekableEvents": direct.suppressedSeekableEvents
        ],
        "systemPiPMotion": [
          "native": "pass",
          "direct": "pass"
        ]
      ],
      scenario: "capability-convergence"
    )
    #endif
  }

  private func runCapabilityTransitions(renderingPath: String) throws -> BackendEvidence {
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }

    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: renderingPath)
    launch(route: .pipCapabilityValidation)
    app.tap()

    let state = element(AccessibilityID.PiPCapabilityValidation.stateLabel)
    let generation = element(AccessibilityID.PiPCapabilityValidation.generationLabel)
    let policy = element(AccessibilityID.PiPCapabilityValidation.snapshotLabel)
    let suppression = element(AccessibilityID.PiPCapabilityValidation.suppressionLabel)
    let possible = element(AccessibilityID.PiPCapabilityValidation.possibleLabel)
    let active = element(AccessibilityID.PiPCapabilityValidation.activeLabel)
    let lifecycle = element(AccessibilityID.PiPCapabilityValidation.lifecycleEventsLabel)
    let skipResult = element(AccessibilityID.PiPCapabilityValidation.skipResultLabel)
    let playbackError = element(AccessibilityID.PiPCapabilityValidation.errorLabel)
    let loadVOD = app.buttons[AccessibilityID.PiPCapabilityValidation.loadVODButton]
    let loadLive = app.buttons[AccessibilityID.PiPCapabilityValidation.loadLiveButton]
    let toggle = app.buttons[AccessibilityID.PiPCapabilityValidation.toggleButton]
    let skipForward = app.buttons[AccessibilityID.PiPCapabilityValidation.skipForwardButton]

    waitForPrefix(suppression, prefix: "enabled:", timeout: 5)
    reveal(loadVOD)
    loadVOD.tap()
    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(policy, equals: "finite:seekable:interactive", timeout: 15)
    waitForLabel(possible, equals: "yes", timeout: 15)

    reveal(toggle)
    XCTAssertTrue(toggle.isEnabled)
    toggle.tap()
    waitForLabel(active, equals: "yes", timeout: 10)
    waitForOccurrence("didStart", count: 1, in: lifecycle, timeout: 10)
    try exerciseSkip(skipForward, result: skipResult)

    let initialGeneration = generation.label
    reveal(loadLive, swiping: .down)
    loadLive.tap()
    waitForLabelChange(generation, from: initialGeneration, timeout: 5)
    waitForLabel(policy, equals: "unbounded:unseekable:linear", timeout: 15)
    waitForLabel(active, equals: "yes", timeout: 10)

    let liveGeneration = generation.label
    reveal(loadVOD, swiping: .down)
    loadVOD.tap()
    waitForLabelChange(generation, from: liveGeneration, timeout: 5)
    waitForLabel(policy, equals: "finite:seekable:interactive", timeout: 15)
    waitForLabel(active, equals: "yes", timeout: 10)
    try exerciseSkip(skipForward, result: skipResult)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(renderingPath) capability PiP motion failed: \(failure)")
    }
    app.activate()
    waitForLabel(active, equals: "yes", timeout: 10)

    reveal(toggle)
    toggle.tap()
    waitForLabel(active, equals: "no", timeout: 10)
    XCTAssertFalse(
      playbackError.exists,
      "Capability surface reported an asynchronous playback error: \(playbackError.label)"
    )
    assertNoLibraryErrors()

    let counts = try parseSuppressionSnapshot(suppression.label)
    XCTAssertTrue(counts.isEnabled, "Raw capability fault injection was not active")
    return BackendEvidence(
      suppressedLengthEvents: counts.length,
      suppressedSeekableEvents: counts.seekable
    )
  }

  private func exerciseSkip(
    _ button: XCUIElement,
    result: XCUIElement
  )
    throws {
    reveal(button)
    XCTAssertTrue(button.isEnabled)
    button.tap()
    waitForPrefix(result, prefix: "pass:", timeout: 15)
    let components = result.label.split(separator: ":")
    let before = try XCTUnwrap(components.count == 3 ? Int64(components[1]) : nil)
    let after = try XCTUnwrap(components.count == 3 ? Int64(components[2]) : nil)
    XCTAssertGreaterThan(after, before, "PiP skip reported success without advancing playback")
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
      "Expected \(prefix), got: \(element.label)"
    )
  }

  private func waitForLabelChange(
    _ element: XCUIElement,
    from previous: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      element.exists && element.label != previous
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func waitForOccurrence(
    _ value: String,
    count: Int,
    in element: XCUIElement,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      element.label.split(separator: "|").count(where: { $0 == Substring(value) }) >= count
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func parseSuppressionSnapshot(
    _ value: String
  )
    throws -> (isEnabled: Bool, length: Int, seekable: Int) {
    let components = value.split(separator: ":")
    XCTAssertEqual(components.count, 3, "Malformed suppression snapshot: \(value)")
    return try (
      XCTUnwrap(components.first.map { $0 == "enabled" }),
      XCTUnwrap(components.count == 3 ? Int(components[1]) : nil),
      XCTUnwrap(components.count == 3 ? Int(components[2]) : nil)
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

  private enum ScrollDirection {
    case up
    case down
  }

  private func reveal(
    _ element: XCUIElement,
    swiping direction: ScrollDirection = .up
  ) {
    for _ in 0..<10 where !element.isHittable {
      switch direction {
      case .up: app.swipeUp()
      case .down: app.swipeDown()
      }
    }
    XCTAssertTrue(element.isHittable)
  }
}
