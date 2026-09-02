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
    revealMeasurement(state, swiping: .up)
    waitForAccessibilityValue(state, equals: "playing", timeout: 20)
    revealMeasurement(playbackSnapshot, swiping: .up)
    waitForAccessibilityValue(
      playbackSnapshot,
      equals: "finite:seekable:interactive",
      timeout: 15
    )
    revealMeasurement(generation, swiping: .down)
    let initialGeneration = accessibilityValue(of: generation)
    revealMeasurement(nativePlaybackSnapshot, swiping: .up)
    _ = waitForNativePlaybackSnapshot(
      generation: initialGeneration,
      expectsFiniteDuration: true,
      expectsSeekable: true,
      timeout: 15
    )
    revealMeasurement(displayedPictures, swiping: .down)
    _ = waitForIntegerAccessibilityValue(displayedPictures, greaterThan: 0, timeout: 10)
    revealMeasurement(playedAudioBuffers, swiping: .up)
    _ = waitForIntegerAccessibilityValue(playedAudioBuffers, greaterThan: 0, timeout: 10)
    revealMeasurement(possible, swiping: .down)
    waitForAccessibilityValue(possible, equals: "yes", timeout: 15)

    let start = app.buttons["Start PiP"]
    reveal(start, swiping: .up)
    waitUntilEnabled(start, timeout: 20)
    start.tap()
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)
    revealMeasurement(lifecycleEvents, swiping: .up)
    waitForOccurrence("didStart", count: 1, in: lifecycleEvents, timeout: 10)
  }

  private func transition(
    using buttonIdentifier: String,
    expectedStream: String,
    expectedSnapshot: String,
    expectedRestoredCount: Int
  ) -> ReplacementMeasurement {
    revealMeasurement(generation, swiping: .down)
    let previousGeneration = accessibilityValue(of: generation)
    let button = app.buttons[buttonIdentifier]
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()

    revealMeasurement(generation, swiping: .up)
    waitForValueChange(generation, from: previousGeneration, timeout: 5)
    revealMeasurement(playbackSnapshot, swiping: .up)
    waitForAccessibilityValue(playbackSnapshot, equals: expectedSnapshot, timeout: 15)
    revealMeasurement(continuityEvents, swiping: .up)
    waitForOccurrence(
      "restored",
      count: expectedRestoredCount,
      in: continuityEvents,
      timeout: 15
    )
    revealMeasurement(generation, swiping: .down)
    let successorGeneration = accessibilityValue(of: generation)
    revealMeasurement(nativePlaybackSnapshot, swiping: .up)
    _ = waitForNativePlaybackSnapshot(
      generation: successorGeneration,
      expectsFiniteDuration: expectedSnapshot.hasPrefix("finite:"),
      expectsSeekable: expectedSnapshot.contains(":seekable:"),
      timeout: 15
    )
    revealMeasurement(replacementMeasurement, swiping: .up)
    let measurement = waitForReplacementMeasurement(
      stream: expectedStream,
      generation: successorGeneration,
      timeout: 15
    )
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 5)
    revealMeasurement(staleSuccessorMutations, swiping: .up)
    waitForAccessibilityValue(staleSuccessorMutations, equals: "0", timeout: 5)
    revealMeasurement(state, swiping: .down)
    waitForAccessibilityValue(state, equals: "playing", timeout: 10)
    revealMeasurement(displayedPictures, swiping: .up)
    _ = waitForIntegerAccessibilityValue(displayedPictures, greaterThan: 0, timeout: 5)
    revealMeasurement(playedAudioBuffers, swiping: .up)
    _ = waitForIntegerAccessibilityValue(playedAudioBuffers, greaterThan: 0, timeout: 5)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("\(expectedStream) replacement PiP motion failed: \(failure)")
    }
    app.activate()
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "yes", timeout: 10)
    revealMeasurement(state, swiping: .up)
    waitForAccessibilityValue(state, equals: "playing", timeout: 10)
    return measurement
  }

  private func stopPictureInPictureAndValidateLifecycle(expectedReplacementCount: Int) {
    revealMeasurement(continuityEvents, swiping: .up)
    XCTAssertEqual(restoredEventCount, expectedReplacementCount)
    let stop = app.buttons["Stop PiP"]
    reveal(stop, swiping: .down)
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    stop.tap()
    revealMeasurement(active, swiping: .down)
    waitForAccessibilityValue(active, equals: "no", timeout: 10)
    revealMeasurement(lifecycleEvents, swiping: .up)
    waitForOccurrence("didStop:programmatic", count: 1, in: lifecycleEvents, timeout: 10)
    XCTAssertTrue(
      accessibilityValue(of: lifecycleEvents).hasPrefix(
        "willStart|didStart|willStop:programmatic|didStop:programmatic"
      ),
      "PiP lifecycle was not ordered: \(accessibilityValue(of: lifecycleEvents))"
    )
    revealMeasurement(staleSuccessorMutations, swiping: .up)
    waitForAccessibilityValue(staleSuccessorMutations, equals: "0", timeout: 5)
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
        .filter { $0.contains(value) }.count >= count
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Expected \(count) \(value) event(s), got: \(accessibilityValue(of: element))"
    )
  }

  private func waitForReplacementMeasurement(
    stream: String,
    generation: String,
    timeout: TimeInterval
  ) -> ReplacementMeasurement {
    let prefix = "complete:\(stream):\(generation):"
    let predicate = NSPredicate { _, _ in
      self.accessibilityValue(of: self.replacementMeasurement).hasPrefix(prefix)
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "No successor A/V measurement arrived: \(accessibilityValue(of: replacementMeasurement))"
    )
    let value = accessibilityValue(of: replacementMeasurement)
    let components = value.split(separator: ":")
    guard
      components.count == 5,
      let video = Int(components[3]),
      let audio = Int(components[4])
    else {
      XCTFail("Malformed replacement measurement: \(value)")
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
        let snapshot = self.parseNativePlaybackSnapshot(
          self.accessibilityValue(of: self.nativePlaybackSnapshot)
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
      "Native playback snapshot did not converge: "
        + "\(accessibilityValue(of: nativePlaybackSnapshot))"
    )
    let value = accessibilityValue(of: nativePlaybackSnapshot)
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
    accessibilityValue(of: continuityEvents)
      .split(separator: "|")
      .filter { $0.contains("restored") }.count
  }

  private func reveal(_ element: XCUIElement, swiping direction: ShowcaseScrollDirection) {
    for _ in 0..<8 where !element.isHittable {
      switch direction {
      case .up:
        app.swipeUp()
      case .down:
        app.swipeDown()
      }
    }
    if !element.isHittable {
      for _ in 0..<20 where !element.isHittable {
        direction.opposite.perform(in: app)
      }
    }
    XCTAssertTrue(element.isHittable, "Could not reveal \(element)")
  }

  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in element.exists && element.isEnabled }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }
}
