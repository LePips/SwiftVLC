import XCTest

/// Fully unattended native PiP subtitle/OSD qualification. The app performs
/// media transitions and samples process state; this test proves the overlay
/// pixels are present in the actual SpringBoard PiP window at both real sizes.
final class NativeSubtitleMatrixDeviceUITests: ShowcaseIOSTestCase {
  func test_nativeSubtitleMatrixIsVisibleAndBounded() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Native subtitle qualification requires a physical iPhone")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SUBTITLE_DEVICE"] == "YES"
    else {
      throw XCTSkip("Set SWIFTVLC_NATIVE_SUBTITLE_DEVICE=YES for candidate-bound hardware runs")
    }
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    let duration = max(
      1,
      Int(ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SUBTITLE_SECONDS"] ?? "900")
        ?? 900
    )
    let encodedBaseURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SUBTITLE_BASE_URL_BASE64"]
    )
    let token = ProcessInfo.processInfo.environment["SWIFTVLC_NATIVE_SUBTITLE_TOKEN"]
      ?? "subtitle-\(UUID().uuidString.lowercased())"
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.nativeSubtitleMatrixValidation.rawValue,
      LaunchArguments.nativeSubtitleBaseURLBase64, encodedBaseURL,
      LaunchArguments.nativeSubtitleDuration, String(duration),
      LaunchArguments.nativeSubtitleToken, token
    ]
    app.launch()
    app.tap()

    let possible = element(AccessibilityID.NativeSubtitleMatrixValidation.possibleLabel)
    let active = element(AccessibilityID.NativeSubtitleMatrixValidation.activeLabel)
    let profileLabel = element(AccessibilityID.NativeSubtitleMatrixValidation.profileLabel)
    let result = element(AccessibilityID.NativeSubtitleMatrixValidation.resultLabel)
    let run = app.buttons[AccessibilityID.NativeSubtitleMatrixValidation.runButton]
    let error = element(AccessibilityID.NativeSubtitleMatrixValidation.errorLabel)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    run.tap()
    waitForLabel(possible, equals: "yes", timeout: 60)
    waitForLabel(active, equals: "yes", timeout: 60)

    let sequence = [
      "baseline", "text", "styled", "bitmap", "forced", "live",
      "adaptive-low", "adaptive-high", "hdr", "osd"
    ]
    var visual: [String: [String: Any]] = [:]
    var baseline: SystemPictureInPicturePixelSummary?
    var visualPasses: [String: Bool] = [:]
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")

    for profile in sequence {
      app.activate()
      waitForLabel(active, equals: "yes", timeout: 30)
      waitForLabel(profileLabel, equals: profile, timeout: 120)
      XCUIDevice.shared.press(.home)
      RunLoop.current.run(until: Date().addingTimeInterval(profile == "baseline" ? 8 : 20))
      var region = try locateSystemPictureInPictureWindow(samples: 5, interval: 0.5)
      let initialRegion = region
      let first = try bestSummary(profile: profile, region: region, suffix: "initial")

      springboard.coordinate(
        withNormalizedOffset: region.normalizedPoint(x: 0.5, y: 0.5)
      ).doubleTap()
      RunLoop.current.run(until: Date().addingTimeInterval(4))
      region = try locateSystemPictureInPictureWindow(samples: 5, interval: 0.5)
      let sizeChanged = abs(region.normalizedWidth - initialRegion.normalizedWidth) > 0.03
        || abs(region.normalizedHeight - initialRegion.normalizedHeight) > 0.03
      XCTAssertTrue(sizeChanged, "System PiP did not resize for \(profile)")
      let resized = try bestSummary(profile: profile, region: region, suffix: "resized")
      if profile == "baseline" {
        baseline = first
      }
      let reference = try XCTUnwrap(baseline)
      let passed = profile == "baseline"
        || overlayIsVisible(profile: profile, samples: [first, resized], baseline: reference)
      visualPasses[profile] = passed
      XCTAssertTrue(passed, "No measurable \(profile) overlay appeared in system PiP")
      visual[profile] = [
        "initial": dictionary(first),
        "resized": dictionary(resized),
        "initialGeometry": geometry(region: initialRegion),
        "resizedGeometry": geometry(region: region),
        "visibleAtBothSizes": passed
      ]
    }

    app.activate()
    waitForPrefix(result, prefix: "pass:", timeout: TimeInterval(duration + 300))
    XCTAssertFalse(error.exists, "Native subtitle matrix failed: \(error.label)")
    var evidence = try decodeEvidence(result.label)
    XCTAssertGreaterThanOrEqual(evidence["durationSeconds"] as? Int ?? 0, 900)
    XCTAssertEqual(evidence["profileSequence"] as? [String], sequence)
    XCTAssertEqual((evidence["timingTransitions"] as? [[String: Any]])?.count, sequence.count)
    let adaptive = try XCTUnwrap(evidence["adaptiveResolution"] as? [String: Any])
    XCTAssertEqual(try Set(XCTUnwrap(adaptive["variants"] as? [String])), ["low", "high"])
    let successfulByVariant = try XCTUnwrap(
      adaptive["successfulSegmentsByVariant"] as? [String: Int]
    )
    XCTAssertGreaterThan(successfulByVariant["low"] ?? 0, 0)
    XCTAssertGreaterThan(successfulByVariant["high"] ?? 0, 0)

    let supportProfiles = ["text", "styled", "bitmap", "forced", "live", "osd"]
    var support: [String: String] = [:]
    for profile in supportProfiles {
      XCTAssertEqual(visualPasses[profile], true)
      support[profile] = "supported"
    }
    evidence["supportMatrix"] = support
    evidence["resizeGeometry"] = visual
    var metrics = try XCTUnwrap(evidence["metrics"] as? [String: Any])
    var color = try XCTUnwrap(metrics["colorHDRImpact"] as? [String: Any])
    color["screenshotMeasurements"] = [
      "baseline": visual["baseline"] as Any,
      "hdrWithSubtitle": visual["hdr"] as Any,
      "osd": visual["osd"] as Any,
      "measurement": "SpringBoard system-PiP RGB pixel summary"
    ]
    metrics["colorHDRImpact"] = color
    evidence["metrics"] = metrics
    attachQualificationEvidence(evidence, scenario: "native-subtitle-matrix")
    #endif
  }

  private func bestSummary(
    profile: String,
    region: SystemPictureInPictureWindowRegion,
    suffix: String
  )
    throws -> SystemPictureInPicturePixelSummary {
    var summaries: [SystemPictureInPicturePixelSummary] = []
    for index in 0..<4 {
      try summaries.append(
        captureSystemPictureInPicturePixelSummary(
          in: region,
          attachmentName: "native-subtitle-\(profile)-\(suffix)-\(index)"
        )
      )
      RunLoop.current.run(until: Date().addingTimeInterval(1))
    }
    return try XCTUnwrap(summaries.max(by: { signal(profile, $0) < signal(profile, $1) }))
  }

  private func overlayIsVisible(
    profile: String,
    samples: [SystemPictureInPicturePixelSummary],
    baseline: SystemPictureInPicturePixelSummary
  ) -> Bool {
    samples.allSatisfy { sample in
      switch profile {
      case "text", "forced", "adaptive-low", "adaptive-high", "hdr":
        sample.brightPixelRatio >= max(0.0004, baseline.brightPixelRatio + 0.00025)
      case "styled", "osd":
        sample.yellowPixelRatio >= max(0.0004, baseline.yellowPixelRatio + 0.00025)
      case "bitmap", "live":
        sample.greenPixelRatio >= max(0.0004, baseline.greenPixelRatio + 0.00025)
      default:
        false
      }
    }
  }

  private func signal(
    _ profile: String,
    _ summary: SystemPictureInPicturePixelSummary
  ) -> Double {
    switch profile {
    case "styled", "osd": summary.yellowPixelRatio
    case "bitmap", "live": summary.greenPixelRatio
    default: summary.brightPixelRatio
    }
  }

  private func dictionary(_ summary: SystemPictureInPicturePixelSummary) -> [String: Any] {
    [
      "sampledPixels": summary.sampledPixels,
      "brightPixelRatio": summary.brightPixelRatio,
      "saturatedPixelRatio": summary.saturatedPixelRatio,
      "yellowPixelRatio": summary.yellowPixelRatio,
      "greenPixelRatio": summary.greenPixelRatio,
      "nonGrayPixelRatio": summary.nonGrayPixelRatio,
      "meanRed": summary.meanRed,
      "meanGreen": summary.meanGreen,
      "meanBlue": summary.meanBlue
    ]
  }

  private func geometry(region: SystemPictureInPictureWindowRegion) -> [String: Double] {
    [
      "x": region.normalizedX,
      "y": region.normalizedY,
      "width": region.normalizedWidth,
      "height": region.normalizedHeight
    ]
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitForPrefix(_ element: XCUIElement, prefix: String, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in element.exists && element.label.hasPrefix(prefix) }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
