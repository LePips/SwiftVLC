import XCTest

/// Physical proof that the native VLC renderer recovers a real decoder-resource
/// revocation while paused. Native counters prove mechanics; SpringBoard pixels
/// independently prove that moving video returned after recovery.
final class NativeRendererRecoveryDeviceUITests: ShowcaseIOSTestCase {
  func test_pausedNativeRendererRecoversAfterRealOSRevocation() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Native renderer resource revocation requires a physical iPhone")
    #else
    guard
      ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_RENDERER_RECOVERY_DEVICE"]
      == "YES"
    else {
      throw XCTSkip(
        "Set SWIFTVLC_NATIVE_RENDERER_RECOVERY_DEVICE=YES for candidate-bound hardware runs"
      )
    }

    app.launchArguments += [
      LaunchArguments.route,
      UITestRoute.nativeRendererRecoveryValidation.rawValue,
      LaunchArguments.nativeRendererRecoveryObservationDuration,
      "4"
    ]
    if
      let encodedURL = ProcessInfo.processInfo.environment[
        "SWIFTVLC_NATIVE_RENDERER_RECOVERY_URL_BASE64"
      ] {
      app.launchArguments += [LaunchArguments.nativeRendererRecoveryURLBase64, encodedURL]
    }
    launchDirectlyHandlingQualificationPermissions()

    let state = element(AccessibilityID.NativeRendererRecoveryValidation.stateLabel)
    let possible = element(AccessibilityID.NativeRendererRecoveryValidation.possibleLabel)
    let active = element(AccessibilityID.NativeRendererRecoveryValidation.activeLabel)
    let phase = element(AccessibilityID.NativeRendererRecoveryValidation.phaseLabel)
    let result = element(AccessibilityID.NativeRendererRecoveryValidation.resultLabel)
    let prepare = app.buttons[AccessibilityID.NativeRendererRecoveryValidation.prepareButton]
    let arm = app.buttons[AccessibilityID.NativeRendererRecoveryValidation.armButton]
    let evaluate = app.buttons[AccessibilityID.NativeRendererRecoveryValidation.evaluateButton]
    let resume = app.buttons[AccessibilityID.NativeRendererRecoveryValidation.resumeButton]
    let error = element(AccessibilityID.NativeRendererRecoveryValidation.errorLabel)

    waitForAccessibilityValue(state, equals: "playing", timeout: 30)
    waitForAccessibilityValue(possible, equals: "yes", timeout: 30)
    reveal(prepare)
    XCTAssertTrue(prepare.isEnabled)
    prepare.tap()
    revealMeasurement(phase, swiping: .down)
    waitForAccessibilityValue(phase, equals: "ready", timeout: 30)
    revealMeasurement(result, swiping: .down)
    waitForAccessibilityValue(result, equals: "ready", timeout: 5)
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)

    reveal(arm)
    XCTAssertTrue(arm.isEnabled)
    arm.tap()
    revealMeasurement(state, swiping: .down)
    waitForAccessibilityValue(state, equals: "paused", timeout: 15)
    revealMeasurement(phase, swiping: .down)
    waitForAccessibilityValue(phase, equals: "armed", timeout: 15)
    revealMeasurement(result, swiping: .down)
    waitForAccessibilityValue(result, equals: "armed", timeout: 5)

    let maximumCycles = boundedEnvironmentInteger(
      "SWIFTVLC_NATIVE_RENDERER_RECOVERY_CYCLES",
      default: 3,
      range: 1...5
    )
    let backgroundSeconds = boundedEnvironmentInteger(
      "SWIFTVLC_NATIVE_RENDERER_BACKGROUND_SECONDS",
      default: 12,
      range: 2...60
    )
    var cycleCount = 0
    var candidateEvidence: [String: Any]?
    var mechanicsOutcome = "not-exercised"

    for cycle in 1...maximumCycles {
      cycleCount = cycle
      XCUIDevice.shared.press(.home)
      RunLoop.current.run(until: Date().addingTimeInterval(TimeInterval(backgroundSeconds)))

      app.activate()
      handleQualificationLocalNetworkPermissionIfPresent()
      revealMeasurement(state, swiping: .down)
      waitForAccessibilityValue(state, equals: "paused", timeout: 15)
      revealMeasurement(active, swiping: .down)
      waitForAccessibilityValue(active, equals: "yes", timeout: 15)
      reveal(evaluate)
      XCTAssertTrue(evaluate.isEnabled)
      let previousResult = accessibilityValue(of: result)
      evaluate.tap()

      let encodedResult = waitForMechanicsResult(
        result,
        replacing: previousResult,
        timeout: 15
      )
      guard encodedResult.contains(":") else {
        XCTFail("Renderer recovery producer failed without evidence: \(error.label)")
        return
      }
      candidateEvidence = try decodeEvidence(encodedResult)
      let mechanics = try XCTUnwrap(candidateEvidence?["mechanics"] as? [String: Any])
      mechanicsOutcome = try XCTUnwrap(mechanics["outcome"] as? String)
      if mechanicsOutcome == "pass" || mechanicsOutcome == "failed" {
        break
      }
    }

    var evidence = try XCTUnwrap(candidateEvidence)
    evidence["backgroundForegroundCycles"] = cycleCount
    evidence["status"] = mechanicsOutcome
    let mechanics = try XCTUnwrap(evidence["mechanics"] as? [String: Any])
    evidence["reason"] = try XCTUnwrap(mechanics["reason"] as? String)

    guard mechanicsOutcome == "pass" else {
      evidence["postRecoveryVisualOracle"] = try jsonObject(
        NativeRendererRecoveryVisualOracleEvidence.notRun(
          reason: mechanicsOutcome == "not-exercised"
            ? "os-resource-revocation-not-observed"
            : "native-recovery-mechanics-failed"
        )
      )
      attachQualificationEvidence(
        evidence,
        scenario: "playback-foreground-displaylayer-recovery"
      )
      if mechanicsOutcome == "failed" {
        XCTFail("Observed native renderer revocation did not recover: \(evidence)")
      }
      return
    }

    reveal(resume)
    XCTAssertTrue(resume.isEnabled)
    resume.tap()
    revealMeasurement(state, swiping: .down)
    waitForAccessibilityValue(state, equals: "playing", timeout: 20)
    revealMeasurement(phase, swiping: .down)
    waitForAccessibilityValue(
      phase,
      equals: "resumed-for-pixel-oracle",
      timeout: 10
    )
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)

    let visual: NativeRendererRecoveryVisualOracleEvidence
    do {
      XCUIDevice.shared.press(.home)
      let region = try locateSystemPictureInPictureWindow(
        samples: 6,
        interval: 0.5,
        retainDiagnostics: true
      )
      visual = try capturePostRecoveryVisualOracle(in: region)
    } catch {
      evidence["status"] = "failed"
      evidence["reason"] = "post-recovery-system-pip-unavailable"
      evidence["postRecoveryVisualOracle"] = try jsonObject(
        NativeRendererRecoveryVisualOracleEvidence.notRun(
          status: .failed,
          reason: "system-pip-capture-or-replay-failed"
        )
      )
      attachQualificationEvidence(
        evidence,
        scenario: "playback-foreground-displaylayer-recovery"
      )
      XCTFail("Could not capture post-recovery system PiP pixels: \(error)")
      return
    }
    let visualPassed = visual.status == .pass

    evidence["status"] = visualPassed ? "pass" : "failed"
    evidence["reason"] = visualPassed
      ? "native-mechanics-and-system-pip-motion-proved"
      : "post-recovery-system-pip-motion-failed"
    evidence["postRecoveryVisualOracle"] = try jsonObject(visual)
    guard visualPassed else {
      attachQualificationEvidence(
        evidence,
        scenario: "playback-foreground-displaylayer-recovery"
      )
      XCTFail("Post-recovery system PiP did not contain sustained moving pixels")
      return
    }
    XCTAssertFalse(error.exists, "Native renderer recovery failed: \(error.label)")
    attachQualificationEvidence(
      evidence,
      scenario: "playback-foreground-displaylayer-recovery"
    )
    #endif
  }

  private func waitForMechanicsResult(
    _ element: XCUIElement,
    replacing previousResult: String,
    timeout: TimeInterval
  ) -> String {
    let predicate = NSPredicate { _, _ in
      let value = self.accessibilityValue(of: element)
      return value != previousResult
        && (value.hasPrefix("pass:")
          || value.hasPrefix("not-exercised:")
          || value.hasPrefix("failed:")
          || value == "failed")
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    return accessibilityValue(of: element)
  }

  private func decodeEvidence(_ encodedResult: String) throws -> [String: Any] {
    let parts = encodedResult.split(separator: ":", maxSplits: 1)
    XCTAssertEqual(parts.count, 2)
    let data = try XCTUnwrap(parts.last.flatMap { Data(base64Encoded: String($0)) })
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    if !element.isHittable {
      for _ in 0..<15 where !element.isHittable {
        app.swipeDown()
      }
    }
    XCTAssertTrue(element.isHittable)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func boundedEnvironmentInteger(
    _ name: String,
    default defaultValue: Int,
    range: ClosedRange<Int>
  ) -> Int {
    let supplied = ProcessInfo.processInfo.environment[name].flatMap(Int.init)
      ?? defaultValue
    return min(range.upperBound, max(range.lowerBound, supplied))
  }

  private func capturePostRecoveryVisualOracle(
    in region: SystemPictureInPictureWindowRegion
  )
    throws -> NativeRendererRecoveryVisualOracleEvidence {
    var timestamps: [Double] = []
    var frames: [VideoSurfaceCanonicalFrame] = []
    for index in 0..<NativeRendererRecoveryVisualCaptureBinding.requiredFrameCount {
      timestamps.append(ProcessInfo.processInfo.systemUptime)
      try frames.append(captureSystemPictureInPictureCanonicalFrame(in: region))
      if index < NativeRendererRecoveryVisualCaptureBinding.requiredFrameCount - 1 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
      }
    }
    let binding = NativeRendererRecoveryVisualCaptureBinding(
      captureSystemUptimeSeconds: timestamps,
      frames: frames
    )
    return try NativeRendererRecoveryVisualOracleEvidence.evaluated(
      binding: binding,
      minimumChangedPixelScore: 0.01
    )
  }

  private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
  }
}
