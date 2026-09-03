import XCTest

/// Candidate-bound, unattended proof for the two-hour adaptive HLS matrix row.
/// The app performs the long-running measurements while this test verifies and
/// attaches its evidence for host-side artifact/device identity binding.
final class AdaptiveHLSSoakDeviceUITests: ShowcaseIOSTestCase {
  func test_adaptiveHLSMatrixSoakRemainsBounded() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("The adaptive HLS soak qualifies only a physical iPhone")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_ADAPTIVE_HLS_SOAK_DEVICE"] == "YES"
    else {
      throw XCTSkip(
        "Set SWIFTVLC_ADAPTIVE_HLS_SOAK_DEVICE=YES for candidate-bound hardware runs"
      )
    }

    let duration = max(
      1,
      Int(ProcessInfo.processInfo.environment["SWIFTVLC_ADAPTIVE_SOAK_SECONDS"] ?? "7200")
        ?? 7200
    )
    let token = ProcessInfo.processInfo.environment["SWIFTVLC_ADAPTIVE_SOAK_TOKEN"]
      ?? "adaptive-\(UUID().uuidString.lowercased())"
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.adaptiveHLSSoakValidation.rawValue,
      LaunchArguments.adaptiveSoakDuration, String(duration),
      LaunchArguments.adaptiveSoakToken, token
    ]
    launchDirectlyHandlingQualificationPermissions()

    let state = element(AccessibilityID.AdaptiveHLSSoakValidation.stateLabel)
    let phase = element(AccessibilityID.AdaptiveHLSSoakValidation.phaseLabel)
    let progress = element(AccessibilityID.AdaptiveHLSSoakValidation.progressLabel)
    let result = element(AccessibilityID.AdaptiveHLSSoakValidation.resultLabel)
    let run = app.buttons[AccessibilityID.AdaptiveHLSSoakValidation.runButton]
    let video = element(AccessibilityID.AdaptiveHLSSoakValidation.videoView)
    let error = element(AccessibilityID.AdaptiveHLSSoakValidation.errorLabel)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    for _ in 0..<10
      where !video.exists
      || !video.frame.intersects(
        CGRect(origin: .zero, size: XCUIScreen.main.screenshot().image.size)
      ) {
      app.swipeDown()
    }

    let modes: Set = [
      "abr-low-ts",
      "abr-high-fmp4",
      "vod-ts",
      "event-fmp4",
      "live-ts",
      "live-fmp4",
      "retry-ts",
      "abr-ts"
    ]
    let deadline = Date().addingTimeInterval(TimeInterval(duration + 300))
    var lastCapturedElapsed = -1
    let maximumVisualGapSeconds = 60
    let visualCheckpointPeriodSeconds = 45
    var nextVisualCheckpointElapsed = 0
    var visualObservations: [AdaptiveVisualObservation] = []
    while Date() < deadline, !result.label.hasPrefix("pass:") {
      let observedMode = phase.label
      if modes.contains(observedMode), state.label == "playing" {
        let observedElapsed = try parseElapsedSeconds(progress.label)
        if
          visualObservations.last?.mode != observedMode
          || observedElapsed >= nextVisualCheckpointElapsed {
          RunLoop.current.run(until: Date().addingTimeInterval(2))
          guard phase.label == observedMode, state.label == "playing" else { continue }
          let visual = try captureInlineVideoSurfaceVisualEvidence(
            video,
            samples: 3,
            interval: 0.25
          )
          let elapsed = try parseElapsedSeconds(progress.label)
          guard
            phase.label == observedMode,
            elapsed > lastCapturedElapsed,
            visual.changedPixelScore >= 0.01,
            Set(visual.frameHashes).count == visual.frameHashes.count
          else {
            XCTFail("Adaptive visual checkpoint was stale or crossed a phase boundary")
            return
          }
          visualObservations.append(
            AdaptiveVisualObservation(
              elapsedSeconds: elapsed,
              mode: observedMode,
              visual: visual
            )
          )
          lastCapturedElapsed = elapsed
          nextVisualCheckpointElapsed = elapsed + visualCheckpointPeriodSeconds
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    }
    XCTAssertTrue(result.label.hasPrefix("pass:"), "Adaptive soak did not complete")
    XCTAssertFalse(error.exists, "Adaptive soak failed: \(error.label)")

    var evidence = try decodeEvidence(result.label)
    evidence["visualObservations"] = [
      "formatVersion": 1,
      "method": VideoSurfaceMotionEvidence.method,
      "records": visualObservations.map(\.rawRecord)
    ]
    evidence["visualOracle"] = [
      "formatVersion": 1,
      "method": VideoSurfaceMotionEvidence.method,
      "maximumMotionGapSeconds": maximumVisualGapSeconds,
      "checkpoints": visualObservations.map(\.derivedCheckpoint)
    ]
    let deviceObservedDuration = try XCTUnwrap(evidence["durationSeconds"] as? Int)
    XCTAssertGreaterThanOrEqual(deviceObservedDuration, duration)
    assertVisualCoverage(
      visualObservations,
      expectedModes: modes,
      deviceObservedDuration: deviceObservedDuration,
      maximumGapSeconds: maximumVisualGapSeconds
    )
    let coverage = try XCTUnwrap(evidence["playlistCoverage"] as? [String: Any])
    XCTAssertEqual(try Set(XCTUnwrap(coverage["playlistTypes"] as? [String])), ["vod", "event", "live"])
    XCTAssertEqual(try Set(XCTUnwrap(coverage["containers"] as? [String])), ["ts", "fmp4"])
    XCTAssertEqual(try Set(XCTUnwrap(coverage["variants"] as? [String])), ["low", "high"])
    XCTAssertGreaterThan(try XCTUnwrap(coverage["variantTransitions"] as? Int), 0)
    XCTAssertGreaterThan(try XCTUnwrap(coverage["discontinuityManifests"] as? Int), 0)
    XCTAssertGreaterThan(try XCTUnwrap(coverage["expiredWindows"] as? Int), 0)
    XCTAssertGreaterThan(try XCTUnwrap(coverage["retryFailures"] as? Int), 0)
    XCTAssertGreaterThan(try XCTUnwrap(coverage["retryRecoveries"] as? Int), 0)
    XCTAssertGreaterThan(try XCTUnwrap(coverage["cancellations"] as? Int), 0)
    XCTAssertFalse(try XCTUnwrap(evidence["memorySeries"] as? [[String: Any]]).isEmpty)
    XCTAssertNotNil(evidence["allocationProvenance"] as? [String: Any])
    XCTAssertEqual(evidence["sanitizerFindings"] as? Int, 0)
    XCTAssertEqual(evidence["crashes"] as? Int, 0)
    XCTAssertEqual(evidence["unboundedRecoveries"] as? Int, 0)
    XCTAssertEqual(evidence["monotonicGrowth"] as? Bool, false)
    XCTAssertEqual(
      evidence["upstreamCrossLink"] as? String,
      "https://code.videolan.org/videolan/vlc/-/work_items/29845"
    )

    attachQualificationEvidence(evidence, scenario: "adaptive-hls-soak")
    #endif
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

  private func parseElapsedSeconds(_ label: String) throws -> Int {
    let value = label.split(separator: "s", maxSplits: 1).first
      .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    return try XCTUnwrap(value, "Malformed adaptive elapsed label: \(label)")
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

  private func assertVisualCoverage(
    _ observations: [AdaptiveVisualObservation],
    expectedModes: Set<String>,
    deviceObservedDuration: Int,
    maximumGapSeconds: Int
  ) {
    XCTAssertEqual(Set(observations.map(\.mode)), expectedModes)
    guard let first = observations.first, let last = observations.last else {
      XCTFail("Adaptive soak produced no retained moving-frame observations")
      return
    }
    XCTAssertLessThanOrEqual(first.elapsedSeconds, maximumGapSeconds)
    XCTAssertGreaterThanOrEqual(
      last.elapsedSeconds,
      deviceObservedDuration - maximumGapSeconds
    )
    for (previous, current) in zip(observations, observations.dropFirst()) {
      XCTAssertGreaterThan(current.elapsedSeconds, previous.elapsedSeconds)
      XCTAssertLessThanOrEqual(
        current.elapsedSeconds - previous.elapsedSeconds,
        maximumGapSeconds,
        "Adaptive visual evidence contains an unobserved playback gap"
      )
    }
  }
}

private struct AdaptiveVisualObservation {
  let elapsedSeconds: Int
  let mode: String
  let visual: VideoSurfaceMotionEvidence

  var rawRecord: [String: Any] {
    [
      "elapsedSeconds": elapsedSeconds,
      "mode": mode,
      "frameHashes": visual.frameHashes,
      "adjacentChangedPixelRatios": visual.adjacentChangedPixelRatios,
      "changedPixelScore": visual.changedPixelScore
    ]
  }

  var derivedCheckpoint: [String: Any] {
    [
      "elapsedSeconds": elapsedSeconds,
      "mode": mode,
      "motionScore": visual.changedPixelScore,
      "distinctFrameHashes": Set(visual.frameHashes).count
    ]
  }
}
