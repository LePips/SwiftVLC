import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound cadence matrix. SpringBoard resize gestures are supplied
/// by the UI test while the app owns media/rate/pause/replacement transitions
/// and samples the exact direct-renderer timing state.
struct PiPCadenceValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var result = "not-run"
  @State private var progress = "0s"
  @State private var activeProfile = "idle"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let durationSeconds = max(1, LaunchArguments.pipCadenceDurationValue ?? 600)
  private let baseURL = LaunchArguments.pipCadenceBaseURLValue

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        DirectPiPValidationSurface(player: player, controller: $controller)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPCadenceValidation.videoView)
      }
      Section("Measured state") {
        valueRow(
          "Playback", value: String(describing: player.state),
          identifier: AccessibilityID.PiPCadenceValidation.stateLabel
        )
        valueRow(
          "PiP possible", value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPCadenceValidation.possibleLabel
        )
        valueRow(
          "PiP active", value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPCadenceValidation.activeLabel
        )
        valueRow(
          "Elapsed", value: progress, identifier: AccessibilityID.PiPCadenceValidation.progressLabel
        )
        valueRow(
          "Cadence", value: activeProfile,
          identifier: AccessibilityID.PiPCadenceValidation.profileLabel
        )
        valueRow(
          "Qualification", value: result,
          identifier: AccessibilityID.PiPCadenceValidation.resultLabel
        )
      }
      Section("Cadence matrix") {
        Button("Run ten-minute cadence matrix") { Task { await run() } }
          .accessibilityIdentifier(AccessibilityID.PiPCadenceValidation.runButton)
          .disabled(isRunning || baseURL == nil || controller == nil)
        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPCadenceValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Direct PiP cadence")
    .onDisappear {
      controller?.stop()
      player.stop()
    }
  }

  private func run() async {
    guard let controller, baseURL != nil else { return }
    isRunning = true
    playbackError = nil
    result = "running"
    defer { isRunning = false }
    do {
      let started = ProcessInfo.processInfo.systemUptime
      var metrics: [CadencePresentationMetric] = []
      var samples: [CadenceSample] = []
      var fabricatedDurationCount = 0
      var monotonicityViolations = 0
      var rateChanges = 0
      var pauseResumeCycles = 0
      var replacements = 0
      var resizeTargets: [String] = []
      var lastPTSByGeneration: [UInt64: Double] = [:]
      var observedVmemOutputTimestampProvenance: String?

      for (index, profile) in CadenceProfile.allCases.enumerated() {
        guard Int(ProcessInfo.processInfo.systemUptime - started) < samplingDeadline else {
          throw CadenceFailure("Cadence sampling exceeded its bounded device window")
        }
        activeProfile = profile.evidenceName
        if index > 0 {
          replacements += 1
        }
        try play(profile)
        try await waitUntil("\(profile.evidenceName) did not start", timeout: .seconds(30)) {
          player.state == .playing && profile.matches(player.videoTracks)
        }
        if index == 0 {
          guard controller.requestStart() == .accepted else {
            throw CadenceFailure("Direct PiP start was not accepted")
          }
          try await waitUntil("Direct PiP did not become active", timeout: .seconds(30)) {
            controller.isActive
          }
        } else {
          try await waitUntil("PiP did not survive cadence replacement", timeout: .seconds(30)) {
            controller.isActive
          }
        }
        if index == 0 {
          // Give the XCTest process time to leave the app, locate the real
          // SpringBoard PiP surface, and begin its uptime-stamped pixel trace.
          try await Task.sleep(for: .seconds(20))
        }
        try await waitUntil(
          "Renderer published fabricated duration metadata", timeout: .seconds(15)
        ) {
          Self.rendererPublishesNoFabricatedDuration(controller: controller)
        }
        try await waitUntil("Native v6 output-attempt PTS was unavailable", timeout: .seconds(15)) {
          let snapshot = controller.timebaseDiagnosticSnapshot()
          return snapshot.vmemOutputTimestampProvenance
            == Self.vmemOutputTimestampProvenance
            && (snapshot.vmemOutputCallbackCount ?? 0) >= 2
        }

        let before = controller.timebaseDiagnosticSnapshot()

        player.pause()
        try await waitUntil("Cadence pause did not settle", timeout: .seconds(10)) {
          !player.isActive
        }
        try await Task.sleep(for: .seconds(2))
        player.resume()
        try await waitUntil("Cadence resume did not settle", timeout: .seconds(10)) {
          player.isActive
        }
        pauseResumeCycles += 1

        for rate in CadenceRate.allCases {
          guard
            Int(ProcessInfo.processInfo.systemUptime - started) + 10
            <= samplingDeadline
          else {
            throw CadenceFailure("Cadence sampling exceeded its bounded device window")
          }
          try player.setPlaybackRate(rate.playbackRate)
          rateChanges += 1
          activeProfile = "\(profile.evidenceName)@\(rate.evidenceName)x"
          try await waitUntil(
            "Cadence rate \(rate.evidenceName)x did not settle", timeout: .seconds(10)
          ) {
            abs(player.rate - rate.rawValue) < 0.001 && player.isActive
          }
          // Exclude the rate-change transient from the retained window.
          try await Task.sleep(for: .seconds(2))

          let first = try await makeSample(
            profile: profile,
            requestedRate: rate.rawValue,
            started: started,
            controller: controller,
            resizeTargets: &resizeTargets
          )
          try validate(
            sample: first,
            observedVmemOutputTimestampProvenance:
            &observedVmemOutputTimestampProvenance,
            lastPTSByGeneration: &lastPTSByGeneration,
            fabricatedDurationCount: &fabricatedDurationCount,
            monotonicityViolations: &monotonicityViolations
          )
          samples.append(first)

          try await Task.sleep(for: .seconds(5))

          let last = try await makeSample(
            profile: profile,
            requestedRate: rate.rawValue,
            started: started,
            controller: controller,
            resizeTargets: &resizeTargets
          )
          try validate(
            sample: last,
            observedVmemOutputTimestampProvenance:
            &observedVmemOutputTimestampProvenance,
            lastPTSByGeneration: &lastPTSByGeneration,
            fabricatedDurationCount: &fabricatedDurationCount,
            monotonicityViolations: &monotonicityViolations
          )
          guard
            last.playbackGeneration == first.playbackGeneration,
            last.requestedRate == first.requestedRate,
            last.effectivePlayerRate == first.effectivePlayerRate,
            (5...6).contains(last.elapsedSeconds - first.elapsedSeconds)
          else {
            throw CadenceFailure(
              "\(profile.evidenceName) \(rate.evidenceName)x window was not stable"
            )
          }
          samples.append(last)
          progress = "\(last.elapsedSeconds)s / \(durationSeconds)s"
        }

        try player.setPlaybackRate(.normal)
        rateChanges += 1
        let after = controller.timebaseDiagnosticSnapshot()
        let metric = try CadencePresentationMetric(
          profile: profile,
          before: before,
          after: after
        )
        guard metric.deliveredFrames > 0 else {
          throw CadenceFailure("\(profile.evidenceName) delivered no frames")
        }
        guard metric.presentationCopyFailures == 0, metric.displayConsumeFailures == 0 else {
          throw CadenceFailure("\(profile.evidenceName) reported a renderer failure")
        }
        metrics.append(metric)
      }

      guard metrics.count == CadenceProfile.allCases.count else {
        throw CadenceFailure("Cadence matrix ended before every source ran")
      }
      guard fabricatedDurationCount == 0 else {
        throw CadenceFailure("Renderer published fabricated duration metadata")
      }
      guard monotonicityViolations == 0 else {
        throw CadenceFailure("Presented time moved backward within a playback generation")
      }
      guard
        rateChanges >= CadenceProfile.allCases.count * 4,
        pauseResumeCycles >= CadenceProfile.allCases.count
      else {
        throw CadenceFailure("Rate or pause/resume transitions were incomplete")
      }

      var nextEnduranceSample = max(
        (samples.last?.elapsedSeconds ?? 0) + 1,
        Int(ProcessInfo.processInfo.systemUptime - started)
      )
      while Int(ProcessInfo.processInfo.systemUptime - started) < durationSeconds {
        try Task.checkCancellation()
        let elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
        progress = "\(elapsed)s / \(durationSeconds)s"
        if elapsed >= nextEnduranceSample {
          let sample = try await makeSample(
            profile: .vfr,
            requestedRate: 1,
            started: started,
            controller: controller,
            resizeTargets: &resizeTargets
          )
          try validate(
            sample: sample,
            observedVmemOutputTimestampProvenance:
            &observedVmemOutputTimestampProvenance,
            lastPTSByGeneration: &lastPTSByGeneration,
            fabricatedDurationCount: &fabricatedDurationCount,
            monotonicityViolations: &monotonicityViolations
          )
          samples.append(sample)
          nextEnduranceSample = sample.elapsedSeconds + 60
        } else {
          _ = recordRenderTarget(controller: controller, resizeTargets: &resizeTargets)
        }
        try await Task.sleep(for: .seconds(1))
      }
      guard controller.isActive else {
        throw CadenceFailure("Direct PiP stopped before the minimum duration")
      }
      let validTargets = Set(resizeTargets.filter { $0 != "0x0" })
      guard validTargets.count >= 2 else {
        throw CadenceFailure("Real PiP resize did not produce distinct render targets")
      }
      let completedDuration = Int(ProcessInfo.processInfo.systemUptime - started)
      if
        let lastElapsed = samples.last?.elapsedSeconds,
        completedDuration - lastElapsed > 6 {
        let finalSample = try await makeSample(
          profile: .vfr,
          requestedRate: 1,
          started: started,
          controller: controller,
          resizeTargets: &resizeTargets
        )
        try validate(
          sample: finalSample,
          observedVmemOutputTimestampProvenance:
          &observedVmemOutputTimestampProvenance,
          lastPTSByGeneration: &lastPTSByGeneration,
          fabricatedDurationCount: &fabricatedDurationCount,
          monotonicityViolations: &monotonicityViolations
        )
        samples.append(finalSample)
      }
      guard
        observedVmemOutputTimestampProvenance
        == Self.vmemOutputTimestampProvenance
      else {
        throw CadenceFailure("Native vmem output-attempt PTS telemetry was unavailable")
      }

      let evidence = CadenceEvidence(
        startedSystemUptime: started,
        durationSeconds: completedDuration,
        rates: [23.976, 24, 25, 29.97, 30, 50, 59.94, 60],
        vfr: true,
        sourceTimestampProvenance: Self.sourceTimestampProvenance,
        vmemOutputTimestampProvenance: Self.vmemOutputTimestampProvenance,
        presentationMetrics: metrics,
        transitionResults: CadenceTransitionResults(
          rateChanges: rateChanges,
          pauseResumeCycles: pauseResumeCycles,
          replacements: replacements,
          resizeCycles: max(0, resizeTargets.count - 1),
          resizeTargets: resizeTargets,
          monotonicityViolations: monotonicityViolations
        ),
        fabricatedDurationCount: fabricatedDurationCount,
        samples: samples
      )
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
      progress = "\(completedDuration)s / \(durationSeconds)s"
      activeProfile = "complete"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      controller.stop()
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private static let sourceTimestampProvenance =
    "libvlc-picture_t.date-native-callback-v1"
  private static let vmemOutputTimestampProvenance =
    "libvlc-vmem-post-filter-vout-selected-output-attempt-pts-v1"

  /// Leaves at least the final 200 seconds for SpringBoard resize qualification.
  /// A slow or stalled source fails instead of silently dropping rate windows.
  private var samplingDeadline: Int {
    max(1, min(400, durationSeconds - 200))
  }

  private func makeSample(
    profile: CadenceProfile,
    requestedRate: Float,
    started: TimeInterval,
    controller: PiPController,
    resizeTargets: inout [String]
  )
    async throws -> CadenceSample {
    let snapshot = try await settledSnapshot(controller: controller)
    let renderTarget = recordRenderTarget(
      controller: controller,
      resizeTargets: &resizeTargets
    )
    return try CadenceSample(
      profile: profile.evidenceName,
      requestedRate: requestedRate,
      elapsedSeconds: Int(snapshot.systemUptime - started),
      snapshot: snapshot,
      renderTarget: renderTarget
    )
  }

  /// Exact retained boundaries are sampled only when every begun v6 callback
  /// has a synchronous submitted/rejected outcome. This makes cumulative
  /// subtraction prove `callback == submitted + rejected` without guessing
  /// about a callback crossing the five-second boundary.
  private func settledSnapshot(
    controller: PiPController
  )
    async throws -> PiPTimebaseDiagnosticSnapshot {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while true {
      let snapshot = controller.timebaseDiagnosticSnapshot()
      if snapshot.vmemOutputInFlightCount == 0 {
        return snapshot
      }
      guard clock.now < deadline else {
        throw CadenceFailure("Could not capture a callback-conserved boundary")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func recordRenderTarget(
    controller: PiPController,
    resizeTargets: inout [String]
  ) -> String? {
    guard let renderer = controller.renderPerformanceQualificationSnapshot else {
      return nil
    }
    let target = "\(renderer.targetWidth ?? 0)x\(renderer.targetHeight ?? 0)"
    if resizeTargets.last != target {
      resizeTargets.append(target)
    }
    return target
  }

  private func validate(
    sample: CadenceSample,
    observedVmemOutputTimestampProvenance: inout String?,
    lastPTSByGeneration: inout [UInt64: Double],
    fabricatedDurationCount: inout Int,
    monotonicityViolations: inout Int
  )
    throws {
    if sample.vmemOutputTimestampProvenance != Self.vmemOutputTimestampProvenance {
      throw CadenceFailure("Native vmem output-attempt PTS telemetry was unavailable")
    }
    observedVmemOutputTimestampProvenance = sample.vmemOutputTimestampProvenance
    guard sample.hasConservedVmemOutputCounters else {
      throw CadenceFailure("Native vmem output-attempt counters were inconsistent")
    }
    guard abs(sample.effectivePlayerRate - sample.requestedRate) < 0.001 else {
      throw CadenceFailure("Effective libVLC rate differed from the requested rate")
    }
    if sample.durationValue != nil || sample.durationTimescale != nil {
      fabricatedDurationCount += 1
    }
    if
      let prior = lastPTSByGeneration[sample.playbackGeneration],
      sample.lastPTSSeconds + 0.001 < prior {
      monotonicityViolations += 1
    }
    lastPTSByGeneration[sample.playbackGeneration] = sample.lastPTSSeconds
  }

  private func play(_ profile: CadenceProfile) throws {
    guard let url = baseURL?.appending(path: "files/cadence/\(profile.fileName).mp4") else {
      throw CadenceFailure("Missing cadence origin")
    }
    let media = try Media(url: url)
    try player.play(media)
  }

  private static func rendererPublishesNoFabricatedDuration(
    controller: PiPController
  ) -> Bool {
    rendererPublishesNoFabricatedDuration(snapshot: controller.timebaseDiagnosticSnapshot())
  }

  private static func rendererPublishesNoFabricatedDuration(
    snapshot: PiPTimebaseDiagnosticSnapshot
  ) -> Bool {
    // libVLC exposes a nominal/average track ratio but the vmem callback does
    // not expose the duration of the individual decoded frame. The safe value
    // for CFR, VFR, and unknown inputs is therefore always `.invalid`; PTS
    // remains authoritative for scheduling.
    snapshot.frameDurationValue == nil && snapshot.frameDurationTimescale == nil
  }

  private func waitUntil(
    _ failure: String, timeout: Duration, condition: @escaping @MainActor () -> Bool
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw CadenceFailure(failure) }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value).foregroundStyle(.secondary).accessibilityIdentifier(identifier)
    }
  }
}

private enum CadenceProfile: CaseIterable {
  case fps23976, fps24, fps25, fps2997, fps30, fps50, fps5994, fps60, vfr

  var fileName: String {
    switch self {
    case .fps23976: "23_976"
    case .fps24: "24"
    case .fps25: "25"
    case .fps2997: "29_97"
    case .fps30: "30"
    case .fps50: "50"
    case .fps5994: "59_94"
    case .fps60: "60"
    case .vfr: "vfr"
    }
  }

  var evidenceName: String {
    self == .vfr ? "vfr-24-60" : fileName.replacingOccurrences(of: "_", with: ".")
  }

  var expectedRatio: (numerator: UInt32, denominator: UInt32)? {
    switch self {
    case .fps23976: (24000, 1001)
    case .fps24: (24, 1)
    case .fps25: (25, 1)
    case .fps2997: (30000, 1001)
    case .fps30: (30, 1)
    case .fps50: (50, 1)
    case .fps5994: (60000, 1001)
    case .fps60: (60, 1)
    case .vfr: nil
    }
  }

  func matches(_ tracks: [Track]) -> Bool {
    guard let ratio = (tracks.first(where: \.isSelected) ?? tracks.first)?.frameRateRatio else {
      return self == .vfr && !tracks.isEmpty
    }
    guard let expectedRatio else { return true }
    return ratio.numerator == expectedRatio.numerator
      && ratio.denominator == expectedRatio.denominator
  }
}

private enum CadenceRate: CaseIterable {
  case half, normal, double

  var playbackRate: PlaybackRate {
    switch self {
    case .half: .half
    case .normal: .normal
    case .double: .double
    }
  }

  var rawValue: Float {
    playbackRate.rawValue
  }

  var evidenceName: String {
    switch self {
    case .half: "0.5"
    case .normal: "1"
    case .double: "2"
    }
  }
}

private struct CadencePresentationMetric: Encodable {
  let profile: String
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let dropRate: Double
  let elapsedSeconds: Double
  let presentationRate: Double
  let backpressureEvents: UInt64
  let presentationCopyFailures: UInt64
  let displayConsumeFailures: UInt64
  let observedDurationValue: Int64?
  let observedDurationTimescale: Int32?

  init(
    profile: CadenceProfile, before: PiPTimebaseDiagnosticSnapshot,
    after: PiPTimebaseDiagnosticSnapshot
  )
    throws {
    guard
      after.playbackGeneration == before.playbackGeneration,
      after.deliveredFrameCount >= before.deliveredFrameCount,
      after.droppedFrameCount >= before.droppedFrameCount,
      after.vmemPoolUnavailableCount >= before.vmemPoolUnavailableCount,
      after.presentationCopyFailureCount >= before.presentationCopyFailureCount,
      after.vmemDisplayConsumeFailureCount >= before.vmemDisplayConsumeFailureCount,
      after.systemUptime >= before.systemUptime
    else {
      throw CadenceFailure(
        "\(profile.evidenceName) renderer counters reset inside one profile"
      )
    }
    self.profile = profile.evidenceName
    deliveredFrames = after.deliveredFrameCount - before.deliveredFrameCount
    droppedFrames = after.droppedFrameCount - before.droppedFrameCount
    let total = deliveredFrames.addingReportingOverflow(droppedFrames)
    guard !total.overflow else {
      throw CadenceFailure("\(profile.evidenceName) renderer frame total overflowed")
    }
    dropRate =
      total.partialValue > 0
        ? Double(droppedFrames) / Double(total.partialValue)
        : 1
    elapsedSeconds = after.systemUptime - before.systemUptime
    presentationRate = elapsedSeconds > 0 ? Double(deliveredFrames) / elapsedSeconds : 0
    backpressureEvents = after.vmemPoolUnavailableCount - before.vmemPoolUnavailableCount
    presentationCopyFailures =
      after.presentationCopyFailureCount - before.presentationCopyFailureCount
    displayConsumeFailures =
      after.vmemDisplayConsumeFailureCount - before.vmemDisplayConsumeFailureCount
    observedDurationValue = after.frameDurationValue
    observedDurationTimescale = after.frameDurationTimescale
  }
}

private struct CadenceSample: Encodable {
  let profile: String
  /// Legacy compatibility view. These counts are not decoded-source cadence.
  let sourceIntervalCounts: PiPSourceIntervalCounts
  let systemUptime: Double
  let elapsedSeconds: Int
  let playbackGeneration: UInt64
  let requestedRate: Float
  let effectivePlayerRate: Float
  let lastPTSSeconds: Double
  let durationValue: Int64?
  let durationTimescale: Int32?
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let backpressureEvents: UInt64
  let renderTarget: String?
  let vmemOutputTimestampProvenance: String
  let vmemOutputPlaybackGeneration: UInt64
  let vmemOutputVoutGeneration: UInt64
  let vmemOutputCallbackCount: UInt64
  let vmemOutputValidPTSCount: UInt64
  let vmemOutputInvalidPTSCount: UInt64
  let vmemOutputDuplicatePTSCount: UInt64
  let vmemOutputBackwardPTSCount: UInt64
  let vmemOutputDeltaOverflowCount: UInt64
  let vmemOutputSubmittedCount: UInt64
  let vmemOutputSwiftRejectedCount: UInt64
  let vmemOutputInFlightCount: UInt64
  let vmemOutputFirstPTSUS: Int64
  let vmemOutputLastPTSUS: Int64
  let vmemOutputFirstValidPTSUS: Int64
  let vmemOutputLastValidPTSUS: Int64
  let vmemOutputDeltaHistogram: [PiPVmemOutputPTSDeltaCount]
  let vmemOutputIntervalCounts: PiPVmemOutputIntervalCounts
  let libVLCDecodedVideoCount: UInt64
  let libVLCDisplayedPictureCount: UInt64
  let libVLCLostPictureCount: UInt64
  let libVLCLatePictureCount: UInt64

  private enum CodingKeys: String, CodingKey {
    case profile
    case sourceIntervalCounts
    case systemUptime
    case elapsedSeconds
    case playbackGeneration
    case requestedRate
    case effectivePlayerRate
    case lastPTSSeconds
    case durationValue
    case durationTimescale
    case deliveredFrames
    case droppedFrames
    case backpressureEvents
    case renderTarget
    case vmemOutputTimestampProvenance
    case vmemOutputPlaybackGeneration
    case vmemOutputVoutGeneration
    case vmemOutputCallbackCount
    case vmemOutputValidPTSCount
    case vmemOutputInvalidPTSCount
    case vmemOutputDuplicatePTSCount
    case vmemOutputBackwardPTSCount
    case vmemOutputDeltaOverflowCount
    case vmemOutputSubmittedCount
    case vmemOutputSwiftRejectedCount
    case vmemOutputInFlightCount
    case vmemOutputFirstPTSUS
    case vmemOutputLastPTSUS
    case vmemOutputFirstValidPTSUS
    case vmemOutputLastValidPTSUS
    case vmemOutputDeltaHistogram
    case vmemOutputIntervalCounts
    case libVLCDecodedVideoCount
    case libVLCDisplayedPictureCount
    case libVLCLostPictureCount
    case libVLCLatePictureCount
  }

  init(
    profile: String,
    requestedRate: Float,
    elapsedSeconds: Int,
    snapshot: PiPTimebaseDiagnosticSnapshot,
    renderTarget: String?
  )
    throws {
    guard
      let sourceIntervalCounts = snapshot.sourceIntervalCounts,
      let lastPTSSeconds = snapshot.lastDeliveredSampleTimeSeconds,
      lastPTSSeconds.isFinite,
      lastPTSSeconds >= 0,
      let vmemOutputTimestampProvenance = snapshot.vmemOutputTimestampProvenance,
      let vmemOutputPlaybackGeneration = snapshot.vmemOutputPlaybackGeneration,
      let vmemOutputVoutGeneration = snapshot.vmemOutputVoutGeneration,
      let vmemOutputCallbackCount = snapshot.vmemOutputCallbackCount,
      let vmemOutputValidPTSCount = snapshot.vmemOutputValidPTSCount,
      let vmemOutputInvalidPTSCount = snapshot.vmemOutputInvalidPTSCount,
      let vmemOutputDuplicatePTSCount = snapshot.vmemOutputDuplicatePTSCount,
      let vmemOutputBackwardPTSCount = snapshot.vmemOutputBackwardPTSCount,
      let vmemOutputDeltaOverflowCount = snapshot.vmemOutputDeltaOverflowCount,
      let vmemOutputSubmittedCount = snapshot.vmemOutputSubmittedCount,
      let vmemOutputSwiftRejectedCount = snapshot.vmemOutputSwiftRejectedCount,
      let vmemOutputInFlightCount = snapshot.vmemOutputInFlightCount,
      let vmemOutputFirstPTSUS = snapshot.vmemOutputFirstPTSUS,
      let vmemOutputLastPTSUS = snapshot.vmemOutputLastPTSUS,
      let vmemOutputFirstValidPTSUS = snapshot.vmemOutputFirstValidPTSUS,
      let vmemOutputLastValidPTSUS = snapshot.vmemOutputLastValidPTSUS,
      let vmemOutputDeltaHistogram = snapshot.vmemOutputDeltaHistogram,
      let vmemOutputIntervalCounts = snapshot.vmemOutputIntervalCounts,
      let libVLCDecodedVideoCount = snapshot.libVLCDecodedVideoCount,
      let libVLCDisplayedPictureCount = snapshot.libVLCDisplayedPictureCount,
      let libVLCLostPictureCount = snapshot.libVLCLostPictureCount,
      let libVLCLatePictureCount = snapshot.libVLCLatePictureCount
    else {
      throw CadenceFailure("Cadence sample lacked native vmem/runtime evidence")
    }
    self.profile = profile
    self.sourceIntervalCounts = sourceIntervalCounts
    systemUptime = snapshot.systemUptime
    self.elapsedSeconds = elapsedSeconds
    playbackGeneration = snapshot.playbackGeneration
    self.requestedRate = requestedRate
    effectivePlayerRate = snapshot.effectivePlayerRate
    self.lastPTSSeconds = lastPTSSeconds
    durationValue = snapshot.frameDurationValue
    durationTimescale = snapshot.frameDurationTimescale
    deliveredFrames = snapshot.deliveredFrameCount
    droppedFrames = snapshot.droppedFrameCount
    backpressureEvents = snapshot.vmemPoolUnavailableCount
    self.renderTarget = renderTarget
    self.vmemOutputTimestampProvenance = vmemOutputTimestampProvenance
    self.vmemOutputPlaybackGeneration = vmemOutputPlaybackGeneration
    self.vmemOutputVoutGeneration = vmemOutputVoutGeneration
    self.vmemOutputCallbackCount = vmemOutputCallbackCount
    self.vmemOutputValidPTSCount = vmemOutputValidPTSCount
    self.vmemOutputInvalidPTSCount = vmemOutputInvalidPTSCount
    self.vmemOutputDuplicatePTSCount = vmemOutputDuplicatePTSCount
    self.vmemOutputBackwardPTSCount = vmemOutputBackwardPTSCount
    self.vmemOutputDeltaOverflowCount = vmemOutputDeltaOverflowCount
    self.vmemOutputSubmittedCount = vmemOutputSubmittedCount
    self.vmemOutputSwiftRejectedCount = vmemOutputSwiftRejectedCount
    self.vmemOutputInFlightCount = vmemOutputInFlightCount
    self.vmemOutputFirstPTSUS = vmemOutputFirstPTSUS
    self.vmemOutputLastPTSUS = vmemOutputLastPTSUS
    self.vmemOutputFirstValidPTSUS = vmemOutputFirstValidPTSUS
    self.vmemOutputLastValidPTSUS = vmemOutputLastValidPTSUS
    self.vmemOutputDeltaHistogram = vmemOutputDeltaHistogram
    self.vmemOutputIntervalCounts = vmemOutputIntervalCounts
    self.libVLCDecodedVideoCount = libVLCDecodedVideoCount
    self.libVLCDisplayedPictureCount = libVLCDisplayedPictureCount
    self.libVLCLostPictureCount = libVLCLostPictureCount
    self.libVLCLatePictureCount = libVLCLatePictureCount
  }

  var hasConservedVmemOutputCounters: Bool {
    guard
      vmemOutputPlaybackGeneration == playbackGeneration,
      vmemOutputVoutGeneration > 0,
      vmemOutputInFlightCount == 0,
      Self.equalsSum(
        vmemOutputCallbackCount,
        vmemOutputValidPTSCount,
        vmemOutputInvalidPTSCount
      ),
      Self.equalsSum(
        vmemOutputCallbackCount,
        vmemOutputSubmittedCount,
        vmemOutputSwiftRejectedCount,
        vmemOutputInFlightCount
      ),
      vmemOutputInvalidPTSCount == 0,
      vmemOutputBackwardPTSCount == 0,
      vmemOutputDeltaOverflowCount == 0,
      vmemOutputFirstPTSUS == vmemOutputFirstValidPTSUS,
      vmemOutputLastPTSUS == vmemOutputLastValidPTSUS,
      vmemOutputFirstPTSUS <= vmemOutputLastPTSUS,
      vmemOutputValidPTSCount > 0,
      zip(vmemOutputDeltaHistogram, vmemOutputDeltaHistogram.dropFirst())
        .allSatisfy({ $0.deltaMicroseconds < $1.deltaMicroseconds }),
      vmemOutputDeltaHistogram.allSatisfy({ $0.count != .zero }),
      Self.histogramCount(vmemOutputDeltaHistogram)
      == vmemOutputValidPTSCount - 1,
      (vmemOutputDeltaHistogram.first {
        $0.deltaMicroseconds == 0
      }?.count ?? 0) == vmemOutputDuplicatePTSCount,
      Self.histogramCount(
        vmemOutputDeltaHistogram.filter { $0.deltaMicroseconds < 0 }
      ) == vmemOutputBackwardPTSCount
    else { return false }
    return true
  }

  private static func histogramCount(
    _ histogram: [PiPVmemOutputPTSDeltaCount]
  ) -> UInt64 {
    histogram.reduce(UInt64(0)) { partial, entry in
      let result = partial.addingReportingOverflow(entry.count)
      return result.overflow ? .max : result.partialValue
    }
  }

  private static func equalsSum(
    _ expected: UInt64,
    _ values: UInt64...
  ) -> Bool {
    var sum: UInt64 = 0
    for value in values {
      let result = sum.addingReportingOverflow(value)
      guard !result.overflow else { return false }
      sum = result.partialValue
    }
    return expected == sum
  }
}

private struct CadenceTransitionResults: Encodable {
  let rateChanges: Int
  let pauseResumeCycles: Int
  let replacements: Int
  let resizeCycles: Int
  let resizeTargets: [String]
  let monotonicityViolations: Int
}

private struct CadenceEvidence: Encodable {
  let startedSystemUptime: TimeInterval
  let durationSeconds: Int
  let rates: [Double]
  let vfr: Bool
  let sourceTimestampProvenance: String
  let vmemOutputTimestampProvenance: String
  let presentationMetrics: [CadencePresentationMetric]
  let transitionResults: CadenceTransitionResults
  let fabricatedDurationCount: Int
  let samples: [CadenceSample]
}

private struct CadenceFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
