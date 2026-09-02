import AVFoundation
import Combine
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound surface for a real cross-process audio-session
/// interruption plus a deterministic old-device-unavailable route-loss event.
struct PiPInterruptionValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var lifecycleEvents: [String] = []
  @State private var interruptionBeganCount = 0
  @State private var interruptionEndedCount = 0
  @State private var routeLossCount = 0
  @State private var playbackError: String?

  private let streams = HarnessStreams.load()?.streams

  private var renderingPath: InterruptionRenderingPath {
    InterruptionRenderingPath(
      rawValue: LaunchArguments.pipRenderingPathValue ?? "native"
    ) ?? .native
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        videoSurface
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPInterruptionValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPInterruptionValidation.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPInterruptionValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPInterruptionValidation.activeLabel
        )
        valueRow(
          "Lifecycle",
          value: lifecycleEvents.joined(separator: "|"),
          identifier: AccessibilityID.PiPInterruptionValidation.lifecycleEventsLabel
        )
        valueRow(
          "Interruptions",
          value: "\(interruptionBeganCount):\(interruptionEndedCount)",
          identifier: AccessibilityID.PiPInterruptionValidation.interruptionCountsLabel
        )
        valueRow(
          "Route losses",
          value: String(routeLossCount),
          identifier: AccessibilityID.PiPInterruptionValidation.routeLossCountLabel
        )
        valueRow(
          "Played audio buffers",
          value: String(player.statistics?.playedAudioBuffers ?? 0),
          identifier: AccessibilityID.PiPInterruptionValidation.playedAudioBuffersLabel
        )
      }

      Section("Qualification controls") {
        Button("Start PiP", action: startPictureInPicture)
          .accessibilityIdentifier(AccessibilityID.PiPInterruptionValidation.startButton)
          .disabled(controller?.isPossible != true || controller?.isActive == true)

        Button("Inject old-device-unavailable route loss", action: injectRouteLoss)
          .accessibilityIdentifier(
            AccessibilityID.PiPInterruptionValidation.injectRouteLossButton
          )
          .disabled(controller?.isActive != true)

        Button("Resume after route loss", action: resumePlayback)
          .accessibilityIdentifier(AccessibilityID.PiPInterruptionValidation.resumeButton)
          .disabled(player.state != .paused)

        Button("Stop PiP", action: { controller?.stop() })
          .accessibilityIdentifier(AccessibilityID.PiPInterruptionValidation.stopButton)
          .disabled(controller?.isActive != true)

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPInterruptionValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("PiP audio disruptions")
    .task { startPlayback() }
    .task(id: controller.map(ObjectIdentifier.init)) {
      lifecycleEvents.removeAll()
      guard let controller else { return }
      for await envelope in controller.pipEventEnvelopes {
        lifecycleEvents.append(envelope.event.interruptionQualificationName)
      }
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVAudioSession.interruptionNotification,
        object: AVAudioSession.sharedInstance()
      )
    ) { notification in
      recordInterruption(notification)
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVAudioSession.routeChangeNotification,
        object: AVAudioSession.sharedInstance()
      )
    ) { notification in
      recordRouteChange(notification)
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

  private func startPictureInPicture() {
    guard let controller else { return }
    playbackError = nil
    guard controller.requestStart() == .accepted else {
      playbackError = "PiP start was not accepted"
      return
    }
  }

  private func injectRouteLoss() {
    NotificationCenter.default.post(
      name: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(),
      userInfo: [
        AVAudioSessionRouteChangeReasonKey:
          AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
      ]
    )
  }

  private func resumePlayback() {
    do {
      try player.play()
    } catch {
      playbackError = String(describing: error)
    }
  }

  private func recordInterruption(_ notification: Notification) {
    guard
      let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: rawType)
    else { return }
    switch type {
    case .began:
      interruptionBeganCount += 1
    case .ended:
      interruptionEndedCount += 1
    @unknown default:
      break
    }
  }

  private func recordRouteChange(_ notification: Notification) {
    guard
      let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable
    else { return }
    routeLossCount += 1
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

private enum InterruptionRenderingPath: String {
  case native
  case direct
}

extension PiPEvent {
  fileprivate var interruptionQualificationName: String {
    switch self {
    case .willStart: "willStart"
    case .didStart: "didStart"
    case .willStop(let reason): "willStop:\(String(describing: reason))"
    case .didStop(let reason): "didStop:\(String(describing: reason))"
    case .failedToStart: "failedToStart"
    }
  }
}
