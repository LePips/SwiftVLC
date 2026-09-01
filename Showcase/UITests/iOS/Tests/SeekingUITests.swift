import XCTest

/// Seek is the hottest mid-playback state manipulation — it touches the
/// demuxer, decoder cascade, buffer manager, and audio output simultaneously.
/// This suite covers: correctness (seek lands at the target within
/// tolerance), lifecycle edge cases (seek before `.playing`, seek past end),
/// and stress (direct seek bursts, seek while paused, re-mount churn).
final class SeekingUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var videoView: XCUIElement {
    app.otherElements[AccessibilityID.Seeking.videoView]
  }

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.Seeking.playPauseButton]
  }

  private var slider: XCUIElement {
    app.sliders[AccessibilityID.SeekBar.slider]
  }

  private var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.SeekBar.currentTime]
  }

  private var durationLabel: XCUIElement {
    app.staticTexts[AccessibilityID.SeekBar.duration]
  }

  private var seekBurstProgress: XCUIElement {
    app.staticTexts[AccessibilityID.Seeking.seekBurstProgress]
  }

  private var seekBurstResult: XCUIElement {
    app.staticTexts[AccessibilityID.Seeking.seekBurstResult]
  }

  // MARK: - Helpers

  /// Parses "M:SS" (e.g. "1:05") into total seconds. Returns nil for
  /// unexpected formats (helpful for asserting-before-parsing in deep tests).
  private func seconds(from label: String) -> Int? {
    let parts = label.split(separator: ":")
    guard
      parts.count == 2,
      let minutes = Int(parts[0]),
      let secs = Int(parts[1])
    else { return nil }
    return minutes * 60 + secs
  }

  // MARK: - Smoke

  /// The page loads, reaches `playing`, and both the slider and the
  /// duration label (non-zero) are visible.
  func test_smoke_sliderAppearsAndPlayerPlays() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    XCTAssertTrue(slider.exists, "Seek slider never appeared")
    XCTAssertTrue(durationLabel.exists, "Duration label never appeared")

    // Once duration is known it should not be "0:00".
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Seeks to low / mid / high positions and verifies the observed
  /// `currentTime` is monotonically increasing across them.
  ///
  /// XCUITest's `adjust(toNormalizedSliderPosition:)` is not pixel-exact
  /// on continuous SwiftUI sliders (observed drift up to ~15 % of slider
  /// width), so an absolute-target-within-N-seconds assertion would be a
  /// test of the automation layer, not the library. A monotonic-ordering
  /// assertion tests what actually matters: seeking forward produces a
  /// forward jump, and the magnitudes of the jumps are proportional to
  /// the slider movement.
  func test_deep_seekProducesProportionalPositionChange() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    // Pause before seeking so playback doesn't drift the observed times
    // between the seek and the sample.
    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    func seekAndSample(_ target: CGFloat) -> Int {
      slider.adjust(toNormalizedSliderPosition: target)
      Thread.sleep(forTimeInterval: 1)
      return seconds(from: currentTimeLabel.label) ?? -1
    }

    let low = seekAndSample(0.1)
    let mid = seekAndSample(0.5)
    let high = seekAndSample(0.9)

    XCTAssertGreaterThan(mid, low, "Seek 0.5 (got \(mid)s) did not advance past 0.1 (got \(low)s)")
    XCTAssertGreaterThan(high, mid, "Seek 0.9 (got \(high)s) did not advance past 0.5 (got \(mid)s)")

    // Sanity: total span must be more than half the fixture length if
    // the seeks actually moved the player across its timeline.
    guard let total = seconds(from: durationLabel.label) else {
      XCTFail("Duration unparseable: '\(durationLabel.label)'")
      return
    }
    XCTAssertGreaterThan(
      high - low, total / 2,
      "Seeks 0.1→0.9 should span >half of duration (\(total)s); got only \(high - low)s"
    )
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  /// Seeking while paused must still advance the position label, and
  /// playback must stay paused (not silently resume).
  func test_deep_seekWhilePausedUpdatesPositionWithoutResuming() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    slider.adjust(toNormalizedSliderPosition: 0.5)
    Thread.sleep(forTimeInterval: 2)

    guard let observed = seconds(from: currentTimeLabel.label) else {
      XCTFail("Current time unparseable: '\(currentTimeLabel.label)'")
      return
    }
    XCTAssertGreaterThan(
      observed, 10,
      "Seek to 50 % while paused didn't update currentTime — got \(observed)s"
    )

    // Must still be paused.
    XCTAssertEqual(
      playPauseButton.label, "Play",
      "Player resumed unexpectedly after seek-while-paused"
    )
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// Exercises a reproducible sequence of real slider gestures without
  /// approaching EOF. XCUITest takes roughly two seconds per adjustment, so
  /// this is deliberately a gesture/control-surface test; the direct in-app
  /// tests below provide the actual 20–100 ms command bursts.
  func test_stress_seededGestureSeeksStayResponsive() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    // Keep the fixture safely away from its terminal lifecycle. Near-EOF
    // behavior is covered independently by `test_stress_seekNearEnd`.
    let targets: [CGFloat] = [
      0.72, 0.10, 0.75, 0.05, 0.50, 0.68,
      0.25, 0.74, 0.15, 0.65, 0.35, 0.70
    ]

    for target in targets {
      slider.adjust(toNormalizedSliderPosition: target)
      XCTAssertEqual(
        playPauseButton.label,
        "Pause",
        "Gesture seek to \(target) unexpectedly left active playback"
      )
    }

    Thread.sleep(forTimeInterval: 3)

    XCTAssertTrue(playPauseButton.exists, "App crashed during rapid seeks")
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid seeks")
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  /// Coalesces 12 fast strict seeks at 20 ms, then proves a final precise
  /// seek restores advancing decoded and displayed video.
  func test_stress_directSeekBurst20Milliseconds() throws {
    try runDirectSeekBurst(cadenceMilliseconds: 20)
  }

  /// Coalesces 12 fast strict seeks at 50 ms, then proves a final precise
  /// seek restores advancing decoded and displayed video.
  func test_stress_directSeekBurst50Milliseconds() throws {
    try runDirectSeekBurst(cadenceMilliseconds: 50)
  }

  /// Coalesces 12 fast strict seeks at 100 ms, then proves a final precise
  /// seek restores advancing decoded and displayed video.
  func test_stress_directSeekBurst100Milliseconds() throws {
    try runDirectSeekBurst(cadenceMilliseconds: 100)
  }

  /// Seek the slider before the player has reached `.playing`. This
  /// exercises the race between `.task { try? player.play(url:) }` and
  /// the user dragging the scrubber — similar class to the immediate
  /// tap-play crash on PlayerState. libVLC's seek without a ready
  /// demuxer has historically corrupted state here.
  func test_stress_seekBeforePlaybackStarts() {
    launch(route: .seeking)

    // Don't wait for Pause. Adjust as soon as the slider exists.
    XCTAssertTrue(slider.waitForExistence(timeout: 3))
    slider.adjust(toNormalizedSliderPosition: 0.5)

    // Player should still be able to reach playing afterwards.
    waitForLabel(playPauseButton, equals: "Pause", timeout: 15)

    assertNoLibraryErrors()
  }

  /// Seek to 99 % and past the logical end. Player must not crash or
  /// hang; state should settle (either at `.playing` at end, or
  /// transition to end-of-media handling).
  func test_stress_seekNearEnd() {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    slider.adjust(toNormalizedSliderPosition: 0.99)
    Thread.sleep(forTimeInterval: 5)

    XCTAssertTrue(playPauseButton.exists, "App died after seek near end")

    assertNoLibraryErrors()
  }

  /// Relaunch the app mid-seek-heavy-session. Memory should plateau.
  func test_stress_presentDismissCycles() {
    launch(route: .seeking)
    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))

    measure(metrics: [XCTMemoryMetric()]) {
      for _ in 0..<3 {
        app.terminate()
        app.launch()
        _ = playPauseButton.waitForExistence(timeout: 5)
      }
    }

    assertNoLibraryErrors()
  }

  // MARK: - Direct burst helper

  /// Runs one cadence in a fresh app process (each XCTest method gets its own
  /// setUp/tearDown), decodes the app-side typed evidence, and then applies an
  /// independent screen-pixel oracle.
  private func runDirectSeekBurst(cadenceMilliseconds: Int) throws {
    launch(route: .seeking)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    let runButton = app.buttons[
      AccessibilityID.Seeking.seekBurstButton(
        cadenceMilliseconds: cadenceMilliseconds
      )
    ]
    reveal(runButton, direction: .up)
    let readyPredicate = NSPredicate { _, _ in runButton.exists && runButton.isEnabled }
    let readyExpectation = expectation(for: readyPredicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [readyExpectation], timeout: 5),
      .completed,
      "Seek burst button was not ready"
    )
    runButton.tap()

    waitForSeekBurstResult(timeout: 15)
    let evidence = try decodeSeekBurstEvidence(seekBurstResult.label)
    attachSeekBurstEvidence(evidence)

    XCTAssertEqual(evidence.schemaVersion, 1)
    XCTAssertEqual(evidence.cadenceMilliseconds, cadenceMilliseconds)
    XCTAssertEqual(
      evidence.outcome,
      "pass",
      evidence.failure ?? "Seek burst reported failure without a reason"
    )
    XCTAssertNil(evidence.failure)

    let expectedFastTargets = [
      0.72, 0.10, 0.75, 0.05, 0.50, 0.68,
      0.25, 0.74, 0.15, 0.65, 0.35, 0.70
    ]
    XCTAssertEqual(evidence.targets.count, 13)
    XCTAssertEqual(evidence.commands.count, 13)
    XCTAssertEqual(evidence.commands.map(\.id), Array(0..<13))

    for (index, command) in evidence.commands.prefix(12).enumerated() {
      XCTAssertTrue(command.fast, "Command \(index) was not fast")
      XCTAssertEqual(command.target, expectedFastTargets[index], accuracy: 0.000_1)
      XCTAssertNil(command.error, "Command \(index) failed: \(command.error ?? "unknown")")
      XCTAssertEqual(
        command.scheduledOffsetMilliseconds,
        Int64(index * cadenceMilliseconds)
      )
      XCTAssertGreaterThanOrEqual(
        command.actualOffsetMilliseconds,
        command.scheduledOffsetMilliseconds - 5,
        "Command \(index) fired before its absolute deadline"
      )
      XCTAssertLessThanOrEqual(
        command.actualOffsetMilliseconds,
        command.scheduledOffsetMilliseconds + 1000,
        "Command \(index) missed its cadence by more than one second"
      )
    }

    let finalCommand = try XCTUnwrap(evidence.commands.last)
    XCTAssertFalse(finalCommand.fast)
    XCTAssertEqual(finalCommand.target, 0.70, accuracy: 0.000_1)
    XCTAssertNil(finalCommand.error)
    XCTAssertEqual(
      finalCommand.scheduledOffsetMilliseconds,
      Int64(11 * cadenceMilliseconds)
    )

    let expectedFastSpan = Int64(11 * cadenceMilliseconds)
    XCTAssertGreaterThanOrEqual(
      evidence.fastDispatchSpanMilliseconds,
      expectedFastSpan - 5,
      "The app did not deliver the requested cadence"
    )
    XCTAssertLessThanOrEqual(
      evidence.fastDispatchSpanMilliseconds,
      expectedFastSpan + 1500,
      "The fast burst stalled"
    )
    XCTAssertLessThan(
      evidence.commands.map(\.callDurationMilliseconds).max() ?? .max,
      500,
      "A synchronous seek dispatch blocked the main actor"
    )

    let recoveryMilliseconds = try XCTUnwrap(evidence.recoveryMilliseconds)
    XCTAssertLessThanOrEqual(recoveryMilliseconds, 10000)
    XCTAssertEqual(evidence.finalState, "playing")
    XCTAssertTrue(evidence.finalIsPlaybackRequestedActive)
    XCTAssertTrue(evidence.finalIsSeekable)
    XCTAssertFalse(evidence.finalDidReachEnd)
    XCTAssertGreaterThan(evidence.finalActiveVideoOutputs, 0)
    XCTAssertTrue(evidence.finalHasVideoOutput)
    XCTAssertEqual(evidence.finalPosition, 0.70, accuracy: 0.08)
    XCTAssertGreaterThanOrEqual(
      evidence.finalTimeMilliseconds,
      evidence.expectedTargetTimeMilliseconds + 250
    )
    XCTAssertLessThanOrEqual(
      evidence.finalTimeMilliseconds,
      evidence.expectedTargetTimeMilliseconds + 5000
    )
    XCTAssertGreaterThan(evidence.decodedVideoDelta, 0)
    XCTAssertGreaterThan(evidence.displayedPicturesDelta, 0)

    // The result section is below the fold; return to the real video surface
    // before sampling its screen pixels.
    for _ in 0..<10 {
      app.swipeDown()
    }
    XCTAssertTrue(videoView.exists, "Video surface disappeared after seek burst")
    XCTAssertTrue(
      app.frame.intersects(videoView.frame),
      "Video surface could not be brought back on screen"
    )
    waitForLabel(playPauseButton, equals: "Pause", timeout: 3)
    XCTAssertTrue(playPauseButton.isHittable, "Playback controls wedged after seek burst")
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  private enum ScrollDirection {
    case up
    case down
  }

  private func reveal(_ element: XCUIElement, direction: ScrollDirection) {
    for _ in 0..<10 where !element.isHittable {
      switch direction {
      case .up:
        app.swipeUp()
      case .down:
        app.swipeDown()
      }
    }
    XCTAssertTrue(element.isHittable, "Could not reveal \(element)")
  }

  private func waitForSeekBurstResult(timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in
      self.seekBurstResult.exists
        && (self.seekBurstResult.label.hasPrefix("pass:")
          || self.seekBurstResult.label.hasPrefix("fail:"))
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Seek burst did not finish; result='\(seekBurstResult.label)', "
        + "progress='\(seekBurstProgress.label)'"
    )
  }

  private func decodeSeekBurstEvidence(_ label: String) throws -> SeekBurstEvidence {
    let prefix: String
    if label.hasPrefix("pass:") {
      prefix = "pass:"
    } else if label.hasPrefix("fail:") {
      prefix = "fail:"
    } else {
      XCTFail("Seek burst result had no outcome prefix: \(label)")
      throw SeekBurstDecodingError.missingOutcomePrefix
    }
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try JSONDecoder().decode(SeekBurstEvidence.self, from: data)
  }

  private func attachSeekBurstEvidence(_ evidence: SeekBurstEvidence) {
    guard let data = try? JSONEncoder().encode(evidence) else {
      XCTFail("Could not re-encode typed seek burst evidence")
      return
    }
    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
    attachment.name = "seek-burst-\(evidence.cadenceMilliseconds)ms.json"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private enum SeekBurstDecodingError: Error {
    case missingOutcomePrefix
  }
}
