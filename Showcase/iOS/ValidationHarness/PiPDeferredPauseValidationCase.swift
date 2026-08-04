import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound physical-device exercise of the exact AVKit deferred-pause
/// command path. Fault injection changes only libVLC's pause-capability answer;
/// all command ownership, retries, native issuance, and reconciliation remain
/// the Release library implementation.
struct PiPDeferredPauseValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var result = "not-run"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let streams = HarnessStreams.load()?.streams

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        DirectPiPValidationSurface(player: player, controller: $controller)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPDeferredPauseValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPDeferredPauseValidation.stateLabel
        )
        valueRow(
          "Playback intent",
          value: player.isPlaybackRequestedActive ? "playing" : "paused",
          identifier: AccessibilityID.PiPDeferredPauseValidation.intentLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPDeferredPauseValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPDeferredPauseValidation.activeLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.PiPDeferredPauseValidation.resultLabel
        )
      }

      Section("Picture in Picture") {
        Button(
          controller?.isActive == true ? "Stop PiP" : "Start PiP",
          systemImage: "pip",
          action: { controller?.toggle() }
        )
        .accessibilityIdentifier(AccessibilityID.PiPDeferredPauseValidation.toggleButton)
        .disabled(controller?.isPossible != true || isRunning)

        Button("Run deferred-pause qualification") {
          Task { await runQualification() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPDeferredPauseValidation.runButton)
        .disabled(
          isRunning
            || controller?.isActive != true
            || player.state != .playing
            || streams?.vod == nil
        )

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPDeferredPauseValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Deferred PiP pause")
    .task { startPlayback() }
    .onDisappear {
      player.configureDeferredPauseQualificationFault(.disabled)
      player.stop()
    }
  }

  private func startPlayback() {
    guard let url = streams?.vod else {
      playbackError = "Missing validation VOD"
      return
    }
    do {
      try player.play(url: url)
    } catch {
      playbackError = String(describing: error)
    }
  }

  private func runQualification() async {
    guard let controller, let url = streams?.vod else { return }
    isRunning = true
    result = "running"
    playbackError = nil
    defer {
      player.configureDeferredPauseQualificationFault(.disabled)
      isRunning = false
    }

    do {
      let permanent = try await runPermanentCase(controller: controller)
      let transient = try await runTransientCase(controller: controller)
      let cancellations = try await runCancellationCases(
        controller: controller,
        url: url
      )
      let truthfulControls = permanent.truthfulControls
        && transient.truthfulControls
        && cancellations.truthfulControls
      let evidence = QualificationEvidence(
        permanentCase: permanent,
        transientCase: transient,
        cancellationCases: cancellations.allPassed ? "pass" : "failed",
        cancellationResults: cancellations.results,
        endlessTaskCount: permanent.taskStayedSettled ? 0 : 1,
        duplicatePauseCount: transient.nativePauseCommandCount > 1
          ? transient.nativePauseCommandCount - 1 : 0,
        truthfulControls: truthfulControls
      )
      guard
        evidence.permanentCase.outcome == "rejected",
        evidence.permanentCase.forcedRejectionCount > 0,
        evidence.permanentCase.nativePauseCommandCount == 0,
        evidence.transientCase.outcome == "issued",
        evidence.transientCase.forcedRejectionCount == 3,
        evidence.transientCase.nativePauseCommandCount == 1,
        evidence.cancellationCases == "pass",
        evidence.endlessTaskCount == 0,
        evidence.duplicatePauseCount == 0,
        evidence.truthfulControls
      else {
        throw ValidationFailure("One or more acceptance conditions failed")
      }
      let data = try JSONEncoder().encode(evidence)
      result = "pass:\(data.base64EncodedString())"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func runPermanentCase(
    controller: PiPController
  )
    async throws -> PauseCaseEvidence {
    player.configureDeferredPauseQualificationFault(.permanentRejection)
    controller.performDeferredPauseQualificationCommand(playing: false)
    let outcome = try await awaitOutcome(controller, timeout: .seconds(12))
    let settledSnapshot = player.deferredPauseQualificationSnapshot
    try await Task.sleep(for: .milliseconds(750))
    let laterSnapshot = player.deferredPauseQualificationSnapshot
    let taskStayedSettled = !controller.isDeferredPauseQualificationInFlight
      && settledSnapshot == laterSnapshot
    return PauseCaseEvidence(
      outcome: outcome.name,
      forcedRejectionCount: settledSnapshot.forcedRejectionCount,
      nativePauseCommandCount: settledSnapshot.nativePauseCommandCount,
      taskStayedSettled: taskStayedSettled,
      truthfulControls: player.state == .playing
        && controller.deferredPauseQualificationControlsArePlaying
    )
  }

  private func runTransientCase(
    controller: PiPController
  )
    async throws -> PauseCaseEvidence {
    player.configureDeferredPauseQualificationFault(
      .transientRejection(attempts: 3)
    )
    controller.performDeferredPauseQualificationCommand(playing: false)
    let outcome = try await awaitOutcome(controller, timeout: .seconds(8))
    try await awaitPlayerState(.paused, timeout: .seconds(3))
    let snapshot = player.deferredPauseQualificationSnapshot
    let truthful = !controller.deferredPauseQualificationControlsArePlaying
      && !player.isPlaybackRequestedActive
      && player.state == .paused
    controller.performDeferredPauseQualificationCommand(playing: true)
    try await awaitPlayerState(.playing, timeout: .seconds(3))
    return PauseCaseEvidence(
      outcome: outcome.name,
      forcedRejectionCount: snapshot.forcedRejectionCount,
      nativePauseCommandCount: snapshot.nativePauseCommandCount,
      taskStayedSettled: !controller.isDeferredPauseQualificationInFlight,
      truthfulControls: truthful
    )
  }

  private func runCancellationCases(
    controller: PiPController,
    url: URL
  )
    async throws -> CancellationEvidence {
    var cases: [String: String] = [:]
    var truthfulControls = true

    player.configureDeferredPauseQualificationFault(.permanentRejection)
    controller.performDeferredPauseQualificationCommand(playing: false)
    try await Task.sleep(for: .milliseconds(50))
    controller.performDeferredPauseQualificationCommand(playing: true)
    cases["newerCommand"] = try await awaitOutcome(controller, timeout: .seconds(2)).name
    truthfulControls = truthfulControls
      && controller.deferredPauseQualificationControlsArePlaying

    player.configureDeferredPauseQualificationFault(.permanentRejection)
    controller.performDeferredPauseQualificationCommand(playing: false)
    try await Task.sleep(for: .milliseconds(50))
    try player.play(url: url)
    cases["replacement"] = try await awaitOutcome(controller, timeout: .seconds(3)).name
    try await awaitPlayerState(.playing, timeout: .seconds(5))
    truthfulControls = truthfulControls
      && controller.deferredPauseQualificationControlsArePlaying

    player.configureDeferredPauseQualificationFault(.permanentRejection)
    controller.performDeferredPauseQualificationCommand(playing: false)
    try await Task.sleep(for: .milliseconds(50))
    player.stop()
    cases["stop"] = try await awaitOutcome(controller, timeout: .seconds(3)).name
    try player.play(url: url)
    try await awaitPlayerState(.playing, timeout: .seconds(5))

    try await Task.sleep(for: .milliseconds(500))
    let noLatePause = player.deferredPauseQualificationSnapshot.nativePauseCommandCount == 0
      && !controller.isDeferredPauseQualificationInFlight
    let allPassed = cases.values.allSatisfy { $0 == "cancelled" }
      && cases.count == 3
      && noLatePause
    return CancellationEvidence(
      results: cases,
      allPassed: allPassed,
      truthfulControls: truthfulControls && player.isPlaybackRequestedActive
    )
  }

  private func awaitOutcome(
    _ controller: PiPController,
    timeout: Duration
  )
    async throws -> PiPController.DeferredPauseOutcome {
    let deadline = ContinuousClock.now + timeout
    while controller.deferredPauseOutcome == nil {
      guard ContinuousClock.now < deadline else {
        throw ValidationFailure("Deferred-pause outcome timed out")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let outcome = controller.deferredPauseOutcome else {
      throw ValidationFailure("Deferred-pause outcome disappeared")
    }
    return outcome
  }

  private func awaitPlayerState(
    _ expected: PlayerState,
    timeout: Duration
  )
    async throws {
    let deadline = ContinuousClock.now + timeout
    while player.state != expected {
      guard ContinuousClock.now < deadline else {
        throw ValidationFailure("Expected \(expected), got \(player.state)")
      }
      try await Task.sleep(for: .milliseconds(20))
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }
}

private struct PauseCaseEvidence: Codable {
  let outcome: String
  let forcedRejectionCount: Int
  let nativePauseCommandCount: Int
  let taskStayedSettled: Bool
  let truthfulControls: Bool
}

private struct CancellationEvidence {
  let results: [String: String]
  let allPassed: Bool
  let truthfulControls: Bool
}

private struct QualificationEvidence: Codable {
  let permanentCase: PauseCaseEvidence
  let transientCase: PauseCaseEvidence
  let cancellationCases: String
  let cancellationResults: [String: String]
  let endlessTaskCount: Int
  let duplicatePauseCount: Int
  let truthfulControls: Bool
}

private struct ValidationFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension PiPController.DeferredPauseOutcome {
  fileprivate var name: String {
    switch self {
    case .issued: "issued"
    case .cancelled: "cancelled"
    case .rejected: "rejected"
    }
  }
}
