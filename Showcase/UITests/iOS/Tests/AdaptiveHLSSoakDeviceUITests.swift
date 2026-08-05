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

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
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
    app.launch()
    app.tap()

    let result = element(AccessibilityID.AdaptiveHLSSoakValidation.resultLabel)
    let run = app.buttons[AccessibilityID.AdaptiveHLSSoakValidation.runButton]
    let error = element(AccessibilityID.AdaptiveHLSSoakValidation.errorLabel)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForPrefix(result, prefix: "pass:", timeout: TimeInterval(duration + 300))
    XCTAssertFalse(error.exists, "Adaptive soak failed: \(error.label)")

    let evidence = try decodeEvidence(result.label)
    XCTAssertGreaterThanOrEqual(try XCTUnwrap(evidence["durationSeconds"] as? Int), duration)
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
