import XCTest

/// Candidate-bound proof that PiP capability policy converges through native
/// polling even when raw length and seekability callbacks are suppressed.
final class PiPCapabilityDeviceUITests: ShowcaseIOSTestCase {
  private struct BackendEvidence {
    let isEnabled: Bool
    let playerSuppressedLengthEvents: Int
    let playerSuppressedSeekableEvents: Int
    let controllerSuppressedLengthEvents: Int
    let controllerSuppressedSeekableEvents: Int

    var playerObserverWasExercised: Bool {
      playerSuppressedLengthEvents > 0 && playerSuppressedSeekableEvents > 0
    }

    var controllerObserverWasExercised: Bool {
      controllerSuppressedLengthEvents > 0 && controllerSuppressedSeekableEvents > 0
    }
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
          "rawEventsSuppressed": native.isEnabled && direct.isEnabled,
          "nativePlayerObserverExercised": native.playerObserverWasExercised,
          "nativeControllerObserverExercised": native.controllerObserverWasExercised,
          "directPlayerObserverExercised": direct.playerObserverWasExercised,
          "directControllerObserverExercised": direct.controllerObserverWasExercised,
          "nativePlayerLengthEvents": native.playerSuppressedLengthEvents,
          "nativePlayerSeekableEvents": native.playerSuppressedSeekableEvents,
          "nativeControllerLengthEvents": native.controllerSuppressedLengthEvents,
          "nativeControllerSeekableEvents": native.controllerSuppressedSeekableEvents,
          "directPlayerLengthEvents": direct.playerSuppressedLengthEvents,
          "directPlayerSeekableEvents": direct.playerSuppressedSeekableEvents,
          "directControllerLengthEvents": direct.controllerSuppressedLengthEvents,
          "directControllerSeekableEvents": direct.controllerSuppressedSeekableEvents
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
    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: renderingPath)
    launch(route: .pipCapabilityValidation)

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

    revealMeasurement(suppression, swiping: .up)
    waitForValuePrefix(suppression, prefix: "enabled:", timeout: 5)
    reveal(loadVOD, swiping: .down)
    loadVOD.tap()
    revealMeasurement(state, swiping: .up)
    waitForAccessibilityValue(state, equals: "playing", timeout: 20)
    revealMeasurement(policy, swiping: .up)
    waitForAccessibilityValue(policy, equals: "finite:seekable:interactive", timeout: 15)
    revealMeasurement(possible, swiping: .up)
    waitForAccessibilityValue(possible, equals: "yes", timeout: 15)

    reveal(toggle, swiping: .up)
    XCTAssertTrue(toggle.isEnabled)
    toggle.tap()
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)
    revealMeasurement(lifecycle, swiping: .up)
    waitForOccurrence("didStart", count: 1, in: lifecycle, timeout: 10)
    try exerciseSkip(skipForward, result: skipResult)

    revealMeasurement(generation, swiping: .down)
    let initialGeneration = accessibilityValue(of: generation)
    reveal(loadLive, swiping: .down)
    loadLive.tap()
    revealMeasurement(generation, swiping: .up)
    waitForValueChange(generation, from: initialGeneration, timeout: 5)
    revealMeasurement(policy, swiping: .up)
    waitForAccessibilityValue(policy, equals: "unbounded:unseekable:linear", timeout: 15)
    revealMeasurement(active, swiping: .up)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)

    revealMeasurement(generation, swiping: .down)
    let liveGeneration = accessibilityValue(of: generation)
    reveal(loadVOD, swiping: .down)
    loadVOD.tap()
    revealMeasurement(generation, swiping: .up)
    waitForValueChange(generation, from: liveGeneration, timeout: 5)
    revealMeasurement(policy, swiping: .up)
    waitForAccessibilityValue(policy, equals: "finite:seekable:interactive", timeout: 15)
    revealMeasurement(active, swiping: .up)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)
    try exerciseSkip(skipForward, result: skipResult)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(renderingPath) capability PiP motion failed: \(failure)")
    }
    app.activate()
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)

    reveal(toggle, swiping: .up)
    toggle.tap()
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "no", timeout: 10)
    reveal(skipForward, swiping: .up)
    XCTAssertFalse(
      playbackError.exists,
      "Capability surface reported an asynchronous playback error: \(playbackError.label)"
    )
    assertNoLibraryErrors()

    revealMeasurement(suppression, swiping: .down)
    let counts = try parseSuppressionSnapshot(accessibilityValue(of: suppression))
    XCTAssertTrue(counts.isEnabled, "Raw capability fault injection was not active")
    XCTAssertGreaterThan(
      counts.playerLength,
      0,
      "No raw length callback reached Player's qualification suppression seam"
    )
    XCTAssertGreaterThan(
      counts.playerSeekable,
      0,
      "No raw seekability callback reached Player's qualification suppression seam"
    )
    XCTAssertGreaterThan(
      counts.controllerLength,
      0,
      "No raw length callback was rejected by PiPController's observer"
    )
    XCTAssertGreaterThan(
      counts.controllerSeekable,
      0,
      "No raw seekability callback was rejected by PiPController's observer"
    )
    guard
      counts.isEnabled,
      counts.playerLength > 0,
      counts.playerSeekable > 0,
      counts.controllerLength > 0,
      counts.controllerSeekable > 0
    else {
      throw CapabilitySuppressionEvidenceFailure(
        "Both Player and PiPController suppression seams must reject length and seekability callbacks"
      )
    }
    return BackendEvidence(
      isEnabled: counts.isEnabled,
      playerSuppressedLengthEvents: counts.playerLength,
      playerSuppressedSeekableEvents: counts.playerSeekable,
      controllerSuppressedLengthEvents: counts.controllerLength,
      controllerSuppressedSeekableEvents: counts.controllerSeekable
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
    revealMeasurement(result, swiping: .down)
    waitForValuePrefix(result, prefix: "pass:", timeout: 15)
    let components = accessibilityValue(of: result).split(separator: ":")
    let before = try XCTUnwrap(components.count == 3 ? Int64(components[1]) : nil)
    let after = try XCTUnwrap(components.count == 3 ? Int64(components[2]) : nil)
    XCTAssertGreaterThan(after, before, "PiP skip reported success without advancing playback")
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func waitForValuePrefix(
    _ element: XCUIElement,
    prefix: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      element.exists && self.accessibilityValue(of: element).hasPrefix(prefix)
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected \(prefix), got: \(accessibilityValue(of: element))"
    )
  }

  private func waitForValueChange(
    _ element: XCUIElement,
    from previous: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      element.exists && self.accessibilityValue(of: element) != previous
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
      self.accessibilityValue(of: element)
        .split(separator: "|")
        .count(where: { $0 == Substring(value) }) >= count
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func parseSuppressionSnapshot(
    _ value: String
  )
    throws -> (
      isEnabled: Bool,
      playerLength: Int,
      playerSeekable: Int,
      controllerLength: Int,
      controllerSeekable: Int
    ) {
    let components = value.split(separator: ":")
    XCTAssertEqual(components.count, 5, "Malformed suppression snapshot: \(value)")
    return try (
      XCTUnwrap(components.first.map { $0 == "enabled" }),
      XCTUnwrap(components.count == 5 ? Int(components[1]) : nil),
      XCTUnwrap(components.count == 5 ? Int(components[2]) : nil),
      XCTUnwrap(components.count == 5 ? Int(components[3]) : nil),
      XCTUnwrap(components.count == 5 ? Int(components[4]) : nil)
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

  private func reveal(
    _ element: XCUIElement,
    swiping direction: ShowcaseScrollDirection = .up
  ) {
    for _ in 0..<10 where !element.isHittable {
      switch direction {
      case .up: app.swipeUp()
      case .down: app.swipeDown()
      }
    }
    if !element.isHittable {
      for _ in 0..<20 where !element.isHittable {
        direction.opposite.perform(in: app)
      }
    }
    XCTAssertTrue(element.isHittable, "Could not reveal \(element)")
  }
}

private struct CapabilitySuppressionEvidenceFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
