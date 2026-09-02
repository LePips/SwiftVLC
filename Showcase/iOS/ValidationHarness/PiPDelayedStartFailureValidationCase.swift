import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound exercise of an accepted direct AVKit start followed by an
/// asynchronous delegate failure. The qualification SPI issues the real start
/// request first; only the delayed failure callback is deterministic.
struct PiPDelayedStartFailureValidationCase: View {
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
          .accessibilityIdentifier(AccessibilityID.PiPDelayedStartFailureValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPDelayedStartFailureValidation.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPDelayedStartFailureValidation.possibleLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.PiPDelayedStartFailureValidation.resultLabel
        )
      }

      Section("Picture in Picture") {
        Button("Run accepted-start failure qualification") {
          Task { await runQualification() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPDelayedStartFailureValidation.runButton)
        .disabled(
          isRunning
            || controller?.isPossible != true
            || player.state != .playing
        )

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPDelayedStartFailureValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Delayed PiP start failure")
    .task { startPlayback() }
    .onDisappear {
      controller?.stop()
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
    guard let controller else { return }
    isRunning = true
    result = "running"
    playbackError = nil
    defer {
      controller.stop()
      isRunning = false
    }

    do {
      let expectedControllerGeneration = controller.qualificationControllerGeneration
      let expectedMediaGeneration = player.playbackQualificationGeneration
      let recorder = FailureRecorder()
      let stream = controller.pipEventEnvelopes
      let collector = Task {
        for await envelope in stream {
          await recorder.record(envelope)
        }
      }
      defer { collector.cancel() }
      let startResult = controller.performAcceptedStartDelayedFailureQualification()
      guard startResult == .accepted else {
        throw ValidationFailure("Start returned \(startResult.name)")
      }
      try await waitForFailure(in: recorder, timeout: .seconds(5))
      // Keep the stream live after the injected callback. A real AVKit start
      // from the still-accepted request must invalidate this evidence rather
      // than arriving after the collector has already declared a pass.
      try await Task.sleep(for: .seconds(3))
      controller.stop()
      try await Task.sleep(for: .seconds(1))
      guard let collection = await recorder.snapshot() else {
        throw ValidationFailure("Failure disappeared before evidence capture")
      }
      let failureIndex = collection.events.firstIndex(of: "failedToStart")
      let laterStartSignal = failureIndex.map { index in
        collection.events[collection.events.index(after: index)...].contains {
          $0 == "willStart" || $0 == "didStart" || $0 == "failedToStart"
        }
      } ?? true
      let orderedAttribution = !laterStartSignal
        && !collection.events.contains("didStart")
        && controller.isActive == false
        && collection.failure.controllerGeneration == expectedControllerGeneration
        && collection.failure.mediaGeneration == expectedMediaGeneration
      let evidence = QualificationEvidence(
        startResult: startResult.name,
        orderedEvents: collection.events,
        controllerGeneration: collection.failure.controllerGeneration,
        mediaGeneration: collection.failure.mediaGeneration.qualificationValue,
        expectedControllerGeneration: expectedControllerGeneration,
        expectedMediaGeneration: expectedMediaGeneration.qualificationValue,
        orderedAttribution: orderedAttribution,
        quiescenceMilliseconds: 3000,
        controllerActiveAfterCleanup: controller.isActive,
        failureDomain: collection.failureDomain,
        failureCode: collection.failureCode
      )
      guard evidence.orderedAttribution else {
        throw ValidationFailure("Failure attribution was late, reordered, or mismatched")
      }
      let data = try JSONEncoder().encode(evidence)
      result = "pass:\(data.base64EncodedString())"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func waitForFailure(
    in recorder: FailureRecorder,
    timeout: Duration
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await recorder.hasFailure == false {
      try Task.checkCancellation()
      guard clock.now < deadline else {
        throw ValidationFailure("Delayed start failure timed out")
      }
      try await Task.sleep(for: .milliseconds(50))
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

private struct FailureCollection: Sendable {
  let events: [String]
  let failure: PiPEventEnvelope
  let failureDomain: String
  let failureCode: Int
}

private actor FailureRecorder {
  private var events: [String] = []
  private var failure: PiPEventEnvelope?
  private var failureDomain: String?
  private var failureCode: Int?

  var hasFailure: Bool {
    failure != nil
  }

  func record(_ envelope: PiPEventEnvelope) {
    events.append(envelope.event.name)
    if case .failedToStart(let error) = envelope.event, failure == nil {
      let value = error as NSError
      failure = envelope
      failureDomain = value.domain
      failureCode = value.code
    }
  }

  func snapshot() -> FailureCollection? {
    guard let failure, let failureDomain, let failureCode else { return nil }
    return FailureCollection(
      events: events,
      failure: failure,
      failureDomain: failureDomain,
      failureCode: failureCode
    )
  }
}

private struct QualificationEvidence: Encodable {
  let formatVersion = 1
  let scenario = "accepted-start-delayed-failure"
  let startResult: String
  let orderedEvents: [String]
  let controllerGeneration: UInt64
  let mediaGeneration: UInt64
  let expectedControllerGeneration: UInt64
  let expectedMediaGeneration: UInt64
  let orderedAttribution: Bool
  let quiescenceMilliseconds: Int
  let controllerActiveAfterCleanup: Bool
  let failureDomain: String
  let failureCode: Int
}

private struct ValidationFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension PiPEvent {
  fileprivate var name: String {
    switch self {
    case .willStart: "willStart"
    case .didStart: "didStart"
    case .willStop: "willStop"
    case .didStop: "didStop"
    case .failedToStart: "failedToStart"
    }
  }
}

extension PiPStartResult {
  fileprivate var name: String {
    switch self {
    case .accepted: "accepted"
    case .noMedia: "noMedia"
    case .notPossible: "notPossible"
    case .backendUnavailable: "backendUnavailable"
    }
  }
}
