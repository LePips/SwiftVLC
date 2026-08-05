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
  }

  private func loadInitialVODAndStartPictureInPicture() {
    app.buttons[AccessibilityID.PiPContinuityValidation.loadVODButton].tap()
    waitForLabel(state, equals: "playing", timeout: 20)
    // iOS 27 lazily materializes Form rows below the initial phone viewport.
    reveal(playbackSnapshot, swiping: .up)
    waitForLabel(playbackSnapshot, equals: "finite:seekable:interactive", timeout: 15)
    reveal(nativePlaybackSnapshot, swiping: .up)
    _ = waitForNativePlaybackSnapshot(
      generation: generation.label,
      expectsFiniteDuration: true,
      expectsSeekable: true,
      timeout: 15
    )
    _ = waitForIntegerLabel(displayedPictures, greaterThan: 0, timeout: 10)
    _ = waitForIntegerLabel(playedAudioBuffers, greaterThan: 0, timeout: 10)
    waitForLabel(possible, equals: "yes", timeout: 15)

    let start = app.buttons["Start PiP"]
    reveal(start, swiping: .down)
    waitUntilEnabled(start, timeout: 20)
    start.tap()
    waitForLabel(active, equals: "yes", timeout: 10)
    waitForOccurrence("didStart", count: 1, in: lifecycleEvents, timeout: 10)
  }

  private func transition(
    using buttonIdentifier: String,
    expectedStream: String,
    expectedSnapshot: String,
    expectedRestoredCount: Int
  ) -> ReplacementMeasurement {
    let previousGeneration = generation.label
    let button = app.buttons[buttonIdentifier]
    reveal(button, swiping: .up)
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()

    waitForLabelChange(generation, from: previousGeneration, timeout: 5)
    waitForLabel(playbackSnapshot, equals: expectedSnapshot, timeout: 15)
    waitForOccurrence(
      "restored",
      count: expectedRestoredCount,
      in: continuityEvents,
      timeout: 15
    )
    _ = waitForNativePlaybackSnapshot(
      generation: generation.label,
      expectsFiniteDuration: expectedSnapshot.hasPrefix("finite:"),
      expectsSeekable: expectedSnapshot.contains(":seekable:"),
      timeout: 15
    )
    let measurement = waitForReplacementMeasurement(
      stream: expectedStream,
      generation: generation.label,
      timeout: 15
    )
    waitForLabel(active, equals: "yes", timeout: 5)
    waitForLabel(staleSuccessorMutations, equals: "0", timeout: 5)
    waitForLabel(state, equals: "playing", timeout: 10)
    _ = waitForIntegerLabel(displayedPictures, greaterThan: 0, timeout: 5)
    _ = waitForIntegerLabel(playedAudioBuffers, greaterThan: 0, timeout: 5)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(expectedStream) replacement PiP motion failed: \(failure)")
    }
    app.activate()
    waitForLabel(active, equals: "yes", timeout: 10)
    waitForLabel(state, equals: "playing", timeout: 10)
    return measurement
  }

  private func stopPictureInPictureAndValidateLifecycle(expectedReplacementCount: Int) {
    XCTAssertEqual(restoredEventCount, expectedReplacementCount)
    let stop = app.buttons["Stop PiP"]
    reveal(stop, swiping: .down)
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    stop.tap()
    waitForLabel(active, equals: "no", timeout: 10)
    waitForOccurrence("didStop:programmatic", count: 1, in: lifecycleEvents, timeout: 10)
    XCTAssertTrue(
      lifecycleEvents.label.hasPrefix(
        "willStart|didStart|willStop:programmatic|didStop:programmatic"
      ),
      "PiP lifecycle was not ordered: \(lifecycleEvents.label)"
    )
    waitForLabel(staleSuccessorMutations, equals: "0", timeout: 5)
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
      element.label.split(separator: "|").filter { $0.contains(value) }.count >= count
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected \(count) \(value) event(s), got: \(element.label)"
    )
  }

  private func waitForReplacementMeasurement(
    stream: String,
    generation: String,
    timeout: TimeInterval
  ) -> ReplacementMeasurement {
    let prefix = "complete:\(stream):\(generation):"
    let predicate = NSPredicate { _, _ in
      self.replacementMeasurement.label.hasPrefix(prefix)
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "No successor A/V measurement arrived: \(replacementMeasurement.label)"
    )
    let components = replacementMeasurement.label.split(separator: ":")
    guard
      components.count == 5,
      let video = Int(components[3]),
      let audio = Int(components[4])
    else {
      XCTFail("Malformed replacement measurement: \(replacementMeasurement.label)")
      return ReplacementMeasurement(videoGapMilliseconds: Int.max, audioGapMilliseconds: Int.max)
    }
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
        let snapshot = self.parseNativePlaybackSnapshot(self.nativePlaybackSnapshot.label)
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
      "Native playback snapshot did not converge: \(nativePlaybackSnapshot.label)"
    )
    guard let snapshot = parseNativePlaybackSnapshot(nativePlaybackSnapshot.label) else {
      XCTFail("Malformed native playback snapshot: \(nativePlaybackSnapshot.label)")
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

  private var state: XCUIElement {
    app.descendants(matching: .any)[AccessibilityID.PiPContinuityValidation.stateLabel]
  }

  private var generation: XCUIElement {
    app.descendants(matching: .any)[AccessibilityID.PiPContinuityValidation.generationLabel]
  }

  private var displayedPictures: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.displayedPicturesLabel
    ]
  }

  private var playedAudioBuffers: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.playedAudioBuffersLabel
    ]
  }

  private var possible: XCUIElement {
    app.descendants(matching: .any)[AccessibilityID.PiPContinuityValidation.possibleLabel]
  }

  private var active: XCUIElement {
    app.descendants(matching: .any)[AccessibilityID.PiPContinuityValidation.activeLabel]
  }

  private var playbackSnapshot: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.playbackSnapshotLabel
    ]
  }

  private var continuityEvents: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.continuityEventsLabel
    ]
  }

  private var nativePlaybackSnapshot: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.nativePlaybackSnapshotLabel
    ]
  }

  private var lifecycleEvents: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.lifecycleEventsLabel
    ]
  }

  private var replacementMeasurement: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.replacementMeasurementLabel
    ]
  }

  private var staleSuccessorMutations: XCUIElement {
    app.descendants(matching: .any)[
      AccessibilityID.PiPContinuityValidation.staleSuccessorMutationsLabel
    ]
  }

  private var restoredEventCount: Int {
    continuityEvents.label.split(separator: "|").filter { $0.contains("restored") }.count
  }

  private enum ScrollDirection {
    case up
    case down
  }

  private func reveal(_ element: XCUIElement, swiping direction: ScrollDirection) {
    for _ in 0..<8 where !element.isHittable {
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
