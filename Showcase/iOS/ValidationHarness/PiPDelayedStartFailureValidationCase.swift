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
      let stream = controller.pipEventEnvelopes
      let collector = Task {
        try await collectFailure(from: stream, timeout: .seconds(5))
      }
      let startResult = controller.performAcceptedStartDelayedFailureQualification()
      guard startResult == .accepted else {
        collector.cancel()
        throw ValidationFailure("Start returned \(startResult.name)")
      }
      let collection = try await collector.value
      let orderedAttribution = collection.events.last == "failedToStart"
        && !collection.events.contains("didStart")
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

  private func collectFailure(
    from stream: AsyncStream<PiPEventEnvelope>,
    timeout: Duration
  )
    async throws -> FailureCollection {
    try await withThrowingTaskGroup(of: FailureCollection.self) { group in
      group.addTask {
        var events: [String] = []
        for await envelope in stream {
          let eventName = envelope.event.name
          events.append(eventName)
          if case .failedToStart(let error) = envelope.event {
            let failure = error as NSError
            return FailureCollection(
              events: events,
              failure: envelope,
              failureDomain: failure.domain,
              failureCode: failure.code
            )
          }
        }
        throw ValidationFailure("Lifecycle stream ended before start failure")
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        throw ValidationFailure("Delayed start failure timed out")
      }
      defer { group.cancelAll() }
      guard let first = try await group.next() else {
        throw ValidationFailure("No lifecycle result")
      }
      return first
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
