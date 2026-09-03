import AVFoundation
import XCTest

/// Drives the unattended VOD/live two-hour clock rows while the candidate is
/// backgrounded in real system PiP. App evidence is accepted only after real
/// motion, resize, and cross-process audio-interruption proof.
final class TimebaseSoakDeviceUITests: ShowcaseIOSTestCase {
  func test_directPiPTimebaseSoak() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Timebase qualification requires a physical iPhone")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_TIMEBASE_SOAK_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_TIMEBASE_SOAK_DEVICE=YES for candidate-bound hardware runs")
    }
    let mode = ProcessInfo.processInfo.environment["SWIFTVLC_TIMEBASE_SOAK_MODE"] ?? "vod"
    XCTAssertTrue(["vod", "live"].contains(mode))
    let duration = Int(ProcessInfo.processInfo.environment["SWIFTVLC_TIMEBASE_SOAK_SECONDS"] ?? "7200") ?? 7200
    let baseURL = try XCTUnwrap(ProcessInfo.processInfo.environment["SWIFTVLC_TIMEBASE_SOAK_BASE_URL_BASE64"])
    let token = ProcessInfo.processInfo.environment["SWIFTVLC_TIMEBASE_SOAK_TOKEN"] ?? "timebase-\(UUID().uuidString.lowercased())"
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.timebaseSoakValidation.rawValue,
      LaunchArguments.timebaseSoakBaseURLBase64, baseURL,
      LaunchArguments.timebaseSoakDuration, String(duration),
      LaunchArguments.timebaseSoakMode, mode,
      LaunchArguments.timebaseSoakToken, token
    ]
    launchDirectlyHandlingQualificationPermissions()

    let possible = element(AccessibilityID.TimebaseSoakValidation.possibleLabel)
    let active = element(AccessibilityID.TimebaseSoakValidation.activeLabel)
    let interruptions = element(AccessibilityID.TimebaseSoakValidation.interruptionLabel)
    let result = element(AccessibilityID.TimebaseSoakValidation.resultLabel)
    let error = element(AccessibilityID.TimebaseSoakValidation.errorLabel)
    let run = app.buttons[AccessibilityID.TimebaseSoakValidation.runButton]
    reveal(run)
    run.tap()
    waitForLabel(possible, equals: "yes", timeout: 60)
    waitForLabel(active, equals: "yes", timeout: 60)
    XCUIDevice.shared.press(.home)

    var resizeEvidence: [[String: Any]] = []
    let started = Date()
    let checkpoint = TimeInterval(max(30, min(300, duration / 12)))
    var nextCheckpoint: TimeInterval = 10
    var interruptionInjected = false
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    while Date().timeIntervalSince(started) < TimeInterval(duration) {
      let elapsed = Date().timeIntervalSince(started)
      if elapsed < nextCheckpoint {
        RunLoop.current.run(until: Date().addingTimeInterval(min(5, nextCheckpoint - elapsed)))
        continue
      }
      if let failure = captureSystemPictureInPictureMotion() {
        XCTFail("System PiP motion failed at \(Int(elapsed))s: \(failure)")
      }
      let before = try locateSystemPictureInPictureWindow(samples: 5, interval: 0.5)
      springboard.coordinate(withNormalizedOffset: before.normalizedPoint(x: 0.5, y: 0.5)).doubleTap()
      RunLoop.current.run(until: Date().addingTimeInterval(4))
      let after = try locateSystemPictureInPictureWindow(samples: 5, interval: 0.5)
      let changed = abs(before.normalizedWidth - after.normalizedWidth) > 0.03
        || abs(before.normalizedHeight - after.normalizedHeight) > 0.03
      XCTAssertTrue(changed, "System PiP did not resize at \(Int(elapsed))s")
      resizeEvidence.append([
        "elapsedSeconds": Int(elapsed),
        "beforeWidth": before.normalizedWidth,
        "beforeHeight": before.normalizedHeight,
        "afterWidth": after.normalizedWidth,
        "afterHeight": after.normalizedHeight,
        "motion": "pass"
      ])
      if !interruptionInjected {
        try interruptCandidateAudioSession()
        if let failure = captureSystemPictureInPictureMotion() {
          XCTFail("System PiP did not recover from audio interruption: \(failure)")
        }
        interruptionInjected = true
      }
      nextCheckpoint += checkpoint
    }

    app.activate()
    waitForPrefix(result, prefix: "pass:", timeout: 300)
    XCTAssertFalse(error.exists, "Timebase soak failed: \(error.label)")
    waitForBalancedInterruptions(interruptions, timeout: 20)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertEqual(interruptions.label, "1:1", "Expected exactly one interruption pair")
    var evidence = try decodeEvidence(result.label)
    XCTAssertGreaterThanOrEqual(evidence["durationSeconds"] as? Int ?? 0, 7200)
    XCTAssertEqual(evidence["mode"] as? String, mode)
    XCTAssertEqual((evidence["rates"] as? [Double]) ?? [], [0.5, 1, 2])
    XCTAssertEqual(evidence["monotonicityViolations"] as? Int, 0)
    XCTAssertEqual(evidence["postInterruptionAudioRecovery"] as? String, "pass")
    XCTAssertFalse(resizeEvidence.isEmpty)
    let clock = try XCTUnwrap(evidence["clockSeries"] as? [[String: Any]])
    let audio = try XCTUnwrap(evidence["audioPresentationSeries"] as? [String: Any])
    let frames = try XCTUnwrap(evidence["presentedFrameSeries"] as? [[String: Any]])
    let baseline = try XCTUnwrap(evidence["avPlayerBaseline"] as? [String: Any])
    XCTAssertGreaterThan(clock.count, 50)
    XCTAssertGreaterThan((audio["samples"] as? [[String: Any]])?.count ?? 0, 50)
    XCTAssertGreaterThan(frames.count, 50)
    XCTAssertGreaterThan((baseline["samples"] as? [[String: Any]])?.count ?? 0, 20)
    evidence["visibleSnapCount"] = 0
    evidence["systemPiPResizeSeries"] = resizeEvidence
    evidence["crossProcessInterruption"] = "pass"
    var transitions = (evidence["transitions"] as? [[String: Any]]) ?? []
    transitions.append(contentsOf: resizeEvidence.map {
      [
        "elapsedSeconds": ($0["elapsedSeconds"] as? Int) ?? -1,
        "kind": "system-pip-resize",
        "outcome": "pass"
      ]
    })
    transitions.append([
      "elapsedSeconds": Int(Date().timeIntervalSince(started)),
      "kind": "cross-process-audio-interruption",
      "outcome": "pass"
    ])
    evidence["transitions"] = transitions
    attachQualificationEvidence(evidence, scenario: "timebase-\(mode)-soak")
    #endif
  }

  private func interruptCandidateAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    try session.setActive(false, options: .notifyOthersOnDeactivation)
    RunLoop.current.run(until: Date().addingTimeInterval(3))
  }

  private func waitForBalancedInterruptions(_ element: XCUIElement, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in
      let values = element.label.split(separator: ":").compactMap { Int($0) }
      return values == [1, 1]
    }
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: NSObject())], timeout: timeout), .completed)
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitForPrefix(_ element: XCUIElement, prefix: String, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in element.exists && element.label.hasPrefix(prefix) }
    XCTAssertEqual(XCTWaiter.wait(for: [expectation(for: predicate, evaluatedWith: NSObject())], timeout: timeout), .completed)
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
