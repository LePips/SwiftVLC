import AVFoundation
import XCTest

/// Candidate-bound proof of managed-audio recovery while real system PiP is
/// active. A separate XCTest runner audio session takes and returns focus; the
/// candidate also receives an explicitly recorded old-device-unavailable event.
final class PiPInterruptionDeviceUITests: ShowcaseIOSTestCase {
  private struct BackendEvidence {
    let backend: String
    let interruptionBeganCount: Int
    let interruptionEndedCount: Int
    let routeLossCount: Int
    let audioBuffersBeforeRouteResume: Int
    let audioBuffersAfterRouteResume: Int
    let audioBuffersBeforeInterruption: Int
    let audioBuffersAfterInterruption: Int
    let orderedEvents: [String]

    var json: [String: Any] {
      [
        "backend": backend,
        "interruptionBeganCount": interruptionBeganCount,
        "interruptionEndedCount": interruptionEndedCount,
        "routeLossCount": routeLossCount,
        "audioBuffersBeforeRouteResume": audioBuffersBeforeRouteResume,
        "audioBuffersAfterRouteResume": audioBuffersAfterRouteResume,
        "routeAudioRecovered": audioBuffersAfterRouteResume > audioBuffersBeforeRouteResume,
        "audioBuffersBeforeInterruption": audioBuffersBeforeInterruption,
        "audioBuffersAfterInterruption": audioBuffersAfterInterruption,
        "audioRecovered": audioBuffersAfterInterruption > audioBuffersBeforeInterruption,
        "orderedEvents": orderedEvents,
        "activeAfterRecovery": true,
        "systemPiPMotionAfterRecovery": "pass"
      ]
    }
  }

  func test_audioInterruptionAndRouteLossAcrossNativeAndDirectBackends() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_INTERRUPTION_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_INTERRUPTION_DEVICE=YES for candidate-bound hardware runs")
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

    let results = try ["native", "direct"].map {
      try runBackend($0, baseLogPath: baseLogPath)
    }
    let unexpectedStops = results.reduce(0) { count, result in
      count
        + result.orderedEvents.filter {
          $0.hasPrefix("didStop:") && $0 != "didStop:programmatic"
        }.count
    }
    XCTAssertEqual(unexpectedStops, 0)
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "interruptions",
        "events": [
          "started": true,
          "unexpectedStopCount": unexpectedStops,
          "order": "pass"
        ],
        "interruptionRecovery": "pass",
        "routeChangeRecovery": "pass",
        "interruptionSource": "exclusive-XCTest-runner-audio-session",
        "routeLossSource": "deterministic-oldDeviceUnavailable-notification",
        "backends": Dictionary(uniqueKeysWithValues: results.map { ($0.backend, $0.json) }),
        "recoveryOutcome": "preserved",
        "systemPiPMotionAfterRecovery": "pass"
      ],
      scenario: "interruptions"
    )
    #endif
  }

  private func runBackend(
    _ backend: String,
    baseLogPath: String
  )
    throws -> BackendEvidence {
    app.terminate()
    replaceLaunchArgument(
      LaunchArguments.route,
      with: UITestRoute.pipInterruptionValidation.rawValue
    )
    replaceLaunchArgument(LaunchArguments.pipRenderingPath, with: backend)
    let cycleLogPath =
      (baseLogPath as NSString).deletingPathExtension + "-\(backend).jsonl"
    replaceLaunchArgument(LaunchArguments.logPath, with: cycleLogPath)
    app.launch()
    app.tap()

    let state = element(AccessibilityID.PiPInterruptionValidation.stateLabel)
    let possible = element(AccessibilityID.PiPInterruptionValidation.possibleLabel)
    let active = element(AccessibilityID.PiPInterruptionValidation.activeLabel)
    let lifecycle = element(AccessibilityID.PiPInterruptionValidation.lifecycleEventsLabel)
    let interruptions = element(
      AccessibilityID.PiPInterruptionValidation.interruptionCountsLabel
    )
    let routeLosses = element(AccessibilityID.PiPInterruptionValidation.routeLossCountLabel)
    let playedAudioBuffers = element(
      AccessibilityID.PiPInterruptionValidation.playedAudioBuffersLabel
    )
    let start = app.buttons[AccessibilityID.PiPInterruptionValidation.startButton]
    let injectRouteLoss = app.buttons[
      AccessibilityID.PiPInterruptionValidation.injectRouteLossButton
    ]
    let resume = app.buttons[AccessibilityID.PiPInterruptionValidation.resumeButton]
    let stop = app.buttons[AccessibilityID.PiPInterruptionValidation.stopButton]
    let error = element(AccessibilityID.PiPInterruptionValidation.errorLabel)

    waitForLabel(state, equals: "playing", timeout: 20)
    waitForLabel(possible, equals: "yes", timeout: 15)
    reveal(start)
    start.tap()
    waitForLabel(active, equals: "yes", timeout: 10)
    waitForLifecyclePrefix(lifecycle, prefix: "willStart|didStart", timeout: 10)
    _ = waitForIntegerLabel(playedAudioBuffers, greaterThan: 0, timeout: 10)

    reveal(injectRouteLoss)
    injectRouteLoss.tap()
    waitForLabel(routeLosses, equals: "1", timeout: 5)
    waitForLabel(state, equals: "paused", timeout: 10)
    waitForLabel(active, equals: "yes", timeout: 5)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    let audioBuffersBeforeRouteResume = Int(playedAudioBuffers.label) ?? -1
    XCTAssertGreaterThanOrEqual(audioBuffersBeforeRouteResume, 0)
    reveal(resume)
    resume.tap()
    waitForLabel(state, equals: "playing", timeout: 15)
    let audioBuffersAfterRouteResume = waitForIntegerLabel(
      playedAudioBuffers,
      greaterThan: audioBuffersBeforeRouteResume,
      timeout: 15
    )

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(backend) PiP was not moving before interruption: \(failure)")
    }
    let audioBuffersBeforeInterruption = waitForIntegerLabel(
      playedAudioBuffers,
      greaterThan: audioBuffersAfterRouteResume,
      timeout: 15
    )
    try interruptCandidateAudioSession()
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(backend) PiP did not recover after interruption: \(failure)")
    }
    let audioBuffersAfterInterruption = waitForIntegerLabel(
      playedAudioBuffers,
      greaterThan: audioBuffersBeforeInterruption,
      timeout: 15
    )

    app.activate()
    waitForInterruptionPair(interruptions, timeout: 10)
    waitForLabel(state, equals: "playing", timeout: 15)
    waitForLabel(active, equals: "yes", timeout: 10)
    reveal(stop)
    stop.tap()
    waitForLabel(active, equals: "no", timeout: 10)
    let expectedLifecycle =
      "willStart|didStart|willStop:programmatic|didStop:programmatic"
    waitForLabel(lifecycle, equals: expectedLifecycle, timeout: 10)
    RunLoop.current.run(until: Date().addingTimeInterval(1))
    XCTAssertEqual(
      lifecycle.label,
      expectedLifecycle,
      "Unexpected trailing interruption lifecycle event"
    )
    XCTAssertFalse(error.exists, "\(backend) disruption qualification failed: \(error.label)")

    let counts = try parseInterruptionCounts(interruptions.label)
    XCTAssertEqual(counts.began, 1)
    XCTAssertEqual(counts.ended, 1)
    let routeLossCount = Int(routeLosses.label) ?? -1
    XCTAssertEqual(routeLossCount, 1)
    return BackendEvidence(
      backend: backend,
      interruptionBeganCount: counts.began,
      interruptionEndedCount: counts.ended,
      routeLossCount: routeLossCount,
      audioBuffersBeforeRouteResume: audioBuffersBeforeRouteResume,
      audioBuffersAfterRouteResume: audioBuffersAfterRouteResume,
      audioBuffersBeforeInterruption: audioBuffersBeforeInterruption,
      audioBuffersAfterInterruption: audioBuffersAfterInterruption,
      orderedEvents: lifecycle.label.split(separator: "|").map(String.init)
    )
  }

  private func interruptCandidateAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)
    var isActive = true
    defer {
      if isActive {
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
      }
    }
    RunLoop.current.run(until: Date().addingTimeInterval(2))
    try session.setActive(false, options: .notifyOthersOnDeactivation)
    isActive = false
    RunLoop.current.run(until: Date().addingTimeInterval(3))
  }

  private func waitForInterruptionPair(_ element: XCUIElement, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in
      guard let counts = try? self.parseInterruptionCounts(element.label) else { return false }
      return counts.began >= 1 && counts.began == counts.ended
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected a balanced interruption pair, got: \(element.label)"
    )
  }

  private func parseInterruptionCounts(_ label: String) throws -> (began: Int, ended: Int) {
    let values = label.split(separator: ":").compactMap { Int($0) }
    guard values.count == 2 else {
      throw InterruptionEvidenceFailure("Malformed interruption counts: \(label)")
    }
    return (values[0], values[1])
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

private struct InterruptionEvidenceFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
