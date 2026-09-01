import XCTest

/// Opt-in physical exploration of vmem PTS/rate semantics. This test attaches
/// an ordinary report and never calls the candidate qualification collector.
final class PiPCadenceSemanticsProbeDeviceUITests: ShowcaseIOSTestCase {
  func test_reportOnlyVmemCadenceSemanticsProbe() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("The cadence semantics probe requires real SpringBoard PiP")
    #else
    guard
      ProcessInfo.processInfo.environment[
        "SWIFTVLC_PIP_CADENCE_SEMANTICS_PROBE"
      ] == "YES"
    else {
      throw XCTSkip(
        "Set SWIFTVLC_PIP_CADENCE_SEMANTICS_PROBE=YES to run this exploratory probe"
      )
    }
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    let encodedBaseURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment[
        "SWIFTVLC_PIP_CADENCE_BASE_URL_BASE64"
      ]
    )
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.pipCadenceSemanticsProbe.rawValue,
      LaunchArguments.pipCadenceBaseURLBase64, encodedBaseURL
    ]
    app.launch()
    app.tap()

    let possible = element(AccessibilityID.PiPCadenceSemanticsProbe.possibleLabel)
    let active = element(AccessibilityID.PiPCadenceSemanticsProbe.activeLabel)
    let result = element(AccessibilityID.PiPCadenceSemanticsProbe.resultLabel)
    let run = app.buttons[AccessibilityID.PiPCadenceSemanticsProbe.runButton]
    let error = element(AccessibilityID.PiPCadenceSemanticsProbe.errorLabel)
    waitForLabel(possible, equals: "yes", timeout: 30)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    let runStartedSystemUptime = ProcessInfo.processInfo.systemUptime
    run.tap()
    waitForLabel(active, equals: "yes", timeout: 60)

    XCUIDevice.shared.press(.home)
    let region = try locateSystemPictureInPictureWindow(
      samples: 5,
      interval: 0.25,
      retainDiagnostics: false
    )
    var timedFrames: [ProbeTimedFrame] = []
    let captureDeadline = runStartedSystemUptime + 95
    while ProcessInfo.processInfo.systemUptime < captureDeadline {
      let captureStarted = ProcessInfo.processInfo.systemUptime
      let frame = try captureSystemPictureInPictureCanonicalFrame(in: region)
      let captureEnded = ProcessInfo.processInfo.systemUptime
      timedFrames.append(
        ProbeTimedFrame(
          systemUptime: (captureStarted + captureEnded) / 2,
          frame: frame
        )
      )
      RunLoop.current.run(until: Date().addingTimeInterval(0.50))
    }

    app.activate()
    waitForPrefix(result, prefix: "report:", timeout: 120)
    XCTAssertFalse(error.exists, "Cadence semantics probe failed operationally: \(error.label)")

    var report = try decodeReport(result.label)
    XCTAssertEqual(report["releaseCreditEligible"] as? Bool, false)
    XCTAssertEqual(
      report["purpose"] as? String,
      "exploratory-vmem-output-attempt-cadence-semantics"
    )
    let windows = try XCTUnwrap(report["windows"] as? [[String: Any]])
    XCTAssertEqual(windows.count, 9)
    report["springBoardFrames"] = try makeSpringBoardFrameReport(
      windows: windows,
      timedFrames: timedFrames
    )
    report["releaseCreditEligible"] = false

    let data = try JSONSerialization.data(
      withJSONObject: report,
      options: [.prettyPrinted, .sortedKeys]
    )
    let attachment = XCTAttachment(
      data: data,
      uniformTypeIdentifier: "public.json"
    )
    attachment.name = "exploratory-pip-cadence-semantics-probe"
    attachment.lifetime = .keepAlways
    add(attachment)
    #endif
  }

  private func makeSpringBoardFrameReport(
    windows: [[String: Any]],
    timedFrames: [ProbeTimedFrame]
  )
    throws -> [String: Any] {
    var records: [[String: Any]] = []
    for window in windows {
      let profile = try XCTUnwrap(window["profile"] as? String)
      let requestedRate = try number(window["requestedRate"], name: "requested rate")
      let start = try number(
        window["windowStartSystemUptime"],
        name: "window start uptime"
      )
      let end = try number(
        window["windowEndSystemUptime"],
        name: "window end uptime"
      )
      let candidates = timedFrames.filter {
        $0.systemUptime >= start && $0.systemUptime <= end
      }
      guard candidates.count >= 3 else {
        throw ProbeVisualFailure(
          "Only \(candidates.count) SpringBoard frames fell inside "
            + "\(profile)@\(requestedRate)x [\(start), \(end)]"
        )
      }
      let selected = [
        candidates[0],
        candidates[candidates.count / 2],
        candidates[candidates.count - 1]
      ]
      let motion = try XCTUnwrap(
        VideoSurfaceMotionEvidenceAnalyzer.analyze(selected.map(\.frame))
      )
      records.append([
        "profile": profile,
        "requestedRate": requestedRate,
        "windowStartSystemUptime": start,
        "windowEndSystemUptime": end,
        "captureSystemUptimes": selected.map(\.systemUptime),
        "canonicalRGB8Base64": selected.map {
          Data($0.frame.rgb).base64EncodedString()
        },
        "frameHashes": motion.frameHashes,
        "adjacentChangedPixelRatios": motion.adjacentChangedPixelRatios,
        "changedPixelScore": motion.changedPixelScore
      ])
    }
    return [
      "formatVersion": 1,
      "method": VideoSurfaceMotionEvidence.method,
      "framesPerWindow": 3,
      "records": records
    ]
  }

  private func decodeReport(_ label: String) throws -> [String: Any] {
    let prefix = "report:"
    guard label.hasPrefix(prefix) else {
      throw ProbeVisualFailure("Probe result did not contain a report")
    }
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func number(_ value: Any?, name: String) throws -> Double {
    guard let value = value as? NSNumber else {
      throw ProbeVisualFailure("Missing \(name)")
    }
    return value.doubleValue
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

private struct ProbeTimedFrame {
  let systemUptime: Double
  let frame: VideoSurfaceCanonicalFrame
}

private struct ProbeVisualFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
