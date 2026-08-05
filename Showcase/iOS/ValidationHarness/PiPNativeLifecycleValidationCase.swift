import Foundation
import SwiftUI
@_spi(Qualification) @_spi(ValidationHarness) import SwiftVLC

/// Runs one isolated native-drawable lifecycle transition against the exact
/// candidate. System restore and close remain in the SpringBoard-driven
/// dismissal test; this surface covers the transitions the app can initiate.
struct PiPNativeLifecycleValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var lifecycle: [LifecycleEvent] = []
  @State private var result = "not-run"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let streams = HarnessStreams.load()?.streams

  private var action: NativeLifecycleAction? {
    LaunchArguments.pipNativeLifecycleActionValue.flatMap(NativeLifecycleAction.init(rawValue:))
  }

  var body: some View {
    Form {
      Section {
        PiPVideoView(player, controller: $controller, startsAutomaticallyFromInline: false)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPNativeLifecycleValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPNativeLifecycleValidation.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPNativeLifecycleValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPNativeLifecycleValidation.activeLabel
        )
        valueRow(
          "Lifecycle",
          value: lifecycle.map(\.name).joined(separator: "|"),
          identifier: AccessibilityID.PiPNativeLifecycleValidation.lifecycleEventsLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.PiPNativeLifecycleValidation.resultLabel
        )
      }

      Section("Native lifecycle") {
        Button("Run \(action?.rawValue ?? "invalid")") {
          Task { await run() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPNativeLifecycleValidation.runButton)
        .disabled(
          isRunning || action == nil || controller?.isPossible != true
            || player.state != .playing
        )

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPNativeLifecycleValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Native PiP lifecycle")
    .task { startPlayback() }
    .task(id: controller.map(ObjectIdentifier.init)) {
      guard let controller else { return }
      for await envelope in controller.pipEventEnvelopes {
        lifecycle.append(
          LifecycleEvent(
            name: envelope.event.nativeLifecycleQualificationName,
            controllerGeneration: envelope.controllerGeneration,
            mediaGeneration: envelope.mediaGeneration.qualificationValue
          )
        )
      }
    }
    .onDisappear {
      controller?.stop()
      player.stop()
    }
  }

  private func startPlayback() {
    guard let action else {
      playbackError = "Missing native lifecycle action"
      return
    }
    let url: URL? = switch action {
    case .failure:
      gatedFailureURL
    default:
      streams?.vod
    }
    guard let url else {
      playbackError = "Missing validation media for \(action.rawValue)"
      return
    }
    do {
      try player.play(url: url)
    } catch {
      playbackError = String(describing: error)
    }
  }

  private func run() async {
    guard let action, let controller else { return }
    isRunning = true
    playbackError = nil
    result = "running"
    do {
      let probe = try await waitForBridgeProbe(controller)
      lifecycle.removeAll(keepingCapacity: true)
      let actionOutcome = try await execute(action, controller: controller)
      let evidence = CaseEvidence(
        action: action.rawValue,
        actionOutcome: actionOutcome,
        bridge: BridgeEvidence(probe),
        orderedEvents: lifecycle
      )
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
      controller.stop()
    }
    isRunning = false
  }

  private func execute(
    _ action: NativeLifecycleAction,
    controller: PiPController
  )
    async throws -> String {
    switch action {
    case .failedStart:
      guard controller.performNativeAcceptedStartFailureQualification() == .accepted else {
        throw NativeLifecycleFailure("Native PiP failure request was not accepted")
      }
      try await waitUntil("Native failedToStart event did not arrive") {
        lifecycle.contains { $0.name == "failedToStart" }
      }
      // Keep observing the still-accepted AVKit request. A late native start
      // invalidates the failure proof instead of arriving after a pass was
      // already published to the UI-test process.
      try await Task.sleep(for: .seconds(3))
      guard
        lifecycle.map(\.name) == ["willStart", "failedToStart"],
        controller.isActive == false
      else {
        throw NativeLifecycleFailure("Native failed start produced late or reordered events")
      }
      return "failedToStart"

    case .programmatic:
      try await startAndWait(controller)
      controller.stop()
      try await waitForTerminal("programmatic")
      return "stopped"

    case .mediaEnd:
      try await startAndWait(controller)
      try await waitUntil("VOD duration did not become available") {
        (player.duration?.milliseconds ?? 0) > 1500
      }
      guard let duration = player.duration else {
        throw NativeLifecycleFailure("VOD duration disappeared before the end seek")
      }
      try player.seek(to: .milliseconds(max(0, duration.milliseconds - 500)))
      try await waitForTerminal("mediaEnded", timeout: .seconds(20))
      return "naturalEnd"

    case .failure:
      try await startAndWait(controller)
      guard let triggerURL = failureTriggerURL else {
        throw NativeLifecycleFailure("Missing gated failure trigger URL")
      }
      let (_, response) = try await URLSession.shared.data(from: triggerURL)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw NativeLifecycleFailure("Fixture failure trigger was rejected")
      }
      try await waitForTerminal("failure", timeout: .seconds(30))
      return "sourceFailure"

    case .recast:
      try await startAndWait(controller)
      let outcome = try await player.recast(to: nil)
      guard outcome == .settled else {
        throw NativeLifecycleFailure("Recast did not settle: \(String(describing: outcome))")
      }
      try await waitForTerminal("controllerReplaced")
      return "settled"

    case .replacement:
      try await startAndWait(controller)
      guard let live = streams?.hlsLive ?? streams?.liveTS else {
        throw NativeLifecycleFailure("Missing replacement stream")
      }
      let outgoingGeneration = player.playbackQualificationGeneration.qualificationValue
      try player.play(url: live)
      try await waitForTerminal("controllerReplaced")
      try await waitUntil("Replacement playback did not start") {
        player.playbackQualificationGeneration.qualificationValue > outgoingGeneration
          && player.state == .playing
      }
      return "playingSuccessor"
    }
  }

  private func startAndWait(_ controller: PiPController) async throws {
    guard controller.start() == .accepted else {
      throw NativeLifecycleFailure("Native PiP start was not accepted")
    }
    try await waitUntil("Native PiP did not become active") { controller.isActive }
    try await waitUntil("Native start lifecycle was incomplete") {
      lifecycle.contains { $0.name == "willStart" }
        && lifecycle.contains { $0.name == "didStart" }
    }
  }

  private func waitForTerminal(
    _ reason: String,
    timeout: Duration = .seconds(15)
  )
    async throws {
    try await waitUntil("Missing authoritative \(reason) stop", timeout: timeout) {
      lifecycle.contains { $0.name == "willStop:\(reason)" }
        && lifecycle.contains { $0.name == "didStop:\(reason)" }
    }
  }

  private func waitForBridgeProbe(_ controller: PiPController) async throws -> NativePiPProbe {
    var captured: NativePiPProbe?
    try await waitUntil("Native lifecycle bridge probe did not converge") {
      guard let probe = controller.nativeValidationProbe else { return false }
      captured = probe
      return probe.hasAVController && probe.hasLifecycleDelegateBridge
    }
    guard let captured else {
      throw NativeLifecycleFailure("Native lifecycle bridge probe disappeared")
    }
    return captured
  }

  private var fixtureBaseURL: URL? {
    guard let live = streams?.liveTS else { return nil }
    var components = URLComponents(url: live, resolvingAgainstBaseURL: false)
    components?.path = ""
    components?.query = nil
    components?.fragment = nil
    return components?.url
  }

  private var gatedFailureURL: URL? {
    guard let token = LaunchArguments.pipNativeLifecycleTokenValue else { return nil }
    return fixtureBaseURL?
      .appending(path: "fault/gated-close/\(token)/live.ts")
  }

  private var failureTriggerURL: URL? {
    guard let token = LaunchArguments.pipNativeLifecycleTokenValue else { return nil }
    return fixtureBaseURL?
      .appending(path: "fault/close-trigger/\(token)")
  }

  private func waitUntil(
    _ failure: String,
    timeout: Duration = .seconds(15),
    condition: @escaping @MainActor () -> Bool
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw NativeLifecycleFailure(failure) }
      try await Task.sleep(for: .milliseconds(50))
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
    }
    .qualificationAccessibilityValue(value, title: title, identifier: identifier)
  }
}

private enum NativeLifecycleAction: String, CaseIterable {
  case failedStart = "failed-start"
  case programmatic
  case mediaEnd = "media-end"
  case failure
  case recast
  case replacement
}

private struct LifecycleEvent: Codable {
  let name: String
  let controllerGeneration: UInt64
  let mediaGeneration: UInt64
}

private struct BridgeEvidence: Codable {
  let windowControllerClassName: String?
  let hasAVController: Bool
  let delegateClassName: String?
  let hasLifecycleDelegateBridge: Bool
  let delegateResponds: [String: Bool]

  init(_ probe: NativePiPProbe) {
    windowControllerClassName = probe.windowControllerClassName
    hasAVController = probe.hasAVController
    delegateClassName = probe.avDelegateClassName
    hasLifecycleDelegateBridge = probe.hasLifecycleDelegateBridge
    delegateResponds = probe.delegateResponds
  }
}

private struct CaseEvidence: Codable {
  let action: String
  let actionOutcome: String
  let bridge: BridgeEvidence
  let orderedEvents: [LifecycleEvent]
}

private struct NativeLifecycleFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension PiPEvent {
  fileprivate var nativeLifecycleQualificationName: String {
    switch self {
    case .willStart: "willStart"
    case .didStart: "didStart"
    case .willStop(let reason): "willStop:\(String(describing: reason))"
    case .didStop(let reason): "didStop:\(String(describing: reason))"
    case .failedToStart: "failedToStart"
    }
  }
}
