import XCTest

/// PiP in the iOS simulator typically reports `isPossible = false` (no
/// real hardware audio session), so the actionable UX test is the
/// button being correctly disabled. Previously flagged: the Start/Stop
/// PiP button was enabled even when PiP wasn't possible, confusing
/// users who tapped it to no effect.
final class PiPUITests: ShowcaseIOSTestCase {
  // Inherits `@MainActor` from `ShowcaseIOSTestCase`.

  private var playPauseButton: XCUIElement {
    app.buttons[AccessibilityID.PiP.playPauseButton]
  }

  private var possibleLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PiP.possibleLabel]
  }

  private var activeLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PiP.activeLabel]
  }

  private var toggleButton: XCUIElement {
    app.buttons[AccessibilityID.PiP.toggleButton]
  }

  private var preparingLabel: XCUIElement {
    app.staticTexts[AccessibilityID.PiP.preparingLabel]
  }

  /// Scroll the Form until PiP section is visible.
  private func scrollToPiPSection() {
    for _ in 0..<6 where !possibleLabel.exists {
      app.swipeUp()
      Thread.sleep(forTimeInterval: 0.3)
    }
  }

  private func assertEnabledPiPToggle() {
    XCTAssertTrue(
      toggleButton.waitForExistence(timeout: 3),
      "Toggle PiP button is missing while isPossible is 'yes'"
    )
    XCTAssertTrue(
      toggleButton.isEnabled,
      "Toggle PiP button is disabled while isPossible is 'yes'"
    )
  }

  private func assertUnavailablePiPToggle() {
    // SwiftUI Form may strip disabled Buttons from the accessibility tree
    // entirely. Hidden and present-but-disabled both prevent a no-op tap.
    if toggleButton.exists {
      XCTAssertFalse(
        toggleButton.isEnabled,
        "Toggle PiP button is enabled while isPossible is 'no'"
      )
    }
  }

  // MARK: - Smoke

  /// Page loads, reaches playing, and the PiP controller becomes
  /// available (the "Preparing…" placeholder is replaced by the
  /// Possible / Active rows).
  func test_smoke_pipControllerBecomesAvailable() {
    launch(route: .pip)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToPiPSection()

    XCTAssertTrue(
      possibleLabel.waitForExistence(timeout: 10),
      "PiP controller never became available — 'Preparing…' still visible"
    )
    XCTAssertTrue(activeLabel.exists, "Active-status row should be visible alongside Possible row")

    assertNoLibraryErrors()
  }

  // MARK: - Deep

  /// Critical UX invariant: the toggle follows PiP capability. A real device
  /// normally exercises the enabled path, while Simulator normally exercises
  /// the disabled-or-hidden path.
  func test_deep_toggleButtonAvailabilityMatchesPiPPossibility() {
    launch(route: .pip)

    waitForLabel(playPauseButton, equals: "Pause", timeout: 10)
    scrollToPiPSection()

    XCTAssertTrue(possibleLabel.waitForExistence(timeout: 10))
    #if targetEnvironment(simulator)
    // Simulator normally remains incapable, but give an asynchronously
    // converging controller a bounded chance to publish `yes` before accepting
    // a stable disabled state.
    let convergenceDeadline = ProcessInfo.processInfo.systemUptime + 3
    while
      possibleLabel.label == "no",
      ProcessInfo.processInfo.systemUptime < convergenceDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    switch possibleLabel.label {
    case "yes": assertEnabledPiPToggle()
    case "no": assertUnavailablePiPToggle()
    default: XCTFail("Unexpected PiP possibility value: \(possibleLabel.label)")
    }
    #else
    // Physical qualification must exercise the enabled path. Accepting the
    // controller's transient initial `no` would let this test pass without
    // proving the capability/button invariant users rely on.
    waitForLabel(possibleLabel, equals: "yes", timeout: 30)
    assertEnabledPiPToggle()
    #endif

    assertNoLibraryErrors()
  }

  // MARK: - Stress

  func test_stress_presentDismissCycles() {
    launch(route: .pip)
    XCTAssertTrue(playPauseButton.waitForExistence(timeout: 5))

    measure(metrics: [XCTMemoryMetric()]) {
      for _ in 0..<3 {
        app.terminate()
        launchDirectlyHandlingQualificationPermissions()
        _ = playPauseButton.waitForExistence(timeout: 5)
      }
    }

    assertNoLibraryErrors()
  }
}
