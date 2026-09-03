import XCTest

@MainActor
private enum QualificationLocalNetworkPermissionContract {
  static let usageDescription =
    "Connects to test streams and discovers media receivers on your local network."
  static let springBoardBundleIdentifier = "com.apple.springboard"
  static let affirmativeButtonLabel = "Allow"
  static let initialAppearanceTimeout: TimeInterval = 10
  static let repeatedAppearanceTimeout: TimeInterval = 0.5
  static let controlReadinessTimeout: TimeInterval = 5
  static var completedInitialObservation = false

  static func grantButton(in alert: XCUIElement) -> XCUIElement? {
    guard alert.elementType == .alert else { return nil }

    let purpose = alert.staticTexts
      .matching(
        NSPredicate(
          format: "label == %@",
          usageDescription
        )
      )
      .firstMatch
    guard purpose.exists else { return nil }

    let grant = alert.buttons[affirmativeButtonLabel]
    guard
      grant.exists,
      grant.label == affirmativeButtonLabel,
      grant.isHittable
    else {
      return nil
    }
    return grant
  }
}

extension ShowcaseIOSTestCase {
  /// Grants only the qualification app's exact local-network prompt. The
  /// qualification device must expose the explicitly recognized affirmative
  /// action; an unfamiliar locale or prompt is deliberately left unhandled.
  func installLocalNetworkPermissionInterruptionMonitor() {
    addUIInterruptionMonitor(
      withDescription: "Qualification local-network permission"
    ) { alert in
      guard
        let grant = QualificationLocalNetworkPermissionContract.grantButton(
          in: alert
        )
      else {
        return false
      }
      grant.tap()
      return true
    }
  }

  /// Handles a prompt without sending an arbitrary interaction to the
  /// candidate. If SpringBoard presents any other alert—or presents the exact
  /// prompt with an unknown affirmative action—the qualification attempt fails
  /// closed instead of guessing which button grants access. The first launch
  /// receives a longer bounded appearance window; later launches still probe
  /// briefly without multiplying that cost through every stress-test cycle.
  func handleQualificationLocalNetworkPermissionIfPresent() {
    guard ProcessInfo.processInfo.environment[Self.deviceLogPrefixEnvironment] != nil else {
      return
    }

    let contract = QualificationLocalNetworkPermissionContract.self
    let springBoard = XCUIApplication(
      bundleIdentifier: contract.springBoardBundleIdentifier
    )
    let alert = springBoard.alerts.firstMatch
    let appearanceTimeout = contract.completedInitialObservation
      ? contract.repeatedAppearanceTimeout
      : contract.initialAppearanceTimeout
    contract.completedInitialObservation = true
    let appearanceDeadline = ProcessInfo.processInfo.systemUptime + appearanceTimeout
    while !alert.exists && ProcessInfo.processInfo.systemUptime < appearanceDeadline {
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    guard alert.exists else { return }

    // SpringBoard can publish the alert container before its text/button
    // descendants finish animating into a hittable state. Poll the exact
    // contract rather than misclassifying that transient snapshot.
    let readinessDeadline =
      ProcessInfo.processInfo.systemUptime + contract.controlReadinessTimeout
    while alert.exists && ProcessInfo.processInfo.systemUptime < readinessDeadline {
      if let grant = contract.grantButton(in: alert) {
        grant.tap()
        XCTAssertFalse(
          alert.waitForExistence(timeout: contract.controlReadinessTimeout),
          "The Local Network permission prompt remained visible after granting access"
        )
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    guard alert.exists else { return }
    let labels = alert.buttons.allElementsBoundByIndex.map(\.label)
    let text = alert.staticTexts.allElementsBoundByIndex.map(\.label)
    XCTFail(
      "Refusing to interact with an unrecognized or unready SpringBoard alert. "
        + "Expected the exact Local Network purpose and affirmative action "
        + "\(contract.affirmativeButtonLabel.debugDescription); "
        + "observed text: \(text); observed buttons: \(labels)"
    )
  }

  /// Direct launch path for device cases that must replace launch arguments
  /// between iterations and therefore cannot use `launch(route:)`.
  func launchDirectlyHandlingQualificationPermissions() {
    app.launch()
    handleQualificationLocalNetworkPermissionIfPresent()
    observeQualificationCandidateRuntimeBindingIfRequired()
  }
}
