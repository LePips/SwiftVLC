import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Runs one isolated terminal playback transition against the exact candidate.
/// Two independent subscribers must observe the same immutable pre-reset
/// payload, and the process remains alive briefly to reject duplicate results.
struct TerminalOutcomesValidationCase: View {
  @State private var player: Player
  @State private var result = "not-run"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let action: TerminalAction?
  private let instance: VLCInstance
  private let streams: HarnessStreams?

  init() {
    let selected = LaunchArguments.terminalOutcomeActionValue
      .flatMap(TerminalAction.init(rawValue:))
    action = selected
    let additionalArguments = selected?.instanceArguments ?? []
    if additionalArguments.isEmpty {
      instance = .shared
    } else {
      let arguments = VLCInstance.defaultArguments + additionalArguments
      instance = (try? VLCInstance(arguments: arguments)) ?? .shared
    }
    _player = State(initialValue: Player(instance: instance))
    streams = HarnessStreams.load()?.streams
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        VideoView(player)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.TerminalOutcomesValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.TerminalOutcomesValidation.stateLabel
        )
        valueRow(
          "Action",
          value: action?.rawValue ?? "invalid",
          identifier: AccessibilityID.TerminalOutcomesValidation.actionLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.TerminalOutcomesValidation.resultLabel
        )
      }

      Section("Terminal outcome") {
        Button("Run \(action?.rawValue ?? "invalid")") {
          Task { await run() }
        }
        .accessibilityIdentifier(AccessibilityID.TerminalOutcomesValidation.runButton)
        .disabled(action == nil || isRunning)

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.TerminalOutcomesValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Terminal outcomes")
    .onDisappear { player.stop() }
  }

  private func run() async {
    guard let action else { return }
    isRunning = true
    result = "running"
    playbackError = nil

    let recorder = TerminalRecorder()
    let firstStream = player.terminalOutcomes
    let secondStream = player.terminalOutcomes
    let firstSubscriber = Task {
      for await outcome in firstStream {
        await recorder.record(outcome, subscriber: 0)
      }
    }
    let secondSubscriber = Task {
      for await outcome in secondStream {
        await recorder.record(outcome, subscriber: 1)
      }
    }
    let errors = LibraryErrorRecorder()
    let logTask = Task {
      for await entry in instance.logStream(minimumLevel: .error) {
        await errors.record(entry)
      }
    }
    defer {
      firstSubscriber.cancel()
      secondSubscriber.cancel()
      logTask.cancel()
      isRunning = false
    }

    do {
      // Ensure both async subscriptions and the native log callback are live
      // before the transition can publish its one-shot terminal payload.
      try await Task.sleep(for: .milliseconds(150))
      let execution = try await execute(action)
      try await waitUntil("Two terminal subscribers did not converge", timeout: .seconds(35)) {
        await recorder.hasOutcomeFromBothSubscribers
      }
      try await Task.sleep(for: .seconds(2))

      let snapshot = await recorder.snapshot
      guard
        snapshot.first.count == 1,
        snapshot.second.count == 1,
        let first = snapshot.first.first,
        let second = snapshot.second.first,
        first == second
      else {
        throw TerminalValidationFailure("Terminal subscribers diverged or received duplicates")
      }
      guard first.cause.qualificationName == action.expectedCause else {
        throw TerminalValidationFailure(
          "Expected \(action.expectedCause), received \(first.cause.qualificationName)"
        )
      }
      guard
        first.generation.qualificationValue == execution.terminalGeneration,
        execution.successorPreserved
      else {
        throw TerminalValidationFailure(
          "Terminal outcome escaped its owning generation"
        )
      }
      let errorRecords = await errors.snapshot
      let evidence = TerminalCaseEvidence(
        action: action.rawValue,
        outcome: OutcomeEvidence(first),
        subscriberPayloadsIdentical: true,
        outcomeCountPerSubscriber: 1,
        generationIsolation: true,
        libraryErrors: errorRecords
      )
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
      player.stop()
    }
  }

  private func execute(_ action: TerminalAction) async throws -> TerminalExecution {
    switch action {
    case .cleanEOF:
      try play(requiredURL(streams?.vod, name: "VOD"))
      let generation = player.playbackQualificationGeneration.qualificationValue
      try await waitForPlaying()
      try await waitUntil("VOD duration did not become available") {
        (player.duration?.milliseconds ?? 0) > 1500
      }
      guard let duration = player.duration else {
        throw TerminalValidationFailure("VOD duration disappeared")
      }
      try player.seek(to: .milliseconds(max(0, duration.milliseconds - 500)))
      return TerminalExecution(terminalGeneration: generation)

    case .explicitStop:
      try play(requiredURL(streams?.vod, name: "VOD"))
      let generation = player.playbackQualificationGeneration.qualificationValue
      try await waitForPlaying()
      try await Task.sleep(for: .milliseconds(500))
      player.stop()
      return TerminalExecution(terminalGeneration: generation)

    case .replacement:
      try play(requiredURL(streams?.vod, name: "VOD"))
      try await waitForPlaying()
      let outgoing = player.playbackQualificationGeneration.qualificationValue
      try play(requiredURL(streams?.hlsLive ?? streams?.liveTS, name: "successor stream"))
      try await waitUntil("Successor generation did not start", timeout: .seconds(20)) {
        player.playbackQualificationGeneration.qualificationValue > outgoing
          && player.state == .playing
      }
      try await Task.sleep(for: .seconds(1))
      return TerminalExecution(
        terminalGeneration: outgoing,
        successorPreserved: player.playbackQualificationGeneration.qualificationValue > outgoing
          && player.state == .playing
      )

    case .serverClose:
      try play(requiredURL(serverCloseURL, name: "gated server-close stream"))
      let generation = player.playbackQualificationGeneration.qualificationValue
      try await waitForPlaying()
      let (_, response) = try await URLSession.shared.data(
        from: requiredURL(serverCloseTriggerURL, name: "server-close trigger")
      )
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw TerminalValidationFailure("Server-close trigger was rejected")
      }
      return TerminalExecution(terminalGeneration: generation)

    case .malformed:
      try play(requiredURL(fileURL("malformed.mp4"), name: "malformed input"))
      return TerminalExecution(
        terminalGeneration: player.playbackQualificationGeneration.qualificationValue
      )

    case .decodeFailure:
      try play(requiredURL(fileURL("unsupported-codec.mp4"), name: "unsupported codec"))
      return TerminalExecution(
        terminalGeneration: player.playbackQualificationGeneration.qualificationValue
      )

    case .rendererFailure:
      try play(requiredURL(streams?.vod, name: "renderer VOD"))
      return TerminalExecution(
        terminalGeneration: player.playbackQualificationGeneration.qualificationValue
      )

    case .outputFailure:
      try play(requiredURL(streams?.audioOnly, name: "audio fixture"))
      return TerminalExecution(
        terminalGeneration: player.playbackQualificationGeneration.qualificationValue
      )

    case .networkLoss:
      try play(requiredURL(networkLossURL, name: "network-loss stream"))
      return TerminalExecution(
        terminalGeneration: player.playbackQualificationGeneration.qualificationValue
      )
    }
  }

  private func play(_ url: URL) throws {
    try player.play(url: url)
  }

  private func waitForPlaying() async throws {
    try await waitUntil("Playback did not start", timeout: .seconds(20)) {
      player.state == .playing
    }
  }

  private func requiredURL(_ url: URL?, name: String) throws -> URL {
    guard let url else { throw TerminalValidationFailure("Missing \(name)") }
    return url
  }

  private var fixtureBaseURL: URL? {
    guard let vod = streams?.vod else { return nil }
    var components = URLComponents(url: vod, resolvingAgainstBaseURL: false)
    components?.path = ""
    components?.query = nil
    components?.fragment = nil
    return components?.url
  }

  private func fileURL(_ name: String) -> URL? {
    fixtureBaseURL?.appending(path: "files/\(name)")
  }

  private var serverCloseURL: URL? {
    guard let token = LaunchArguments.terminalOutcomeTokenValue else { return nil }
    return fixtureBaseURL?.appending(path: "fault/gated-close/\(token)/live.ts")
  }

  private var serverCloseTriggerURL: URL? {
    guard let token = LaunchArguments.terminalOutcomeTokenValue else { return nil }
    return fixtureBaseURL?.appending(path: "fault/close-trigger/\(token)")
  }

  private var networkLossURL: URL? {
    fixtureBaseURL?.appending(path: "fault/close/32768/live.ts")
  }

  private func waitUntil(
    _ failure: String,
    timeout: Duration = .seconds(15),
    condition: @escaping @MainActor () async -> Bool
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while await condition() == false {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw TerminalValidationFailure(failure) }
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

private enum TerminalAction: String, CaseIterable {
  case cleanEOF = "clean-eof"
  case explicitStop = "explicit-stop"
  case replacement
  case serverClose = "server-close"
  case malformed
  case decodeFailure = "decode-failure"
  case rendererFailure = "renderer-failure"
  case outputFailure = "output-failure"
  case networkLoss = "network-loss"

  var instanceArguments: [String] {
    switch self {
    case .rendererFailure:
      ["--vout=swiftvlc-qualification-missing-vout"]
    case .outputFailure:
      ["--aout=swiftvlc-qualification-missing-aout"]
    default:
      []
    }
  }

  var expectedCause: String {
    switch self {
    case .cleanEOF: "naturalEnd"
    case .explicitStop: "requestedStop"
    case .replacement: "replacement"
    case .serverClose, .networkLoss: "failure:source"
    case .malformed: "failure:demux"
    case .decodeFailure: "failure:decoder"
    case .rendererFailure: "failure:renderer"
    case .outputFailure: "failure:output"
    }
  }
}

private actor TerminalRecorder {
  private var values: [Int: [PlaybackTerminalOutcome]] = [:]

  func record(_ outcome: PlaybackTerminalOutcome, subscriber: Int) {
    values[subscriber, default: []].append(outcome)
  }

  var hasOutcomeFromBothSubscribers: Bool {
    values[0]?.isEmpty == false && values[1]?.isEmpty == false
  }

  var snapshot: (first: [PlaybackTerminalOutcome], second: [PlaybackTerminalOutcome]) {
    (values[0] ?? [], values[1] ?? [])
  }
}

private actor LibraryErrorRecorder {
  private var values: [LibraryErrorEvidence] = []

  func record(_ entry: LogEntry) {
    values.append(
      LibraryErrorEvidence(module: entry.module, message: entry.message)
    )
  }

  var snapshot: [LibraryErrorEvidence] {
    values
  }
}

private struct TerminalCaseEvidence: Encodable {
  let action: String
  let outcome: OutcomeEvidence
  let subscriberPayloadsIdentical: Bool
  let outcomeCountPerSubscriber: Int
  let generationIsolation: Bool
  let libraryErrors: [LibraryErrorEvidence]
}

private struct TerminalExecution {
  let terminalGeneration: UInt64
  var successorPreserved = true
}

private struct OutcomeEvidence: Encodable {
  let generation: UInt64
  let cause: String
  let failureClassification: String?
  let finalTimeline: TimelineEvidence

  init(_ outcome: PlaybackTerminalOutcome) {
    generation = outcome.generation.qualificationValue
    cause = outcome.cause.qualificationName
    failureClassification = outcome.cause.failureQualificationName
    finalTimeline = TimelineEvidence(outcome.finalTimeline)
  }
}

private struct TimelineEvidence: Encodable {
  let timeMilliseconds: Int64
  let durationMilliseconds: Int64?
  let position: Double
  let bufferFill: Float
  let activeVideoOutputs: Int

  init(_ timeline: PlaybackFinalTimeline) {
    timeMilliseconds = timeline.time.milliseconds
    durationMilliseconds = timeline.duration?.milliseconds
    position = timeline.position
    bufferFill = timeline.bufferFill
    activeVideoOutputs = timeline.activeVideoOutputs
  }
}

private struct LibraryErrorEvidence: Encodable {
  let module: String?
  let message: String
}

private struct TerminalValidationFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension PlaybackTerminalCause {
  fileprivate var qualificationName: String {
    switch self {
    case .naturalEnd: "naturalEnd"
    case .requestedStop: "requestedStop"
    case .replacement: "replacement"
    case .cancellation: "cancellation"
    case .failure(let failure): "failure:\(failure.qualificationName)"
    case .unknownNativeStop: "unknownNativeStop"
    }
  }

  fileprivate var failureQualificationName: String? {
    if case .failure(let failure) = self {
      failure.qualificationName
    } else {
      nil
    }
  }
}

extension PlaybackFailureKind {
  fileprivate var qualificationName: String {
    switch self {
    case .source: "source"
    case .demux: "demux"
    case .decoder: "decoder"
    case .renderer: "renderer"
    case .output: "output"
    case .unknown: "unknown"
    }
  }
}
