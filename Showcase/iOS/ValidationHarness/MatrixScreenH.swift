import SwiftUI
@_spi(Qualification) import SwiftVLC

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
  @State private var unexpectedStopCount = 0
  @State private var forwardSeekResult = "not-run"
  @State private var backwardSeekResult = "not-run"
  @State private var absoluteSeekResult = "not-run"
  @State private var seekQualificationOrdinal: UInt64 = 0
  @State private var seekQualificationTask: Task<Void, Never>?

  private struct LogLine: Identifiable {
    let id = UUID()
    let text: String
  }

  private enum SeekQualificationKind: String, Codable {
    case forward
    case backward
    case absolute
  }

  private struct PiPOutputIdentityEvidence: Codable, Equatable {
    let nativeHandleIdentity: UInt64
    let playbackGeneration: UInt64
    let outputIdentity: UInt64

    init(_ snapshot: NativePiPOutputIdentityQualificationSnapshot) {
      nativeHandleIdentity = snapshot.nativeHandleIdentity
      playbackGeneration = snapshot.playbackGeneration
      outputIdentity = snapshot.outputIdentity
    }
  }

  private struct SeekQualificationEvidence: Codable {
    let formatVersion: Int
    let command: SeekQualificationKind
    let outcome: String
    let accepted: Bool
    let mediaGeneration: UInt64?
    let durationMilliseconds: Int64?
    let baselineNativeTimeMilliseconds: Int64?
    let expectedTimeMilliseconds: Int64?
    let landingToleranceMilliseconds: Int64?
    let landingNativeTimeMilliseconds: Int64?
    let postCommandDisplayedPictures: UInt64
    let displayedPicturesAtLanding: UInt64?
    let finalDisplayedPictures: UInt64
    let commandToRecoveryMilliseconds: Int?
    let baselinePiPOutputIdentity: PiPOutputIdentityEvidence?
    let landingPiPOutputIdentity: PiPOutputIdentityEvidence?
    let failure: String?
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
            .qualificationAccessibilityValue(
              label: "Possible",
              value: pip.isPossible ? "yes" : "no",
              identifier: "validation.matrixH.possible"
            )
          LabeledContent("Active", value: pip.isActive ? "yes" : "no")
            .qualificationAccessibilityValue(
              label: "Active",
              value: pip.isActive ? "yes" : "no",
              identifier: AccessibilityID.MatrixHValidation.activeLabel
            )
          LabeledContent("Overlay support", value: String(describing: pip.overlaySupport))
            .qualificationAccessibilityValue(
              label: "Overlay support",
              value: String(describing: pip.overlaySupport),
              identifier: "validation.matrixH.overlaySupport"
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
        LabeledContent("Playback", value: String(describing: player.state))
          .qualificationAccessibilityValue(
            label: "Playback",
            value: String(describing: player.state),
            identifier: AccessibilityID.MatrixHValidation.stateLabel
          )
        LabeledContent("Current time", value: player.currentTime.formatted)
          .qualificationAccessibilityValue(
            label: "Current time",
            value: String(player.currentTime.milliseconds),
            identifier: AccessibilityID.MatrixHValidation.currentTimeLabel
          )
        LabeledContent(
          "Displayed pictures",
          value: String(player.statistics?.displayedPictures ?? 0)
        )
        .qualificationAccessibilityValue(
          label: "Displayed pictures",
          value: String(player.statistics?.displayedPictures ?? 0),
          identifier: AccessibilityID.MatrixHValidation.displayedPicturesLabel
        )
        LabeledContent("Unexpected PiP stops", value: String(unexpectedStopCount))
          .qualificationAccessibilityValue(
            label: "Unexpected PiP stops",
            value: String(unexpectedStopCount),
            identifier: AccessibilityID.MatrixHValidation.unexpectedStopCountLabel
          )
        LabeledContent("Forward seek", value: resultSummary(forwardSeekResult))
          .qualificationAccessibilityValue(
            label: "Forward seek",
            value: forwardSeekResult,
            identifier: AccessibilityID.MatrixHValidation.forwardResultLabel
          )
        LabeledContent("Backward seek", value: resultSummary(backwardSeekResult))
          .qualificationAccessibilityValue(
            label: "Backward seek",
            value: backwardSeekResult,
            identifier: AccessibilityID.MatrixHValidation.backwardResultLabel
          )
        LabeledContent("Absolute seek", value: resultSummary(absoluteSeekResult))
          .qualificationAccessibilityValue(
            label: "Absolute seek",
            value: absoluteSeekResult,
            identifier: AccessibilityID.MatrixHValidation.absoluteResultLabel
          )
      }

      subtitleTrackSection

      Section("Transitions") {
        Button("Seek −10 seconds") {
          beginSeekQualification(.backward)
        }
        .accessibilityIdentifier(AccessibilityID.MatrixHValidation.seekBackwardButton)
        Button("Seek +10 seconds") {
          beginSeekQualification(.forward)
        }
        .accessibilityIdentifier(AccessibilityID.MatrixHValidation.seekForwardButton)
        Button("Seek to 50%") {
          beginSeekQualification(.absolute)
        }
        .accessibilityIdentifier(AccessibilityID.MatrixHValidation.seekAbsoluteButton)
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
    .task(id: pip == nil) {
      guard let pip else { return }
      for await event in pip.pipEvents {
        if case .didStop = event {
          unexpectedStopCount += 1
        }
      }
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
      seekQualificationTask?.cancel()
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
    seekQualificationTask?.cancel()
    seekQualificationOrdinal &+= 1
    guard let url = streams.subtitled else { return }
    do {
      try player.play(url: url)
      append("play() → subtitled")
    } catch {
      append("play() threw: \(error)")
    }
  }

  /// Captures the native clock and decoder counter at command dispatch, then
  /// publishes success only after the native atomic clock lands near the
  /// requested target and a frame strictly newer than the post-command
  /// decoder baseline is displayed.
  private func beginSeekQualification(_ command: SeekQualificationKind) {
    seekQualificationTask?.cancel()
    seekQualificationOrdinal &+= 1
    let ordinal = seekQualificationOrdinal
    let displayedBeforeCommand = player.statistics?.displayedPictures ?? 0
    guard
      let pip,
      let baseline = pip.nativePlaybackQualificationSnapshot,
      let baselinePiPOutput = pip.nativeOutputIdentityQualificationSnapshot,
      baseline.durationMilliseconds > 0,
      baseline.currentTimeMilliseconds >= 0,
      baseline.isSeekable,
      baselinePiPOutput.nativeHandleIdentity != 0,
      baselinePiPOutput.playbackGeneration == baseline.mediaGeneration,
      baselinePiPOutput.outputIdentity != 0
    else {
      publishSeekEvidence(
        SeekQualificationEvidence(
          formatVersion: 1,
          command: command,
          outcome: "failed",
          accepted: false,
          mediaGeneration: nil,
          durationMilliseconds: nil,
          baselineNativeTimeMilliseconds: nil,
          expectedTimeMilliseconds: nil,
          landingToleranceMilliseconds: nil,
          landingNativeTimeMilliseconds: nil,
          postCommandDisplayedPictures: displayedBeforeCommand,
          displayedPicturesAtLanding: nil,
          finalDisplayedPictures: displayedBeforeCommand,
          commandToRecoveryMilliseconds: nil,
          baselinePiPOutputIdentity: nil,
          landingPiPOutputIdentity: nil,
          failure: "native playback snapshot was unavailable or unseekable"
        )
      )
      return
    }

    let expectedTime: Int64
    let accepted: Bool
    let started = ContinuousClock.now
    switch command {
    case .forward:
      expectedTime = min(
        baseline.durationMilliseconds,
        baseline.currentTimeMilliseconds + 10000
      )
      accepted = player.jump(by: .seconds(10))
    case .backward:
      expectedTime = max(0, baseline.currentTimeMilliseconds - 10000)
      accepted = player.jump(by: .seconds(-10))
    case .absolute:
      expectedTime = baseline.durationMilliseconds / 2
      accepted = player.seek(toPosition: 0.5)
    }
    let postCommandDisplayed = player.statistics?.displayedPictures
    let tolerance = max(
      1500,
      min(3000, baseline.durationMilliseconds / 20)
    )
    append(
      "seek \(command.rawValue) → \(accepted); native="
        + "\(baseline.currentTimeMilliseconds) expected=\(expectedTime); "
        + "displayed=\(displayedBeforeCommand)/"
        + "\(postCommandDisplayed.map { String($0) } ?? "unavailable")"
    )
    guard accepted else {
      publishSeekEvidence(
        SeekQualificationEvidence(
          formatVersion: 1,
          command: command,
          outcome: "failed",
          accepted: false,
          mediaGeneration: baseline.mediaGeneration,
          durationMilliseconds: baseline.durationMilliseconds,
          baselineNativeTimeMilliseconds: baseline.currentTimeMilliseconds,
          expectedTimeMilliseconds: expectedTime,
          landingToleranceMilliseconds: tolerance,
          landingNativeTimeMilliseconds: nil,
          postCommandDisplayedPictures: postCommandDisplayed ?? 0,
          displayedPicturesAtLanding: nil,
          finalDisplayedPictures: postCommandDisplayed ?? 0,
          commandToRecoveryMilliseconds: nil,
          baselinePiPOutputIdentity: PiPOutputIdentityEvidence(baselinePiPOutput),
          landingPiPOutputIdentity: nil,
          failure: "seek command was rejected"
        )
      )
      return
    }
    guard let postCommandDisplayed else {
      publishSeekEvidence(
        SeekQualificationEvidence(
          formatVersion: 1,
          command: command,
          outcome: "failed",
          accepted: true,
          mediaGeneration: baseline.mediaGeneration,
          durationMilliseconds: baseline.durationMilliseconds,
          baselineNativeTimeMilliseconds: baseline.currentTimeMilliseconds,
          expectedTimeMilliseconds: expectedTime,
          landingToleranceMilliseconds: tolerance,
          landingNativeTimeMilliseconds: nil,
          postCommandDisplayedPictures: 0,
          displayedPicturesAtLanding: nil,
          finalDisplayedPictures: 0,
          commandToRecoveryMilliseconds: nil,
          baselinePiPOutputIdentity: PiPOutputIdentityEvidence(baselinePiPOutput),
          landingPiPOutputIdentity: nil,
          failure: "decoder statistics were unavailable after seek dispatch"
        )
      )
      return
    }
    let displacement = abs(expectedTime - baseline.currentTimeMilliseconds)
    let targetCanProveTheCommand = switch command {
    case .forward, .backward:
      displacement == 10000
    case .absolute:
      displacement > tolerance + 5000
    }
    guard targetCanProveTheCommand else {
      publishSeekEvidence(
        SeekQualificationEvidence(
          formatVersion: 1,
          command: command,
          outcome: "failed",
          accepted: true,
          mediaGeneration: baseline.mediaGeneration,
          durationMilliseconds: baseline.durationMilliseconds,
          baselineNativeTimeMilliseconds: baseline.currentTimeMilliseconds,
          expectedTimeMilliseconds: expectedTime,
          landingToleranceMilliseconds: tolerance,
          landingNativeTimeMilliseconds: nil,
          postCommandDisplayedPictures: postCommandDisplayed,
          displayedPicturesAtLanding: nil,
          finalDisplayedPictures: postCommandDisplayed,
          commandToRecoveryMilliseconds: nil,
          baselinePiPOutputIdentity: PiPOutputIdentityEvidence(baselinePiPOutput),
          landingPiPOutputIdentity: nil,
          failure: "seek target was too close to distinguish dispatch from ordinary playback"
        )
      )
      return
    }

    seekQualificationTask = Task { @MainActor in
      // The release gate's recovery budget is five seconds. Keeping the
      // in-app deadline identical also prevents an ignored +10s command from
      // looking successful merely because ordinary playback reaches the
      // lower edge of the landing tolerance several seconds later.
      let deadline = started + .seconds(5)
      var finalTime: Int64?
      var finalDisplayed = postCommandDisplayed
      var landingFrameGate = HLSSeekLandingFrameGate()
      while !Task.isCancelled, ContinuousClock.now < deadline {
        guard ordinal == seekQualificationOrdinal else { return }
        guard
          let currentPiPOutput = pip.nativeOutputIdentityQualificationSnapshot,
          currentPiPOutput == baselinePiPOutput
        else {
          publishSeekEvidence(
            SeekQualificationEvidence(
              formatVersion: 1,
              command: command,
              outcome: "failed",
              accepted: true,
              mediaGeneration: baseline.mediaGeneration,
              durationMilliseconds: baseline.durationMilliseconds,
              baselineNativeTimeMilliseconds: baseline.currentTimeMilliseconds,
              expectedTimeMilliseconds: expectedTime,
              landingToleranceMilliseconds: tolerance,
              landingNativeTimeMilliseconds: finalTime,
              postCommandDisplayedPictures: postCommandDisplayed,
              displayedPicturesAtLanding: landingFrameGate.displayedPicturesAtLanding,
              finalDisplayedPictures: finalDisplayed,
              commandToRecoveryMilliseconds: nil,
              baselinePiPOutputIdentity: PiPOutputIdentityEvidence(baselinePiPOutput),
              landingPiPOutputIdentity: pip.nativeOutputIdentityQualificationSnapshot.map(
                PiPOutputIdentityEvidence.init
              ),
              failure: "native PiP output identity changed or became unready during seek"
            )
          )
          return
        }
        if
          let snapshot = pip.nativePlaybackQualificationSnapshot,
          snapshot.mediaGeneration == baseline.mediaGeneration,
          snapshot.currentTimeMilliseconds >= 0 {
          finalTime = snapshot.currentTimeMilliseconds
          guard let displayedPictures = player.statistics?.displayedPictures else {
            try? await Task.sleep(for: .milliseconds(50))
            continue
          }
          finalDisplayed = displayedPictures
          if
            landingFrameGate.observe(
              nativeTimeMilliseconds: snapshot.currentTimeMilliseconds,
              expectedTimeMilliseconds: expectedTime,
              toleranceMilliseconds: tolerance,
              displayedPictures: displayedPictures
            ) {
            let elapsed = Int(started.duration(to: .now) / .milliseconds(1))
            publishSeekEvidence(
              SeekQualificationEvidence(
                formatVersion: 1,
                command: command,
                outcome: "pass",
                accepted: true,
                mediaGeneration: baseline.mediaGeneration,
                durationMilliseconds: baseline.durationMilliseconds,
                baselineNativeTimeMilliseconds: baseline.currentTimeMilliseconds,
                expectedTimeMilliseconds: expectedTime,
                landingToleranceMilliseconds: tolerance,
                landingNativeTimeMilliseconds:
                landingFrameGate.landingNativeTimeMilliseconds,
                postCommandDisplayedPictures: postCommandDisplayed,
                displayedPicturesAtLanding:
                landingFrameGate.displayedPicturesAtLanding,
                finalDisplayedPictures: finalDisplayed,
                commandToRecoveryMilliseconds: elapsed,
                baselinePiPOutputIdentity: PiPOutputIdentityEvidence(baselinePiPOutput),
                landingPiPOutputIdentity: PiPOutputIdentityEvidence(currentPiPOutput),
                failure: nil
              )
            )
            return
          }
        }
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard !Task.isCancelled, ordinal == seekQualificationOrdinal else { return }
      publishSeekEvidence(
        SeekQualificationEvidence(
          formatVersion: 1,
          command: command,
          outcome: "failed",
          accepted: true,
          mediaGeneration: baseline.mediaGeneration,
          durationMilliseconds: baseline.durationMilliseconds,
          baselineNativeTimeMilliseconds: baseline.currentTimeMilliseconds,
          expectedTimeMilliseconds: expectedTime,
          landingToleranceMilliseconds: tolerance,
          landingNativeTimeMilliseconds:
          landingFrameGate.landingNativeTimeMilliseconds ?? finalTime,
          postCommandDisplayedPictures: postCommandDisplayed,
          displayedPicturesAtLanding: landingFrameGate.displayedPicturesAtLanding,
          finalDisplayedPictures: finalDisplayed,
          commandToRecoveryMilliseconds: nil,
          baselinePiPOutputIdentity: PiPOutputIdentityEvidence(baselinePiPOutput),
          landingPiPOutputIdentity: pip.nativeOutputIdentityQualificationSnapshot.map(
            PiPOutputIdentityEvidence.init
          ),
          failure: "native landing or strictly post-landing displayed frame timed out"
        )
      )
    }
  }

  private func publishSeekEvidence(_ evidence: SeekQualificationEvidence) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encoded = (try? encoder.encode(evidence).base64EncodedString()) ?? "encoding-failed"
    let value = "\(evidence.outcome):\(encoded)"
    switch evidence.command {
    case .forward:
      forwardSeekResult = value
    case .backward:
      backwardSeekResult = value
    case .absolute:
      absoluteSeekResult = value
    }
  }

  private func resultSummary(_ value: String) -> String {
    if value.hasPrefix("pass:") {
      return "pass"
    }
    if value.hasPrefix("failed:") {
      return "failed"
    }
    return value
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
