import Foundation
import SwiftUI
import SwiftVLC

private let readMe = """
`position` is a `Double` in `0.0...1.0`, bindable directly to a `Slider`. Seeks are \
async. `currentTime` updates continuously, and `duration` becomes non-nil once known.
"""

struct SeekingCase: View {
  @State private var player = Player()
  @State private var seekBurstTask: Task<Void, Never>?
  @State private var seekBurstIsRunning = false
  @State private var seekBurstStatus = "idle"
  @State private var seekBurstProgress = "0/13"
  @State private var seekBurstSnapshot = "none"
  @State private var seekBurstResult: String?
  @State private var seekBurstError: String?

  private static let seekBurstFastTargets = [
    0.72, 0.10, 0.75, 0.05, 0.50, 0.68,
    0.25, 0.74, 0.15, 0.65, 0.35, 0.70
  ]
  private static let seekBurstFinalTarget = 0.70

  var body: some View {
    Form {
      Section { AboutView(readMe: readMe) }

      Section {
        VideoView(player)
          .aspectRatio(16 / 9, contentMode: .fit)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.Seeking.videoView)
      } footer: {
        PlayPauseFooter(player: player)
          .accessibilityIdentifier(AccessibilityID.Seeking.playPauseButton)
      }

      Section("Position") {
        SeekBar(player: player)
      }

      if LaunchArguments.isUITestMode {
        seekBurstSection
      }
    }
    .showcaseFormStyle()
    .overlay(alignment: .topTrailing) {
      seekBurstEvidenceEndpoint
    }
    .navigationTitle("Seeking")
    .task { try? player.play(url: TestMedia.demo) }
    .onDisappear {
      seekBurstTask?.cancel()
      seekBurstTask = nil
      player.stop()
    }
  }

  private var seekBurstSection: some View {
    Section("Direct seek burst (UI tests)") {
      ForEach([20, 50, 100], id: \.self) { cadenceMilliseconds in
        Button("Run \(cadenceMilliseconds) ms burst") {
          startSeekBurst(cadenceMilliseconds: cadenceMilliseconds)
        }
        .accessibilityIdentifier(
          AccessibilityID.Seeking.seekBurstButton(
            cadenceMilliseconds: cadenceMilliseconds
          )
        )
        .disabled(!canRunSeekBurst)
      }

      HStack {
        Text("Status")
        Spacer()
        VStack(alignment: .trailing) {
          Text(seekBurstStatus)
            .foregroundStyle(.secondary)
            .accessibilityIdentifier(AccessibilityID.Seeking.seekBurstStatus)
        }
      }
      seekBurstValueRow(
        "Progress",
        value: seekBurstProgress,
        identifier: AccessibilityID.Seeking.seekBurstProgress
      )
      seekBurstValueRow(
        "Latest command",
        value: seekBurstSnapshot,
        identifier: AccessibilityID.Seeking.seekBurstSnapshot
      )

      if let seekBurstError {
        Text(seekBurstError)
          .foregroundStyle(.red)
          .accessibilityIdentifier(AccessibilityID.Seeking.seekBurstError)
      }
    }
  }

  /// A Form virtualizes off-screen rows. Keep the evidence endpoint outside
  /// that lazy hierarchy so XCUITest can always read a finished run without
  /// scroll position becoming part of the contract.
  @ViewBuilder
  private var seekBurstEvidenceEndpoint: some View {
    if LaunchArguments.isUITestMode {
      Text("Burst evidence")
        .font(.caption2)
        .padding(2)
        .background(.thinMaterial, in: Capsule())
        .accessibilityLabel(Text(seekBurstResult ?? "pending"))
        .accessibilityIdentifier(AccessibilityID.Seeking.seekBurstResult)
        .allowsHitTesting(false)
    }
  }

  private var canRunSeekBurst: Bool {
    !seekBurstIsRunning
      && player.state == .playing
      && player.duration != nil
      && player.isSeekable
  }

  private func seekBurstValueRow(
    _ title: String,
    value: String,
    identifier: String
  ) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }

  private func startSeekBurst(cadenceMilliseconds: Int) {
    guard canRunSeekBurst else { return }

    seekBurstTask?.cancel()
    seekBurstIsRunning = true
    seekBurstStatus = "running"
    seekBurstProgress = "0/13"
    seekBurstSnapshot = "none"
    seekBurstResult = nil
    seekBurstError = nil

    seekBurstTask = Task { @MainActor in
      await runSeekBurst(cadenceMilliseconds: cadenceMilliseconds)
      seekBurstIsRunning = false
      seekBurstTask = nil
    }
  }

  /// Issues the real strict seek calls inside the app process. XCUITest
  /// slider gestures take seconds each and therefore cannot exercise command
  /// coalescing at 20–100 ms cadence.
  private func runSeekBurst(cadenceMilliseconds: Int) async {
    guard let duration = player.duration else {
      seekBurstStatus = "fail"
      seekBurstError = "Duration disappeared before the burst began"
      return
    }

    let targets = Self.seekBurstFastTargets + [Self.seekBurstFinalTarget]
    let expectedTargetTimeMilliseconds = Int64(
      (Double(duration.milliseconds) * Self.seekBurstFinalTarget).rounded()
    )
    let startedAt = Date()
    let clock = ContinuousClock()
    let start = clock.now
    var commands: [SeekBurstCommand] = []
    var fastDispatchSpanMilliseconds: Int64 = 0

    for (index, target) in Self.seekBurstFastTargets.enumerated() {
      let scheduledOffset = Int64(index * cadenceMilliseconds)
      let deadline = start.advanced(by: .milliseconds(scheduledOffset))
      do {
        try await clock.sleep(until: deadline)
      } catch {
        return
      }

      let actualOffset = elapsedMilliseconds(from: start, to: clock.now)
      let callStart = clock.now
      var commandError: String?
      do {
        try player.seek(to: PlaybackPosition(target), fast: true)
      } catch {
        commandError = String(describing: error)
      }
      let callDuration = elapsedMilliseconds(from: callStart, to: clock.now)
      let command = captureSeekBurstCommand(
        id: index,
        target: target,
        fast: true,
        scheduledOffsetMilliseconds: scheduledOffset,
        actualOffsetMilliseconds: actualOffset,
        callDurationMilliseconds: callDuration,
        error: commandError
      )
      commands.append(command)
      seekBurstProgress = "\(commands.count)/13"
      seekBurstSnapshot = command.snapshot

      if let commandError {
        publishSeekBurstEvidence(
          outcome: "fail",
          cadenceMilliseconds: cadenceMilliseconds,
          startedAt: startedAt,
          targets: targets,
          commands: commands,
          fastDispatchSpanMilliseconds: elapsedMilliseconds(from: start, to: clock.now),
          recoveryMilliseconds: nil,
          expectedTargetTimeMilliseconds: expectedTargetTimeMilliseconds,
          baselineDecodedVideo: player.statistics?.decodedVideo ?? 0,
          baselineDisplayedPictures: player.statistics?.displayedPictures ?? 0,
          failure: "Fast seek \(index) failed to dispatch: \(commandError)"
        )
        return
      }
    }

    fastDispatchSpanMilliseconds = elapsedMilliseconds(from: start, to: clock.now)

    // A precise request immediately after the fast sequence is the normal
    // scrubber contract: intermediate fast seeks may coalesce, but this final
    // target must recover to playing video and an advancing native timeline.
    let preciseCallStart = clock.now
    let preciseActualOffset = elapsedMilliseconds(from: start, to: preciseCallStart)
    var preciseError: String?
    do {
      try player.seek(to: PlaybackPosition(Self.seekBurstFinalTarget), fast: false)
    } catch {
      preciseError = String(describing: error)
    }
    let preciseCallDuration = elapsedMilliseconds(from: preciseCallStart, to: clock.now)
    let preciseCommand = captureSeekBurstCommand(
      id: Self.seekBurstFastTargets.count,
      target: Self.seekBurstFinalTarget,
      fast: false,
      scheduledOffsetMilliseconds: Int64(
        (Self.seekBurstFastTargets.count - 1) * cadenceMilliseconds
      ),
      actualOffsetMilliseconds: preciseActualOffset,
      callDurationMilliseconds: preciseCallDuration,
      error: preciseError
    )
    commands.append(preciseCommand)
    seekBurstProgress = "13/13"
    seekBurstSnapshot = preciseCommand.snapshot

    let baselineStatistics = player.statistics
    let baselineDecodedVideo = baselineStatistics?.decodedVideo ?? 0
    let baselineDisplayedPictures = baselineStatistics?.displayedPictures ?? 0

    if let preciseError {
      publishSeekBurstEvidence(
        outcome: "fail",
        cadenceMilliseconds: cadenceMilliseconds,
        startedAt: startedAt,
        targets: targets,
        commands: commands,
        fastDispatchSpanMilliseconds: fastDispatchSpanMilliseconds,
        recoveryMilliseconds: nil,
        expectedTargetTimeMilliseconds: expectedTargetTimeMilliseconds,
        baselineDecodedVideo: baselineDecodedVideo,
        baselineDisplayedPictures: baselineDisplayedPictures,
        failure: "Final precise seek failed to dispatch: \(preciseError)"
      )
      return
    }

    let recoveryStart = clock.now
    let recoveryDeadline = recoveryStart.advanced(by: .seconds(10))
    var recoveryMilliseconds: Int64?

    while clock.now < recoveryDeadline {
      if Task.isCancelled {
        return
      }
      if
        seekBurstRecoverySucceeded(
          expectedTargetTimeMilliseconds: expectedTargetTimeMilliseconds,
          baselineDecodedVideo: baselineDecodedVideo,
          baselineDisplayedPictures: baselineDisplayedPictures
        ) {
        recoveryMilliseconds = elapsedMilliseconds(from: recoveryStart, to: clock.now)
        break
      }
      do {
        try await clock.sleep(for: .milliseconds(50))
      } catch {
        return
      }
    }

    let failure = recoveryMilliseconds == nil
      ? seekBurstRecoveryFailure(
        expectedTargetTimeMilliseconds: expectedTargetTimeMilliseconds,
        baselineDecodedVideo: baselineDecodedVideo,
        baselineDisplayedPictures: baselineDisplayedPictures
      )
      : nil
    publishSeekBurstEvidence(
      outcome: failure == nil ? "pass" : "fail",
      cadenceMilliseconds: cadenceMilliseconds,
      startedAt: startedAt,
      targets: targets,
      commands: commands,
      fastDispatchSpanMilliseconds: fastDispatchSpanMilliseconds,
      recoveryMilliseconds: recoveryMilliseconds,
      expectedTargetTimeMilliseconds: expectedTargetTimeMilliseconds,
      baselineDecodedVideo: baselineDecodedVideo,
      baselineDisplayedPictures: baselineDisplayedPictures,
      failure: failure
    )
  }

  private func captureSeekBurstCommand(
    id: Int,
    target: Double,
    fast: Bool,
    scheduledOffsetMilliseconds: Int64,
    actualOffsetMilliseconds: Int64,
    callDurationMilliseconds: Int64,
    error: String?
  ) -> SeekBurstCommand {
    SeekBurstCommand(
      id: id,
      target: target,
      fast: fast,
      scheduledOffsetMilliseconds: scheduledOffsetMilliseconds,
      actualOffsetMilliseconds: actualOffsetMilliseconds,
      callDurationMilliseconds: callDurationMilliseconds,
      error: error,
      publishedState: player.state.description,
      publishedTimeMilliseconds: player.currentTime.milliseconds,
      publishedPosition: player.position,
      publishedIsSeekable: player.isSeekable,
      publishedActiveVideoOutputs: player.activeVideoOutputs,
      publishedDidReachEnd: player.didReachEnd
    )
  }

  private func seekBurstRecoverySucceeded(
    expectedTargetTimeMilliseconds: Int64,
    baselineDecodedVideo: UInt64,
    baselineDisplayedPictures: UInt64
  ) -> Bool {
    let statistics = player.statistics
    let finalTime = player.currentTime.milliseconds
    return player.state == .playing
      && player.isPlaybackRequestedActive
      && player.isSeekable
      && !player.didReachEnd
      && player.activeVideoOutputs > 0
      && player.hasVideoOutput
      && (statistics?.decodedVideo ?? 0) > baselineDecodedVideo
      && (statistics?.displayedPictures ?? 0) > baselineDisplayedPictures
      && finalTime >= expectedTargetTimeMilliseconds + 250
      && finalTime <= expectedTargetTimeMilliseconds + 5000
  }

  private func seekBurstRecoveryFailure(
    expectedTargetTimeMilliseconds: Int64,
    baselineDecodedVideo: UInt64,
    baselineDisplayedPictures: UInt64
  ) -> String {
    let statistics = player.statistics
    let decoded = statistics?.decodedVideo ?? 0
    let displayed = statistics?.displayedPictures ?? 0
    return "Post-final recovery timed out: state=\(player.state), "
      + "intent=\(player.isPlaybackRequestedActive), seekable=\(player.isSeekable), "
      + "end=\(player.didReachEnd), vout=\(player.activeVideoOutputs), "
      + "hasVideo=\(player.hasVideoOutput), time=\(player.currentTime.milliseconds), "
      + "expected=\(expectedTargetTimeMilliseconds + 250)..."
      + "\(expectedTargetTimeMilliseconds + 5000), "
      + "decoded=\(decoded)-\(baselineDecodedVideo), "
      + "displayed=\(displayed)-\(baselineDisplayedPictures)"
  }

  private func publishSeekBurstEvidence(
    outcome: String,
    cadenceMilliseconds: Int,
    startedAt: Date,
    targets: [Double],
    commands: [SeekBurstCommand],
    fastDispatchSpanMilliseconds: Int64,
    recoveryMilliseconds: Int64?,
    expectedTargetTimeMilliseconds: Int64,
    baselineDecodedVideo: UInt64,
    baselineDisplayedPictures: UInt64,
    failure: String?
  ) {
    let statistics = player.statistics
    let decodedVideo = statistics?.decodedVideo ?? 0
    let displayedPictures = statistics?.displayedPictures ?? 0
    let evidence = SeekBurstEvidence(
      schemaVersion: 1,
      outcome: outcome,
      cadenceMilliseconds: cadenceMilliseconds,
      startedAt: startedAt,
      targets: targets,
      commands: commands,
      fastDispatchSpanMilliseconds: fastDispatchSpanMilliseconds,
      recoveryMilliseconds: recoveryMilliseconds,
      expectedTargetTimeMilliseconds: expectedTargetTimeMilliseconds,
      finalState: player.state.description,
      finalTimeMilliseconds: player.currentTime.milliseconds,
      finalPosition: player.position,
      finalIsPlaybackRequestedActive: player.isPlaybackRequestedActive,
      finalIsSeekable: player.isSeekable,
      finalDidReachEnd: player.didReachEnd,
      finalActiveVideoOutputs: player.activeVideoOutputs,
      finalHasVideoOutput: player.hasVideoOutput,
      decodedVideoDelta: counterDelta(decodedVideo, from: baselineDecodedVideo),
      displayedPicturesDelta: counterDelta(displayedPictures, from: baselineDisplayedPictures),
      failure: failure
    )

    guard let data = try? JSONEncoder().encode(evidence) else {
      seekBurstStatus = "fail"
      seekBurstError = "Could not encode seek burst evidence"
      return
    }
    seekBurstStatus = outcome
    seekBurstError = failure
    seekBurstResult = "\(outcome):\(data.base64EncodedString())"
  }

  private func counterDelta(_ value: UInt64, from baseline: UInt64) -> UInt64 {
    value >= baseline ? value - baseline : 0
  }

  private func elapsedMilliseconds(
    from start: ContinuousClock.Instant,
    to end: ContinuousClock.Instant
  ) -> Int64 {
    let components = start.duration(to: end).components
    return components.seconds * 1000
      + components.attoseconds / 1_000_000_000_000_000
  }
}

extension SeekBurstCommand {
  fileprivate var snapshot: String {
    let mode = fast ? "fast" : "precise"
    let errorSummary = error.map { " error=\($0)" } ?? ""
    return "#\(id) \(mode) target=\(String(format: "%.2f", target)) "
      + "at=\(actualOffsetMilliseconds)ms call=\(callDurationMilliseconds)ms "
      + "state=\(publishedState) time=\(publishedTimeMilliseconds)ms\(errorSummary)"
  }
}
