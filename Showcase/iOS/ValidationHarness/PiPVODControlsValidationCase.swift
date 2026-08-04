import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound VOD transport exercise while real system PiP is active.
/// Play/pause and relative skips enter through the backend-specific callbacks
/// used by AVKit or libVLC; the absolute scrub uses Player's public seek API.
struct PiPVODControlsValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var lifecycleEvents: [String] = []
  @State private var result = "not-run"
  @State private var playbackError: String?
  @State private var isRunning = false
  @State private var completedControls: ControlEvidence?

  private let streams = HarnessStreams.load()?.streams

  private var renderingPath: RenderingPath {
    RenderingPath(rawValue: LaunchArguments.pipRenderingPathValue ?? "native") ?? .native
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        videoSurface
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPVODControlsValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPVODControlsValidation.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPVODControlsValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPVODControlsValidation.activeLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.PiPVODControlsValidation.resultLabel
        )
      }

      Section("Picture in Picture") {
        Button("Run VOD controls qualification") {
          Task { await runQualification() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPVODControlsValidation.runButton)
        .disabled(isRunning || controller?.isPossible != true || player.state != .playing)

        Button("Stop and finalize evidence") {
          Task { await stopAndFinalize() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPVODControlsValidation.stopButton)
        .disabled(completedControls == nil || controller?.isActive != true)

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPVODControlsValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("VOD PiP controls")
    .task { startPlayback() }
    .task(id: controller.map(ObjectIdentifier.init)) {
      lifecycleEvents.removeAll()
      guard let controller else { return }
      for await envelope in controller.pipEventEnvelopes {
        lifecycleEvents.append(envelope.event.qualificationName)
      }
    }
    .onDisappear {
      controller?.stop()
      player.stop()
    }
  }

  @ViewBuilder
  private var videoSurface: some View {
    switch renderingPath {
    case .native:
      PiPVideoView(player, controller: $controller, startsAutomaticallyFromInline: false)
    case .direct:
      DirectPiPValidationSurface(player: player, controller: $controller)
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
    completedControls = nil
    do {
      guard controller.start() == .accepted else {
        throw QualificationFailure("PiP start was not accepted")
      }
      try await waitUntil("PiP did not become active") { controller.isActive }
      try await waitUntil("Playback clock did not advance") {
        player.currentTime.milliseconds >= 1000
      }

      controller.performQualificationSetPlaying(false)
      try await waitUntil("PiP pause did not settle") { !player.isActive }
      let pausedTime = player.currentTime.milliseconds
      try await Task.sleep(for: .milliseconds(350))
      guard abs(player.currentTime.milliseconds - pausedTime) <= 500 else {
        throw QualificationFailure("Playback clock advanced while paused")
      }

      controller.performQualificationSetPlaying(true)
      try await waitUntil("PiP play did not settle") { player.isActive }

      try player.seek(to: .seconds(15))
      try await waitUntil("Absolute scrub did not land") {
        abs(player.currentTime.milliseconds - 15000) <= 2000
      }

      let forwardBefore = player.currentTime.milliseconds
      guard await controller.performQualificationSkip(bySeconds: 10) else {
        throw QualificationFailure("Forward PiP skip did not settle")
      }
      let forwardAfter = player.currentTime.milliseconds
      guard forwardAfter > forwardBefore else {
        throw QualificationFailure("Forward PiP skip moved backward or nowhere")
      }

      let backwardBefore = player.currentTime.milliseconds
      guard await controller.performQualificationSkip(bySeconds: -10) else {
        throw QualificationFailure("Backward PiP skip did not settle")
      }
      let backwardAfter = player.currentTime.milliseconds
      guard backwardAfter < backwardBefore else {
        throw QualificationFailure("Backward PiP skip moved forward or nowhere")
      }

      completedControls = ControlEvidence(
        play: "pass",
        pause: "pass",
        scrub: "pass",
        skipForward: "pass",
        skipBackward: "pass",
        pausedTimeMilliseconds: pausedTime,
        scrubTargetMilliseconds: 15000,
        forwardBeforeMilliseconds: forwardBefore,
        forwardAfterMilliseconds: forwardAfter,
        backwardBeforeMilliseconds: backwardBefore,
        backwardAfterMilliseconds: backwardAfter
      )
      result = "ready-for-motion-check"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
      controller.stop()
    }
    isRunning = false
  }

  private func stopAndFinalize() async {
    guard let controller, let completedControls else { return }
    result = "stopping"
    controller.stop()
    do {
      try await waitUntil("PiP did not stop") { !controller.isActive }
      try await waitUntil("Programmatic stop event did not arrive") {
        lifecycleEvents.contains("didStop:programmatic")
      }
      guard lifecycleOrderPasses else {
        throw QualificationFailure("Lifecycle events were incomplete or reordered")
      }
      let evidence = QualificationEvidence(
        backend: renderingPath.rawValue,
        commandPath: renderingPath == .native
          ? "nativeMediaController"
          : "sampleBufferPlaybackDelegate",
        orderedEvents: lifecycleEvents,
        events: EventEvidence(
          started: true,
          unexpectedStopCount: lifecycleEvents.filter {
            $0.hasPrefix("didStop:") && $0 != "didStop:programmatic"
          }.count,
          order: "pass"
        ),
        controls: completedControls
      )
      let data = try JSONEncoder().encode(evidence)
      result = "pass:\(data.base64EncodedString())"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private var lifecycleOrderPasses: Bool {
    let required = ["willStart", "didStart", "willStop:programmatic", "didStop:programmatic"]
    var searchStart = lifecycleEvents.startIndex
    for value in required {
      guard let index = lifecycleEvents[searchStart...].firstIndex(of: value) else { return false }
      searchStart = lifecycleEvents.index(after: index)
    }
    return true
  }

  private func waitUntil(
    _ failure: String,
    timeout: Duration = .seconds(12),
    condition: @escaping @MainActor () -> Bool
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw QualificationFailure(failure) }
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

private enum RenderingPath: String {
  case native
  case direct
}

private struct QualificationEvidence: Encodable {
  let formatVersion = 1
  let scenario = "vod-controls"
  let backend: String
  let commandPath: String
  let orderedEvents: [String]
  let events: EventEvidence
  let controls: ControlEvidence
}

private struct EventEvidence: Encodable {
  let started: Bool
  let unexpectedStopCount: Int
  let order: String
}

private struct ControlEvidence: Encodable {
  let play: String
  let pause: String
  let scrub: String
  let skipForward: String
  let skipBackward: String
  let pausedTimeMilliseconds: Int64
  let scrubTargetMilliseconds: Int64
  let forwardBeforeMilliseconds: Int64
  let forwardAfterMilliseconds: Int64
  let backwardBeforeMilliseconds: Int64
  let backwardAfterMilliseconds: Int64
}

private struct QualificationFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension PiPEvent {
  fileprivate var qualificationName: String {
    switch self {
    case .willStart: "willStart"
    case .didStart: "didStart"
    case .willStop(let reason): "willStop:\(String(describing: reason))"
    case .didStop(let reason): "didStop:\(String(describing: reason))"
    case .failedToStart: "failedToStart"
    }
  }
}
