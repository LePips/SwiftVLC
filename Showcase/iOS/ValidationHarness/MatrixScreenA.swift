import SwiftUI
import SwiftVLC

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
  @State private var log: [LogLine] = []

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  private var zapTargets: [(key: HarnessStreams.Key, url: URL)] {
    streams.configured.filter { [.liveTS, .hlsLive, .vod].contains($0.key) }
  }

  var body: some View {
    Form {
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
          LabeledContent("Possible", value: pip.isPossible ? "yes" : "no")
          LabeledContent("Active", value: pip.isActive ? "yes" : "no")
          LabeledContent("Continuity", value: continuityStatus)
            .accessibilityIdentifier("validation.matrixA.continuity")
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
    .onChange(of: pip?.isActive) { _, isActive in
      if let isActive {
        append("pip.isActive → \(isActive)")
      }
    }
    .onDisappear { player.stop() }
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
    try? player.play(url: target.url)
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
      continuityStatus = "\(event.outcome)"
      let detail = "continuity \(event.outcome): \(event.previousMediaGeneration) → "
        + "\(event.mediaGeneration), controller \(event.controllerGeneration), "
        + "elapsed \(event.elapsed)"
      append(detail)
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
