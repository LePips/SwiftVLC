import SwiftUI
import SwiftVLC

private let readMe = """
Qualifies native PiP subtitle and OSD composition on hardware. Select each \
subtitle track, enter PiP, and exercise pause/resume, seeks, and inline \
restore. Show the marquee while PiP is active to prove VLC OSD regions use \
the same path. Repeat with text, styled, bitmap, forced, live, HDR, and \
adaptive-resolution fixtures by replacing the configured `subtitled` URL.

Record an Instruments Energy Log and Metal System Trace for the no-overlay \
baseline and overlay run. Note CPU, GPU, thermal state, color/HDR changes, \
subtitle timing, geometry, and any transition frame that loses or duplicates \
the overlay.
"""

struct MatrixScreenH: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var pip: PiPController?
  @State private var log: [LogLine] = []
  @State private var marqueeVisible = false

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
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
          LabeledContent("Overlay support", value: String(describing: pip.overlaySupport))
            .accessibilityIdentifier("validation.matrixH.overlaySupport")
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

      subtitleTrackSection

      Section("Transitions") {
        Button("Seek −10 seconds") {
          let accepted = player.jump(by: .seconds(-10))
          append("jump(-10s) → \(accepted)")
        }
        Button("Seek +10 seconds") {
          let accepted = player.jump(by: .seconds(10))
          append("jump(+10s) → \(accepted)")
        }
        Button("Reload same media") {
          activate()
          append("reload() requested")
        }
      }

      Section {
        Toggle("Marquee", isOn: $marqueeVisible)
          .accessibilityIdentifier("validation.matrixH.marquee")
        LabeledContent(
          "Thermal state",
          value: String(describing: ProcessInfo.processInfo.thermalState)
        )
      } header: {
        Text("OSD")
      } footer: {
        Text("The marquee is a VLC subpicture, not a SwiftUI overlay.")
      }

      logSection

      ResultRecorderSection(screenID: "matrix-h")
    }
    .showcaseFormStyle()
    .navigationTitle("(h) Native PiP overlays")
    .task {
      activate()
      await observeEvents()
    }
    .onChange(of: marqueeVisible) { _, visible in
      if visible {
        player.withMarquee { marquee in
          marquee.show(
            text: "SwiftVLC native PiP OSD  %H:%M:%S",
            fontSize: 32,
            color: 0xFFD000,
            position: OverlayPosition.bottomRight.rawValue
          )
        }
      } else {
        player.withMarquee { $0.hide() }
      }
      append("marquee → \(visible)")
    }
    .onChange(of: pip?.isActive) { _, active in
      if let active {
        append("pip.isActive → \(active)")
      }
    }
    .onDisappear {
      player.withMarquee { $0.hide() }
      player.stop()
    }
  }

  private var subtitleTrackSection: some View {
    Section("Subtitle track") {
      if player.subtitleTracks.isEmpty {
        Text("No subtitle tracks yet")
          .foregroundStyle(.secondary)
      } else {
        Picker(
          "Track",
          selection: Binding(
            get: { player.selectedSubtitleTrack },
            set: { track in
              player.selectedSubtitleTrack = track
              append("subtitle → \(track?.name ?? "off")")
            }
          )
        ) {
          Text("Off").tag(Track?.none)
          ForEach(player.subtitleTracks) { track in
            Text(track.name).tag(Track?.some(track))
          }
        }
      }
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
      Text("Transition log")
    } footer: {
      if !log.isEmpty {
        Button("Clear log") { log.removeAll() }
      }
    }
  }

  private func activate() {
    guard let url = streams.subtitled else { return }
    do {
      try player.play(url: url)
      append("play() → subtitled")
    } catch {
      append("play() threw: \(error)")
    }
  }

  private func observeEvents() async {
    for await event in player.events {
      switch event {
      case .timeChanged, .positionChanged, .bufferingProgress:
        continue
      case .stateChanged(let state):
        append("state → \(state)")
      case .tracksChanged:
        append("tracks changed; subtitle → \(player.selectedSubtitleTrack?.name ?? "off")")
      default:
        append("\(event)")
      }
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
