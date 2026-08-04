import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Physical-device fault-injection surface for PiP capability convergence.
///
/// Raw length and seekability callbacks are deliberately dropped. The only
/// path left for the controller to discover finite/seekable VOD and
/// unbounded/unseekable live media is Player's native-state polling.
struct PiPCapabilityValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var lifecycleEvents: [String] = []
  @State private var skipResult = "none"
  @State private var playbackError: String?
  @State private var isSuppressionEnabled = false

  private let streams = HarnessStreams.load()?.streams

  private var renderingPath: PiPCapabilityRenderingPath {
    PiPCapabilityRenderingPath(
      rawValue: LaunchArguments.pipRenderingPathValue ?? "native"
    ) ?? .native
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        videoSurface
          .frame(height: 240)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPCapabilityValidation.videoView)
      }

      Section("Media") {
        Button("Load finite VOD") { load(streams?.vod) }
          .accessibilityIdentifier(AccessibilityID.PiPCapabilityValidation.loadVODButton)
          .disabled(streams?.vod == nil)
        Button("Load unbounded live stream") { load(streams?.liveTS) }
          .accessibilityIdentifier(AccessibilityID.PiPCapabilityValidation.loadLiveButton)
          .disabled(streams?.liveTS == nil)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPCapabilityValidation.stateLabel
        )
        valueRow(
          "Media generation",
          value: player.playbackQualificationGeneration.description,
          identifier: AccessibilityID.PiPCapabilityValidation.generationLabel
        )
        valueRow(
          "Current time",
          value: String(player.currentTime.milliseconds),
          identifier: AccessibilityID.PiPCapabilityValidation.currentTimeLabel
        )
        valueRow(
          "Playback policy",
          value: playbackSnapshot,
          identifier: AccessibilityID.PiPCapabilityValidation.snapshotLabel
        )
        valueRow(
          "Raw event suppression",
          value: suppressionSnapshot,
          identifier: AccessibilityID.PiPCapabilityValidation.suppressionLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPCapabilityValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPCapabilityValidation.activeLabel
        )
        valueRow(
          "Lifecycle",
          value: lifecycleEvents.isEmpty ? "none" : lifecycleEvents.joined(separator: "|"),
          identifier: AccessibilityID.PiPCapabilityValidation.lifecycleEventsLabel
        )
        valueRow(
          "Skip result",
          value: skipResult,
          identifier: AccessibilityID.PiPCapabilityValidation.skipResultLabel
        )
      }

      Section("Picture in Picture") {
        Button(
          controller?.isActive == true ? "Stop PiP" : "Start PiP",
          systemImage: "pip",
          action: { controller?.toggle() }
        )
        .accessibilityIdentifier(AccessibilityID.PiPCapabilityValidation.toggleButton)
        .disabled(controller?.isPossible != true)

        Button("Skip forward 10 seconds", systemImage: "goforward.10") {
          performSkip()
        }
        .accessibilityIdentifier(AccessibilityID.PiPCapabilityValidation.skipForwardButton)
        .disabled(controller == nil)

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPCapabilityValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("PiP capability convergence")
    .task {
      player.suppressRawCapabilityEventsForQualification(true)
      isSuppressionEnabled = true
    }
    .task(id: controller.map(ObjectIdentifier.init)) {
      lifecycleEvents.removeAll()
      guard let controller else { return }
      for await envelope in controller.pipEventEnvelopes {
        lifecycleEvents.append(lifecycleName(envelope.event))
      }
    }
    .onDisappear {
      player.suppressRawCapabilityEventsForQualification(false)
      isSuppressionEnabled = false
      player.stop()
    }
  }

  @ViewBuilder
  private var videoSurface: some View {
    switch renderingPath {
    case .native:
      PiPVideoView(
        player,
        controller: $controller,
        startsAutomaticallyFromInline: false
      )
    case .direct:
      DirectPiPValidationSurface(player: player, controller: $controller)
    }
  }

  private var playbackSnapshot: String {
    guard let controller else { return "none" }
    let snapshot = controller.playbackQualificationSnapshot
    let duration = snapshot.durationMilliseconds == nil ? "unbounded" : "finite"
    let seekable = snapshot.isSeekable ? "seekable" : "unseekable"
    let controls = snapshot.requiresLinearPlayback ? "linear" : "interactive"
    return "\(duration):\(seekable):\(controls)"
  }

  private var suppressionSnapshot: String {
    let snapshot = player.rawCapabilityEventSuppressionSnapshot
    return "\(isSuppressionEnabled ? "enabled" : "disabled"):"
      + "\(snapshot.suppressedLengthEventCount):"
      + "\(snapshot.suppressedSeekableEventCount)"
  }

  private func load(_ url: URL?) {
    guard let url else {
      playbackError = "Missing validation stream"
      return
    }
    do {
      skipResult = "none"
      playbackError = nil
      try player.play(url: url)
    } catch {
      playbackError = String(describing: error)
    }
  }

  private func performSkip() {
    guard let controller else {
      skipResult = "failed:no-controller"
      return
    }
    let before = player.currentTime.milliseconds
    skipResult = "pending:\(before)"
    Task { @MainActor in
      let settled = await controller.performQualificationSkip(bySeconds: 10)
      let after = player.currentTime.milliseconds
      skipResult = "\(settled && after > before ? "pass" : "failed"):\(before):\(after)"
    }
  }

  private func lifecycleName(_ event: PiPEvent) -> String {
    switch event {
    case .willStart:
      "willStart"
    case .didStart:
      "didStart"
    case .willStop(let reason):
      "willStop:\(String(describing: reason))"
    case .didStop(let reason):
      "didStop:\(String(describing: reason))"
    case .failedToStart:
      "failedToStart"
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

private enum PiPCapabilityRenderingPath: String {
  case native
  case direct
}
