import XCTest

/// Relative-seek wraps `seek(by:)` and exercises the same backend as
/// absolute seek, but via discrete deltas rather than slider drags.
/// Coverage focuses on direction correctness, magnitude correctness, and
/// boundary behavior (seek before start, seek past end).
final class RelativeSeekUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var videoView: XCUIElement {
    app.otherElements[AccessibilityID.RelativeSeek.videoView]
  }

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.RelativeSeek.playPauseButton]
  }

  private var skipBack30: XCUIElement {
    app.buttons[AccessibilityID.RelativeSeek.skipBack30]
  }

  private var skipBack10: XCUIElement {
    app.buttons[AccessibilityID.RelativeSeek.skipBack10]
  }

  private var skipForward10: XCUIElement {
    app.buttons[AccessibilityID.RelativeSeek.skipForward10]
  }

  private var skipForward30: XCUIElement {
    app.buttons[AccessibilityID.RelativeSeek.skipForward30]
  }

  private var sameDirectionBurst: XCUIElement {
    app.buttons[AccessibilityID.RelativeSeek.sameDirectionBurst]
  }

  private var currentTimeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.SeekBar.currentTime]
  }

  private var durationLabel: XCUIElement {
    app.staticTexts[AccessibilityID.SeekBar.duration]
  }

  private func seconds(from label: String) -> Int? {
    let parts = label.split(separator: ":")
    guard
      parts.count == 2,
      let minutes = Int(parts[0]),
      let secs = Int(parts[1])
    else { return nil }
    return minutes * 60 + secs
  }

  /// Native seeks settle asynchronously. Poll the observable label instead of
  /// sampling one arbitrary second later, which can catch an intermediate
  /// demux timestamp even though the accepted target is correct.
  private func waitForCurrentTime(
    near expected: Int,
    tolerance: Int = 2,
    timeout: TimeInterval = 5
  ) -> Int? {
    let deadline = Date().addingTimeInterval(timeout)
    var latest: Int?
    repeat {
      latest = seconds(from: currentTimeLabel.label)
      if let latest, abs(latest - expected) <= tolerance {
        return latest
      }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return latest
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, all four skip buttons are hittable.
  /// Buttons being hittable is itself a regression guard — the previous
  /// version of this showcase had the SwiftUI Form-row tap-routing bug.
  func test_smoke_skipButtonsAreInteractive() {
    launch(route: .relativeSeek)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    XCTAssertTrue(skipBack30.isHittable, "−30s button not hittable")
    XCTAssertTrue(skipBack10.isHittable, "−10s button not hittable")
    XCTAssertTrue(skipForward10.isHittable, "+10s button not hittable")
    XCTAssertTrue(skipForward30.isHittable, "+30s button not hittable")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Forward skip advances currentTime by approximately the requested
  /// delta. Pause first so playback drift doesn't contaminate the
  /// observed delta.
  func test_deep_skipForwardAdvancesByDelta() {
    launch(route: .relativeSeek)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    Thread.sleep(forTimeInterval: 1)
    guard let before = seconds(from: currentTimeLabel.label) else {
      XCTFail("currentTime unparseable: '\(currentTimeLabel.label)'")
      return
    }

    skipForward10.tap()
    guard let after10 = waitForCurrentTime(near: before + 10) else {
      XCTFail("currentTime unparseable after +10s skip: '\(currentTimeLabel.label)'")
      return
    }

    let delta10 = after10 - before
    // Allow ±2s tolerance — libVLC seek-by jumps to the nearest keyframe
    // when fast-seeking, and our timeChanged event arrives async.
    XCTAssertGreaterThanOrEqual(
      delta10, 8,
      "+10s skip only advanced \(delta10)s (from \(before)s to \(after10)s)"
    )
    XCTAssertLessThanOrEqual(
      delta10, 12,
      "+10s skip overshot to \(delta10)s"
    )
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  /// Backward skip from the same starting position returns approximately
  /// the same delta in reverse. Combined with the forward test this
  /// proves direction correctness is symmetric.
  func test_deep_skipBackwardRewindsByDelta() {
    launch(route: .relativeSeek)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)

    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    // Skip forward 30 first to give us room to skip back.
    skipForward30.tap()
    guard let mid = waitForCurrentTime(near: 30) else {
      XCTFail("currentTime unparseable after seeding: '\(currentTimeLabel.label)'")
      return
    }
    XCTAssertGreaterThanOrEqual(mid, 25, "Couldn't skip forward 30s — only landed at \(mid)s")

    skipBack10.tap()
    guard let after = waitForCurrentTime(near: mid - 10) else {
      XCTFail("currentTime unparseable after −10s skip: '\(currentTimeLabel.label)'")
      return
    }

    let delta = mid - after
    XCTAssertGreaterThanOrEqual(delta, 8, "−10s skip only rewound \(delta)s")
    XCTAssertLessThanOrEqual(delta, 12, "−10s skip overshot to \(delta)s")
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  /// One synchronous UI action submits three same-direction commands while the
  /// first native seek still owns libVLC's watcher. The final clock proves the
  /// scheduler preserved the whole +30-second intent instead of replacing the
  /// queue with three identical +10-second snapshots.
  func test_stress_sameDirectionBurstPreservesNetDisplacement() {
    launch(route: .relativeSeek)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    waitForLabel(durationLabel, notEqual: "0:00", timeout: 5)
    playPauseButton.tap()
    waitForLabel(playPauseButton, equals: "Play", timeout: 3)

    guard let before = seconds(from: currentTimeLabel.label) else {
      XCTFail("currentTime unparseable: '\(currentTimeLabel.label)'")
      return
    }
    if !sameDirectionBurst.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(sameDirectionBurst.waitForExistence(timeout: 2))
    sameDirectionBurst.tap()

    guard let after = waitForCurrentTime(near: before + 30, tolerance: 4) else {
      XCTFail("currentTime unparseable after burst: '\(currentTimeLabel.label)'")
      return
    }
    let displacement = after - before
    XCTAssertGreaterThanOrEqual(
      displacement,
      26,
      "Three +10s commands only advanced \(displacement)s"
    )
    XCTAssertLessThanOrEqual(
      displacement,
      34,
      "Three +10s commands advanced an unexpected \(displacement)s"
    )
    if !videoView.isHittable {
      app.swipeDown()
    }
    assertRendersNonBlackFrame(videoView, timeout: 10)
    assertNoLibraryErrors()
  }

  /// Hammer all four buttons in alternating directions. The decoder
  /// cascade and buffer manager must stay coherent across rapid
  /// `seek(by:)` calls.
  func test_stress_rapidAlternatingSkips() {
    launch(route: .relativeSeek)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    for _ in 0..<4 {
      skipForward10.tap()
      skipBack10.tap()
      skipForward30.tap()
      skipBack30.tap()
    }

    Thread.sleep(forTimeInterval: 2)

    XCTAssertTrue(playPauseButton.exists, "App died during rapid alternating skips")
    XCTAssertTrue(playPauseButton.isHittable, "Player unresponsive after rapid skips")
    assertRendersNonBlackFrame(videoView, timeout: 10)

    assertNoLibraryErrors()
  }

  /// Skip backward repeatedly from the start — libVLC must clamp at 0
  /// rather than seeking to negative time.
  func test_stress_skipBackwardPastStart() {
    launch(route: .relativeSeek)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    for _ in 0..<5 {
      skipBack30.tap()
      Thread.sleep(forTimeInterval: 0.3)
    }

    Thread.sleep(forTimeInterval: 1)

    guard let observed = seconds(from: currentTimeLabel.label) else {
      XCTFail("currentTime unparseable: '\(currentTimeLabel.label)'")
      return
    }
    XCTAssertGreaterThanOrEqual(observed, 0, "currentTime went negative: \(observed)s")

    XCTAssertTrue(playPauseButton.exists, "App died on skip-past-start")

    assertNoLibraryErrors()
  }

  /// Skip forward repeatedly past the end of media — libVLC must
  /// either clamp at duration or transition to end-of-media without
  /// crashing.
  func test_stress_skipForwardPastEnd() {
    launch(route: .relativeSeek)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)

    for _ in 0..<5 {
      skipForward30.tap()
      Thread.sleep(forTimeInterval: 0.3)
    }

    Thread.sleep(forTimeInterval: 2)

    XCTAssertTrue(playPauseButton.exists, "App died on skip-past-end")

    assertNoLibraryErrors()
  }

  func test_stress_presentDismissCycles() {
    launch(route: .relativeSeek)
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
}
