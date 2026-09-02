import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound surface for exercising the real system PiP restore and
/// close affordances. The UI test interacts with SpringBoard; this view only
/// starts a selected backend and exposes the public lifecycle that results.
struct PiPDismissalValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var lifecycleEvents: [String] = []
  @State private var restoreCount = 0
  @State private var playbackError: String?

  private let streams = HarnessStreams.load()?.streams

  private var renderingPath: DismissalRenderingPath {
    DismissalRenderingPath(
      rawValue: LaunchArguments.pipRenderingPathValue ?? "native"
    ) ?? .native
  }

  var body: some View {
    Form {
      Section {
        videoSurface
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPDismissalValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPDismissalValidation.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPDismissalValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPDismissalValidation.activeLabel
        )
        valueRow(
          "Lifecycle",
          value: lifecycleEvents.joined(separator: "|"),
          identifier: AccessibilityID.PiPDismissalValidation.lifecycleEventsLabel
        )
        valueRow(
          "Restore callbacks",
          value: String(restoreCount),
          identifier: AccessibilityID.PiPDismissalValidation.restoreCountLabel
        )
      }

      Section("Picture in Picture") {
        Button("Start PiP") {
          startPictureInPicture()
        }
        .accessibilityIdentifier(AccessibilityID.PiPDismissalValidation.startButton)
        .disabled(controller?.isPossible != true || controller?.isActive == true)

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPDismissalValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("PiP restore and close")
    .task { startPlayback() }
    .task(id: controller.map(ObjectIdentifier.init)) {
      lifecycleEvents.removeAll()
      restoreCount = 0
      guard let controller else { return }
      controller.onRestoreUserInterface = { answer in
        restoreCount += 1
        answer(true)
      }
      for await envelope in controller.pipEventEnvelopes {
        lifecycleEvents.append(envelope.event.dismissalQualificationName)
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

  private func startPictureInPicture() {
    guard let controller else { return }
    playbackError = nil
    guard controller.requestStart() == .accepted else {
      playbackError = "PiP start was not accepted"
      return
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

private enum DismissalRenderingPath: String {
  case native
  case direct
}

extension PiPEvent {
  fileprivate var dismissalQualificationName: String {
    switch self {
    case .willStart: "willStart"
    case .didStart: "didStart"
    case .willStop(let reason): "willStop:\(String(describing: reason))"
    case .didStop(let reason): "didStop:\(String(describing: reason))"
    case .failedToStart: "failedToStart"
    }
  }
}
