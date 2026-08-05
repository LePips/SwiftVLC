import SwiftUI
@_spi(Qualification) import SwiftVLC

private let readMe = """
Tap a channel button to start playback, then start PiP from the button \
below or by backgrounding the app. While the OS PiP window is up, zap \
between channels — every button issues a `load()` on the **same** \
`Player`. For each transition class (VOD→live, live→live, live→VOD) \
record whether the PiP window survives the zap and how long the picture \
gap or freeze lasts. The event log records the controller generation, \
outgoing and successor media generations, continuity outcome, and measured \
rebuild duration reported by SwiftVLC.
"""

struct MatrixScreenA: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var pip: PiPController?
  @State private var continuityStatus = "none"
  @State private var continuityEvents: [String] = []
  @State private var lifecycleEvents: [String] = []
  @State private var latestGeneration: PlaybackGeneration?
  @State private var replacementMeasurement = "none"
  @State private var replacementProbe: Task<Void, Never>?
  @State private var pendingReplacement: PendingReplacement?
  @State private var staleSuccessorMutations = 0
  @State private var hasLoadedMedia = false
  @State private var log: [LogLine] = []

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  private struct PendingReplacement {
    let stream: String
    let generation: PlaybackGeneration
    let startedAt: ContinuousClock.Instant
  }

  private var zapTargets: [(key: HarnessStreams.Key, url: URL)] {
    streams.configured.filter { [.liveTS, .hlsLive, .vod].contains($0.key) }
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      Section { AboutView(readMe: readMe) }

      Section {
        PiPVideoView(player, controller: $pip)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Picture in Picture") {
        if let pip {
          valueRow(
            "Possible",
            value: pip.isPossible ? "yes" : "no",
            identifier: AccessibilityID.PiPContinuityValidation.possibleLabel
          )
          valueRow(
            "Active",
            value: pip.isActive ? "yes" : "no",
            identifier: AccessibilityID.PiPContinuityValidation.activeLabel
          )
          valueRow(
            "Continuity",
            value: continuityStatus,
            identifier: "validation.matrixA.continuity"
          )
          Button(
            pip.isActive ? "Stop PiP" : "Start PiP",
            systemImage: "pip",
            action: { pip.toggle() }
          )
          .disabled(!pip.isPossible)
        } else {
          Text("Preparing…")
            .foregroundStyle(.secondary)
        }
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPContinuityValidation.stateLabel
        )
        valueRow(
          "Media generation",
          value: player.playbackQualificationGeneration.description,
          identifier: AccessibilityID.PiPContinuityValidation.generationLabel
        )
        valueRow(
          "Displayed pictures",
          value: String(player.statistics?.displayedPictures ?? 0),
          identifier: AccessibilityID.PiPContinuityValidation.displayedPicturesLabel
        )
        valueRow(
          "Played audio buffers",
          value: String(player.statistics?.playedAudioBuffers ?? 0),
          identifier: AccessibilityID.PiPContinuityValidation.playedAudioBuffersLabel
        )
        valueRow(
          "Playback snapshot",
          value: playbackSnapshot,
          identifier: AccessibilityID.PiPContinuityValidation.playbackSnapshotLabel
        )
        valueRow(
          "Native atomic snapshot",
          value: nativePlaybackSnapshot,
          identifier: AccessibilityID.PiPContinuityValidation.nativePlaybackSnapshotLabel
        )
        valueRow(
          "Continuity events",
          value: continuityEvents.isEmpty ? "none" : continuityEvents.joined(separator: "|"),
          identifier: AccessibilityID.PiPContinuityValidation.continuityEventsLabel
        )
        valueRow(
          "Lifecycle events",
          value: lifecycleEvents.isEmpty ? "none" : lifecycleEvents.joined(separator: "|"),
          identifier: AccessibilityID.PiPContinuityValidation.lifecycleEventsLabel
        )
        valueRow(
          "Replacement measurement",
          value: "\(replacementMeasurement):\(staleSuccessorMutations)",
          identifier: AccessibilityID.PiPContinuityValidation.replacementMeasurementLabel
        )
        valueRow(
          "Stale successor mutations",
          value: String(staleSuccessorMutations),
          identifier: AccessibilityID.PiPContinuityValidation.staleSuccessorMutationsLabel
        )
      }

      Section("Channel zap") {
        ForEach(zapTargets, id: \.key) { target in
          Button("Load \(target.key.rawValue)") {
            load(target)
          }
        }
      }

      logSection

      ResultRecorderSection(screenID: "matrix-a")
    }
    .showcaseFormStyle()
    .navigationTitle("(a) PiP survival")
    .toolbar {
      if LaunchArguments.isUITestMode {
        ToolbarItemGroup(placement: .bottomBar) {
          qualificationLoadButton(for: .vod)
          qualificationLoadButton(for: .liveTS)
        }
      }
    }
    .task { await observeEvents() }
    .task(id: pip.map(ObjectIdentifier.init)) {
      guard let pip else { return }
      await observeContinuityEvents(from: pip)
    }
    .task(id: pip.map(ObjectIdentifier.init)) {
      guard let pip else { return }
      for await envelope in pip.pipEventEnvelopes {
        lifecycleEvents.append(lifecycleName(envelope.event))
      }
    }
    .onChange(of: pip?.isActive) { _, isActive in
      if let isActive {
        append("pip.isActive → \(isActive)")
      }
    }
    .onDisappear {
      replacementProbe?.cancel()
      player.stop()
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    LabeledContent(title, value: value)
      .qualificationAccessibilityValue(value, title: title, identifier: identifier)
  }

  @ViewBuilder
  private func qualificationLoadButton(for key: HarnessStreams.Key) -> some View {
    if let target = zapTargets.first(where: { $0.key == key }) {
      Button("Load \(key.rawValue)") { load(target) }
        .accessibilityIdentifier(
          key == .vod
            ? AccessibilityID.PiPContinuityValidation.loadVODButton
            : AccessibilityID.PiPContinuityValidation.loadLiveTSButton
        )
    }
  }

  private func load(_ target: (key: HarnessStreams.Key, url: URL)) {
    append("load() → \(target.key.rawValue)")
    replacementProbe?.cancel()
    let replacementStartedAt = hasLoadedMedia ? ContinuousClock.now : nil
    do {
      try player.play(url: target.url)
      let generation = player.playbackQualificationGeneration
      latestGeneration = generation
      if let replacementStartedAt {
        pendingReplacement = PendingReplacement(
          stream: target.key.rawValue,
          generation: generation,
          startedAt: replacementStartedAt
        )
        replacementMeasurement = "pending:\(target.key.rawValue):\(generation)"
      } else {
        hasLoadedMedia = true
      }
    } catch {
      replacementMeasurement = "failed:\(error)"
      append("load() failed → \(error)")
    }
  }

  private var logSection: some View {
    Section {
      if log.isEmpty {
        Text("Waiting…")
          .foregroundStyle(.secondary)
      } else {
        ForEach(log) { entry in
          Text(entry.text)
            .font(.caption.monospaced())
        }
      }
    } header: {
      Text("Event log")
    } footer: {
      if !log.isEmpty {
        Button("Clear log") { log.removeAll() }
      }
    }
  }

  private func observeEvents() async {
    for await event in player.events {
      switch event {
      case .timeChanged, .positionChanged, .bufferingProgress:
        continue
      case .stateChanged(let state):
        append("state → \(state)")
      default:
        append("\(event)")
      }
    }
  }

  private func observeContinuityEvents(from pip: PiPController) async {
    for await event in pip.pipContinuityEvents {
      if let latestGeneration, event.mediaGeneration < latestGeneration {
        staleSuccessorMutations += 1
      }
      continuityStatus = "\(event.outcome)"
      let elapsedMilliseconds = Int(event.elapsed / .milliseconds(1))
      continuityEvents.append(
        "\(event.outcome):\(event.previousMediaGeneration):\(event.mediaGeneration):"
          + "\(event.controllerGeneration):\(elapsedMilliseconds)"
      )
      if case .restored = event.outcome {
        completeReplacementProbe(for: event.mediaGeneration)
      }
      let detail = "continuity \(event.outcome): \(event.previousMediaGeneration) → "
        + "\(event.mediaGeneration), controller \(event.controllerGeneration), "
        + "elapsed \(event.elapsed)"
      append(detail)
    }
  }

  private var playbackSnapshot: String {
    guard let pip else { return "none" }
    let snapshot = pip.playbackQualificationSnapshot
    let duration = snapshot.durationMilliseconds == nil ? "unbounded" : "finite"
    let seekable = snapshot.isSeekable ? "seekable" : "unseekable"
    let controls = snapshot.requiresLinearPlayback ? "linear" : "interactive"
    return "\(duration):\(seekable):\(controls)"
  }

  private var nativePlaybackSnapshot: String {
    guard let snapshot = pip?.nativePlaybackQualificationSnapshot else { return "none" }
    return "\(snapshot.mediaGeneration):\(snapshot.durationMilliseconds):"
      + "\(snapshot.currentTimeMilliseconds):\(snapshot.isSeekable ? "yes" : "no")"
  }

  private func completeReplacementProbe(for generation: PlaybackGeneration) {
    guard
      let pendingReplacement,
      pendingReplacement.generation == generation
    else { return }
    self.pendingReplacement = nil
    replacementProbe = Task { @MainActor in
      var videoGapMilliseconds: Int?
      var audioGapMilliseconds: Int?
      while pendingReplacement.startedAt.duration(to: .now) < .seconds(15) {
        guard
          !Task.isCancelled,
          player.playbackQualificationGeneration == generation
        else { return }
        let statistics = player.statistics
        let elapsed = Int(
          pendingReplacement.startedAt.duration(to: .now) / .milliseconds(1)
        )
        if videoGapMilliseconds == nil, statistics?.displayedPictures ?? 0 > 0 {
          videoGapMilliseconds = elapsed
        }
        if audioGapMilliseconds == nil, statistics?.playedAudioBuffers ?? 0 > 0 {
          audioGapMilliseconds = elapsed
        }
        if let videoGapMilliseconds, let audioGapMilliseconds {
          replacementMeasurement = "complete:\(pendingReplacement.stream):\(generation):"
            + "\(videoGapMilliseconds):\(audioGapMilliseconds)"
          return
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      replacementMeasurement = "timed-out:\(pendingReplacement.stream):\(generation)"
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

  private func append(_ text: String) {
    let timestamp = Date.now.formatted(
      .dateTime.hour().minute().second().secondFraction(.fractional(2))
    )
    log.insert(LogLine(text: "\(timestamp)  \(text)"), at: 0)
    if log.count > 200 {
      log.removeLast()
    }
  }
}
