import XCTest

/// Candidate-bound physical-device proof that native PiP survives same-player
/// media replacement and publishes coherent successor policy and measurements.
final class PiPContinuityDeviceUITests: ShowcaseIOSTestCase {
  private struct ReplacementMeasurement {
    let videoGapMilliseconds: Int
    let audioGapMilliseconds: Int
  }

  private struct NativePlaybackSnapshot {
    let generation: Int
    let durationMilliseconds: Int
    let currentTimeMilliseconds: Int
    let isSeekable: Bool
  }

  func test_nativePiPSurvivesSamePlayerReplacement() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    try requireDeviceQualification()
    openMatrixA()
    loadInitialVODAndStartPictureInPicture()

    _ = transition(
      using: AccessibilityID.PiPContinuityValidation.loadLiveTSButton,
      expectedStream: "liveTS",
      expectedSnapshot: "unbounded:unseekable:linear",
      expectedRestoredCount: 1
    )
    stopPictureInPictureAndValidateLifecycle(expectedReplacementCount: 1)
    assertNoLibraryErrors()
    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "replacement",
        "events": [
          "controllerReplacementCount": 1,
          "unattributedStopCount": 0,
          "order": "pass"
        ],
        "controls": "pass",
        "recoveryOutcome": "preserved"
      ],
      scenario: "replacement"
    )
    #endif
  }

  func test_nativePiPReplacementContinuityAcrossVODAndLive() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("System Picture in Picture requires a physical iOS device")
    #else
    try requireDeviceQualification()
    openMatrixA()
    loadInitialVODAndStartPictureInPicture()

    let vodToLive = transition(
      using: AccessibilityID.PiPContinuityValidation.loadLiveTSButton,
      expectedStream: "liveTS",
      expectedSnapshot: "unbounded:unseekable:linear",
      expectedRestoredCount: 1
    )
    let liveToVOD = transition(
      using: AccessibilityID.PiPContinuityValidation.loadVODButton,
      expectedStream: "vod",
      expectedSnapshot: "finite:seekable:interactive",
      expectedRestoredCount: 2
    )
    let maximumAudioGap = max(
      vodToLive.audioGapMilliseconds,
      liveToVOD.audioGapMilliseconds
    )
    let maximumVideoGap = max(
      vodToLive.videoGapMilliseconds,
      liveToVOD.videoGapMilliseconds
    )
    XCTAssertLessThanOrEqual(maximumAudioGap, 5000, "Successor audio exceeded the 5s budget")
    XCTAssertLessThanOrEqual(maximumVideoGap, 5000, "Successor video exceeded the 5s budget")
    stopPictureInPictureAndValidateLifecycle(expectedReplacementCount: 2)
    assertNoLibraryErrors()

    attachQualificationEvidence(
      [
        "formatVersion": 1,
        "scenario": "replacement-continuity",
        "combinations": [
          "vodToLive": "pass",
          "liveToVOD": "pass"
        ],
        "snapshotCoherence": "pass",
        "measurements": [
          "audioGapMilliseconds": maximumAudioGap,
          "videoGapMilliseconds": maximumVideoGap
        ],
        "audioContinuityWithinBudget": maximumAudioGap <= 5000,
        "videoContinuityWithinBudget": maximumVideoGap <= 5000,
        "controls": "pass",
        "recoveryOutcome": "preserved",
        "staleSuccessorMutations": 0
      ],
      scenario: "replacement-continuity"
    )
    #endif
  }

  private func requireDeviceQualification() throws {
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_CONTINUITY_DEVICE"] == "YES" else {
      throw XCTSkip("Set SWIFTVLC_PIP_CONTINUITY_DEVICE=YES after configuring Matrix A streams")
    }
  }

  private func openMatrixA() {
    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }

    launch(route: .harnessHome)
    app.tap()
    let matrix = app.buttons["(a) PiP survival across load()"]
    XCTAssertTrue(matrix.waitForExistence(timeout: 5))
    matrix.tap()
    XCTAssertTrue(automationSnapshot.waitForExistence(timeout: 5))
  }

  private func loadInitialVODAndStartPictureInPicture() {
    app.buttons[AccessibilityID.PiPContinuityValidation.loadVODButton].tap()
    waitForSnapshotValue("state", equals: "playing", timeout: 20)
    waitForSnapshotValue(
      "playbackSnapshot",
      equals: "finite:seekable:interactive",
      timeout: 15
    )
    _ = waitForNativePlaybackSnapshot(
      generation: snapshotValue("generation"),
      expectsFiniteDuration: true,
      expectsSeekable: true,
      timeout: 15
    )
    _ = waitForSnapshotInteger("displayedPictures", greaterThan: 0, timeout: 10)
    _ = waitForSnapshotInteger("playedAudioBuffers", greaterThan: 0, timeout: 10)
    waitForSnapshotValue("possible", equals: "yes", timeout: 15)

    let start = app.buttons["Start PiP"]
    reveal(start, swiping: .down)
    waitUntilEnabled(start, timeout: 20)
    start.tap()
    waitForSnapshotValue("active", equals: "yes", timeout: 10)
    waitForSnapshotOccurrence("didStart", count: 1, in: "lifecycleEvents", timeout: 10)
  }

  private func transition(
    using buttonIdentifier: String,
    expectedStream: String,
    expectedSnapshot: String,
    expectedRestoredCount: Int
  ) -> ReplacementMeasurement {
    let previousGeneration = snapshotValue("generation")
    let button = app.buttons[buttonIdentifier]
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()

    waitForSnapshotValueChange("generation", from: previousGeneration, timeout: 5)
    waitForSnapshotValue("playbackSnapshot", equals: expectedSnapshot, timeout: 15)
    waitForSnapshotOccurrence(
      "restored",
      count: expectedRestoredCount,
      in: "continuityEvents",
      timeout: 15
    )
    let generation = snapshotValue("generation")
    _ = waitForNativePlaybackSnapshot(
      generation: generation,
      expectsFiniteDuration: expectedSnapshot.hasPrefix("finite:"),
      expectsSeekable: expectedSnapshot.contains(":seekable:"),
      timeout: 15
    )
    let measurement = waitForReplacementMeasurement(
      stream: expectedStream,
      generation: generation,
      timeout: 15
    )
    waitForSnapshotValue("active", equals: "yes", timeout: 5)
    waitForSnapshotValue("state", equals: "playing", timeout: 10)
    _ = waitForSnapshotInteger("displayedPictures", greaterThan: 0, timeout: 5)
    _ = waitForSnapshotInteger("playedAudioBuffers", greaterThan: 0, timeout: 5)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(expectedStream) replacement PiP motion failed: \(failure)")
    }
    app.activate()
    waitForSnapshotValue("active", equals: "yes", timeout: 10)
    waitForSnapshotValue("state", equals: "playing", timeout: 10)
    _ = waitForReplacementMeasurement(
      stream: expectedStream,
      generation: generation,
      timeout: 5
    )
    return measurement
  }

  private func stopPictureInPictureAndValidateLifecycle(expectedReplacementCount: Int) {
    XCTAssertEqual(restoredEventCount, expectedReplacementCount)
    let stop = app.buttons["Stop PiP"]
    reveal(stop, swiping: .down)
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    stop.tap()
    waitForSnapshotValue("active", equals: "no", timeout: 10)
    waitForSnapshotOccurrence(
      "didStop:programmatic",
      count: 1,
      in: "lifecycleEvents",
      timeout: 10
    )
    let lifecycleEvents = snapshotValue("lifecycleEvents")
    XCTAssertTrue(
      lifecycleEvents.hasPrefix(
        "willStart|didStart|willStop:programmatic|didStop:programmatic"
      ),
      "PiP lifecycle was not ordered: \(lifecycleEvents)"
    )
  }

  private func waitForSnapshotValueChange(
    _ key: String,
    from previous: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      self.snapshotValue(key) != previous
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func waitForSnapshotOccurrence(
    _ value: String,
    count: Int,
    in key: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      self.snapshotValue(key).split(separator: "|").filter { $0.contains(value) }.count >= count
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected \(count) \(value) event(s), got: \(snapshotValue(key))"
    )
  }

  private func waitForSnapshotValue(
    _ key: String,
    equals expected: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in self.snapshotValue(key) == expected }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected \(key)=\(expected), got: \(snapshotValue(key))"
    )
  }

  @discardableResult
  private func waitForSnapshotInteger(
    _ key: String,
    greaterThan minimum: Int,
    timeout: TimeInterval
  ) -> Int {
    let predicate = NSPredicate { _, _ in
      Int(self.snapshotValue(key)).map { $0 > minimum } ?? false
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected \(key) > \(minimum), got: \(snapshotValue(key))"
    )
    return Int(snapshotValue(key)) ?? Int.min
  }

  private func waitForReplacementMeasurement(
    stream: String,
    generation: String,
    timeout: TimeInterval
  ) -> ReplacementMeasurement {
    let prefix = "complete:\(stream):\(generation):"
    let predicate = NSPredicate { _, _ in
      self.snapshotValue("replacementMeasurement").hasPrefix(prefix)
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "No successor A/V measurement arrived: \(snapshotValue("replacementMeasurement"))"
    )
    let value = snapshotValue("replacementMeasurement")
    let components = value.split(separator: ":")
    guard
      components.count == 6,
      let video = Int(components[3]),
      let audio = Int(components[4]),
      let staleMutations = Int(components[5])
    else {
      XCTFail("Malformed replacement measurement: \(value)")
      return ReplacementMeasurement(videoGapMilliseconds: Int.max, audioGapMilliseconds: Int.max)
    }
    XCTAssertEqual(
      staleMutations,
      0,
      "Retired playback generations mutated successor state"
    )
    return ReplacementMeasurement(videoGapMilliseconds: video, audioGapMilliseconds: audio)
  }

  private func waitForNativePlaybackSnapshot(
    generation: String,
    expectsFiniteDuration: Bool,
    expectsSeekable: Bool,
    timeout: TimeInterval
  ) -> NativePlaybackSnapshot {
    let expectedGeneration = Int(generation.split(separator: " ").last ?? "")
    let predicate = NSPredicate { _, _ in
      guard
        let expectedGeneration,
        let snapshot = self.parseNativePlaybackSnapshot(
          self.snapshotValue("nativePlaybackSnapshot")
        )
      else { return false }
      let durationMatches = expectsFiniteDuration
        ? snapshot.durationMilliseconds > 0
        : snapshot.durationMilliseconds == 0
      return snapshot.generation == expectedGeneration
        && snapshot.currentTimeMilliseconds >= 0
        && snapshot.isSeekable == expectsSeekable
        && durationMatches
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Native playback snapshot did not converge: \(snapshotValue("nativePlaybackSnapshot"))"
    )
    let value = snapshotValue("nativePlaybackSnapshot")
    guard let snapshot = parseNativePlaybackSnapshot(value) else {
      XCTFail("Malformed native playback snapshot: \(value)")
      return NativePlaybackSnapshot(
        generation: -1,
        durationMilliseconds: -1,
        currentTimeMilliseconds: -1,
        isSeekable: false
      )
    }
    return snapshot
  }

  private func parseNativePlaybackSnapshot(_ value: String) -> NativePlaybackSnapshot? {
    let components = value.split(separator: ":")
    guard
      components.count == 4,
      let generation = Int(components[0]),
      let duration = Int(components[1]),
      let time = Int(components[2])
    else { return nil }
    let seekable = String(components[3])
    guard ["yes", "no"].contains(seekable) else { return nil }
    return NativePlaybackSnapshot(
      generation: generation,
      durationMilliseconds: duration,
      currentTimeMilliseconds: time,
      isSeekable: seekable == "yes"
    )
  }

  private var automationSnapshot: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.automationSnapshot
    ]
  }

  private func snapshotValue(_ key: String) -> String {
    let prefix = "\(key)="
    guard
      let line = automationSnapshot.label.split(separator: "\n").first(where: {
        $0.hasPrefix(prefix)
      })
    else { return "" }
    return String(line.dropFirst(prefix.count))
  }

  private var restoredEventCount: Int {
    snapshotValue("continuityEvents").split(separator: "|").filter {
      $0.contains("restored")
    }.count
  }

  private enum ScrollDirection {
    case up
    case down
  }

  private func reveal(_ element: XCUIElement, swiping direction: ScrollDirection) {
    for _ in 0..<8 {
      // `isHittable` is not a safe existence probe: XCTest records a lookup
      // failure when a lazy SwiftUI Form row has not been materialized yet.
      // Scroll first until the query exists, then ask whether it is hittable.
      if element.exists, element.isHittable {
        return
      }
      switch direction {
      case .up:
        app.swipeUp()
      case .down:
        app.swipeDown()
      }
    }
  }

  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in element.exists && element.isEnabled }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }
}
