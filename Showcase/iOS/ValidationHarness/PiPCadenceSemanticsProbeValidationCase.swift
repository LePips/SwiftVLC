import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Short, opt-in physical exploration of the actual vmem callback semantics.
///
/// This surface emits a report, never a qualification pass. It is intentionally
/// absent from the release matrix and candidate evidence collector.
struct PiPCadenceSemanticsProbeValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var result = "not-run"
  @State private var progress = "0 / \(ProbeScenario.all.count)"
  @State private var activeProfile = "idle"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let baseURL = LaunchArguments.pipCadenceBaseURLValue

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        DirectPiPValidationSurface(player: player, controller: $controller)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPCadenceSemanticsProbe.videoView)
      }
      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPCadenceSemanticsProbe.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPCadenceSemanticsProbe.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPCadenceSemanticsProbe.activeLabel
        )
        valueRow(
          "Progress",
          value: progress,
          identifier: AccessibilityID.PiPCadenceSemanticsProbe.progressLabel
        )
        valueRow(
          "Window",
          value: activeProfile,
          identifier: AccessibilityID.PiPCadenceSemanticsProbe.profileLabel
        )
        valueRow(
          "Report",
          value: result,
          identifier: AccessibilityID.PiPCadenceSemanticsProbe.resultLabel
        )
      }
      Section("Exploratory only") {
        Button("Run ~90-second cadence semantics probe") {
          Task { await run() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPCadenceSemanticsProbe.runButton)
        .disabled(isRunning || baseURL == nil || controller == nil)
        Text("This report is never accepted as release qualification evidence.")
          .font(.caption)
          .foregroundStyle(.secondary)
        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPCadenceSemanticsProbe.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("PiP cadence semantics probe")
    .onDisappear {
      controller?.stop()
      player.stop()
    }
  }

  private func run() async {
    guard let controller, let baseURL else { return }
    isRunning = true
    playbackError = nil
    result = "running"
    controller.enableFrameContentDiagnostics()
    defer { isRunning = false }

    do {
      let startedSystemUptime = ProcessInfo.processInfo.systemUptime
      var windows: [ProbeWindow] = []
      for (index, scenario) in ProbeScenario.all.enumerated() {
        activeProfile = scenario.name
        progress = "\(index) / \(ProbeScenario.all.count)"
        try play(scenario.profile, from: baseURL)
        try await waitUntil("\(scenario.profile.rawValue) did not start", timeout: .seconds(20)) {
          player.state == .playing && scenario.profile.matches(player.videoTracks)
        }

        if index == 0 {
          guard controller.requestStart() == .accepted else {
            throw ProbeFailure("Direct PiP start was not accepted")
          }
          try await waitUntil("Direct PiP did not become active", timeout: .seconds(30)) {
            controller.isActive
          }
          // Gives the XCTest process time to enter SpringBoard and establish
          // its fixed PiP crop before the first retained boundary.
          try await Task.sleep(for: .seconds(5))
        } else {
          try await waitUntil("PiP did not survive media replacement", timeout: .seconds(20)) {
            controller.isActive
          }
        }

        try player.setPlaybackRate(PlaybackRate(scenario.requestedRate))
        try await waitUntil("\(scenario.name) rate did not apply", timeout: .seconds(10)) {
          player.isActive && abs(player.rate - scenario.requestedRate) < 0.001
        }
        try await waitUntil("\(scenario.name) v6 output PTS was unavailable", timeout: .seconds(10)) {
          let snapshot = controller.timebaseDiagnosticSnapshot()
          return snapshot.vmemOutputTimestampProvenance == ProbeWindow.provenance
            && (snapshot.vmemOutputCallbackCount ?? 0) >= 2
        }

        // Exclude media/rate/vout transients from the retained window.
        try await Task.sleep(for: .seconds(2))
        let before = try await settledBoundary(controller: controller)
        try await Task.sleep(for: .seconds(5))
        let after = try await settledBoundary(controller: controller)
        try windows.append(
          ProbeWindow(
            scenario: scenario,
            before: before,
            after: after
          )
        )
        progress = "\(index + 1) / \(ProbeScenario.all.count)"
      }

      let endedSystemUptime = ProcessInfo.processInfo.systemUptime
      let report = ProbeReport(
        startedSystemUptime: startedSystemUptime,
        endedSystemUptime: endedSystemUptime,
        windows: windows
      )
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      result = try "report:\(encoder.encode(report).base64EncodedString())"
      activeProfile = "complete"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      controller.stop()
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func settledBoundary(
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
        throw ProbeFailure("Could not capture a callback-conserved boundary")
      }
      try await Task.sleep(for: .milliseconds(5))
    }
  }

  private func play(_ profile: PiPCadenceProbeProfile, from baseURL: URL) throws {
    let url = baseURL.appending(path: "files/cadence/\(profile.fileName).mp4")
    try player.play(Media(url: url))
  }

  private func waitUntil(
    _ failure: String,
    timeout: Duration,
    condition: @escaping @MainActor () -> Bool
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw ProbeFailure(failure) }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func valueRow(
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
}

private struct ProbeScenario: Sendable {
  let profile: PiPCadenceProbeProfile
  let requestedRate: Float

  var name: String {
    "\(profile.rawValue)@\(requestedRate)x"
  }

  static let all: [Self] = [
    .init(profile: .fps24, requestedRate: 0.5),
    .init(profile: .fps60, requestedRate: 1),
    .init(profile: .fps30, requestedRate: 2),
    .init(profile: .fps50, requestedRate: 2),
    .init(profile: .fps5994, requestedRate: 2),
    .init(profile: .fps60, requestedRate: 2),
    .init(profile: .vfr, requestedRate: 0.5),
    .init(profile: .vfr, requestedRate: 1),
    .init(profile: .vfr, requestedRate: 2)
  ]
}

extension PiPCadenceProbeProfile {
  fileprivate func matches(_ tracks: [Track]) -> Bool {
    guard let ratio = (tracks.first(where: \.isSelected) ?? tracks.first)?.frameRateRatio else {
      return self == .vfr && !tracks.isEmpty
    }
    switch self {
    case .fps23976:
      return ratio.numerator == 24000 && ratio.denominator == 1001
    case .fps24: return ratio.numerator == 24 && ratio.denominator == 1
    case .fps25: return ratio.numerator == 25 && ratio.denominator == 1
    case .fps2997:
      return ratio.numerator == 30000 && ratio.denominator == 1001
    case .fps30: return ratio.numerator == 30 && ratio.denominator == 1
    case .fps50: return ratio.numerator == 50 && ratio.denominator == 1
    case .fps5994: return ratio.numerator == 60000 && ratio.denominator == 1001
    case .fps60: return ratio.numerator == 60 && ratio.denominator == 1
    case .vfr: return true
    }
  }
}

private struct ProbeReport: Encodable {
  let formatVersion = 1
  let purpose = "exploratory-vmem-output-attempt-cadence-semantics"
  let releaseCreditEligible = false
  let vmemOutputTimestampProvenance = ProbeWindow.provenance
  let targetWindowSeconds = 5.0
  let settlingSeconds = 2.0
  let startedSystemUptime: Double
  let endedSystemUptime: Double
  let windows: [ProbeWindow]
}

private struct ProbeWindow: Encodable {
  static let provenance =
    "libvlc-vmem-post-filter-vout-selected-output-attempt-pts-v1"

  let profile: PiPCadenceProbeProfile
  let requestedRate: Float
  let windowStartSystemUptime: Double
  let windowEndSystemUptime: Double
  let windowDurationSeconds: Double
  let effectivePlayerRateStart: Float
  let effectivePlayerRateEnd: Float
  let controlTimebaseRateStart: Double?
  let controlTimebaseRateEnd: Double?
  let controlTimebaseDeltaSeconds: Double?
  let mediaTimeDeltaSeconds: Double
  let nativePTSDeltaSeconds: Double?
  let nativePTSDeltaMatchesHistogram: Bool?
  let nativePTSDeltaHistogram: [PiPCadenceProbeDeltaCount]
  let nativePTSClassification: PiPCadenceProbeMultipleClassification
  let outputCallbackCount: UInt64
  let validPTSCount: UInt64
  let invalidPTSCount: UInt64
  let submittedFrames: UInt64
  let swiftRejectedFrames: UInt64
  let inFlightStart: UInt64
  let inFlightEnd: UInt64
  let callbackConservationAtStart: Bool
  let callbackConservationAtEnd: Bool
  let callbackDeltaConservation: Bool
  let observedSubmissionFPS: Double
  let renderer: ProbeRendererDeltas
  let libVLC: ProbeLibVLCDeltas
  let before: PiPTimebaseDiagnosticSnapshot
  let after: PiPTimebaseDiagnosticSnapshot

  init(
    scenario: ProbeScenario,
    before: PiPTimebaseDiagnosticSnapshot,
    after: PiPTimebaseDiagnosticSnapshot
  )
    throws {
    guard
      before.vmemOutputTimestampProvenance == Self.provenance,
      after.vmemOutputTimestampProvenance == Self.provenance
    else { throw ProbeFailure("Native v6 output-attempt PTS was unavailable") }
    guard
      before.playbackGeneration == after.playbackGeneration,
      before.vmemOutputPlaybackGeneration == after.vmemOutputPlaybackGeneration,
      before.vmemOutputVoutGeneration == after.vmemOutputVoutGeneration
    else { throw ProbeFailure("Playback/vout generation changed inside retained window") }

    let callbackCount = try Self.delta(
      before.vmemOutputCallbackCount,
      after.vmemOutputCallbackCount,
      name: "output callback"
    )
    let validPTSCount = try Self.delta(
      before.vmemOutputValidPTSCount,
      after.vmemOutputValidPTSCount,
      name: "valid PTS"
    )
    let invalidPTSCount = try Self.delta(
      before.vmemOutputInvalidPTSCount,
      after.vmemOutputInvalidPTSCount,
      name: "invalid PTS"
    )
    let submitted = try Self.delta(
      before.vmemOutputSubmittedCount,
      after.vmemOutputSubmittedCount,
      name: "submitted callback"
    )
    let rejected = try Self.delta(
      before.vmemOutputSwiftRejectedCount,
      after.vmemOutputSwiftRejectedCount,
      name: "Swift-rejected callback"
    )
    let inFlightStart = try Self.require(
      before.vmemOutputInFlightCount,
      name: "start in-flight callback"
    )
    let inFlightEnd = try Self.require(
      after.vmemOutputInFlightCount,
      name: "end in-flight callback"
    )
    let histogram = try Self.histogramDelta(before: before, after: after)
    let overflow = try Self.delta(
      before.vmemOutputDeltaOverflowCount,
      after.vmemOutputDeltaOverflowCount,
      name: "PTS delta overflow"
    )
    let classification = PiPCadenceProbeDeltaAnalyzer.classify(
      profile: scenario.profile,
      histogram: histogram,
      deltaOverflowCount: overflow
    )
    let nativeDelta = Self.nativePTSDelta(before: before, after: after)
    let histogramSum = Self.weightedDeltaSum(histogram)

    profile = scenario.profile
    requestedRate = scenario.requestedRate
    windowStartSystemUptime = before.systemUptime
    windowEndSystemUptime = after.systemUptime
    windowDurationSeconds = after.systemUptime - before.systemUptime
    effectivePlayerRateStart = before.effectivePlayerRate
    effectivePlayerRateEnd = after.effectivePlayerRate
    controlTimebaseRateStart = before.controlTimebaseRate
    controlTimebaseRateEnd = after.controlTimebaseRate
    controlTimebaseDeltaSeconds = Self.finiteDelta(
      before.controlTimebaseSeconds,
      after.controlTimebaseSeconds
    )
    mediaTimeDeltaSeconds = after.mediaTimeSeconds - before.mediaTimeSeconds
    nativePTSDeltaSeconds = nativeDelta.map { Double($0) / 1_000_000 }
    nativePTSDeltaMatchesHistogram =
      switch (nativeDelta, histogramSum) {
      case (.some(let native), .some(let sum)): native == sum
      default: nil
      }
    nativePTSDeltaHistogram = histogram
    nativePTSClassification = classification
    outputCallbackCount = callbackCount
    self.validPTSCount = validPTSCount
    self.invalidPTSCount = invalidPTSCount
    submittedFrames = submitted
    swiftRejectedFrames = rejected
    self.inFlightStart = inFlightStart
    self.inFlightEnd = inFlightEnd
    callbackConservationAtStart = Self.isConserved(before)
    callbackConservationAtEnd = Self.isConserved(after)
    callbackDeltaConservation =
      inFlightStart == 0 && inFlightEnd == 0
        && Self.equalsSum(callbackCount, submitted, rejected)
    observedSubmissionFPS =
      windowDurationSeconds > 0
        ? Double(submitted) / windowDurationSeconds
        : 0
    renderer = try ProbeRendererDeltas(before: before, after: after)
    libVLC = ProbeLibVLCDeltas(before: before, after: after)
    self.before = before
    self.after = after
  }

  private static func histogramDelta(
    before: PiPTimebaseDiagnosticSnapshot,
    after: PiPTimebaseDiagnosticSnapshot
  )
    throws -> [PiPCadenceProbeDeltaCount] {
    guard
      let beforeValues = before.vmemOutputDeltaHistogram,
      let afterValues = after.vmemOutputDeltaHistogram
    else { throw ProbeFailure("PTS delta histogram was unavailable") }
    let beforeMap = Dictionary(
      uniqueKeysWithValues: beforeValues.map { ($0.deltaMicroseconds, $0.count) }
    )
    let afterMap = Dictionary(
      uniqueKeysWithValues: afterValues.map { ($0.deltaMicroseconds, $0.count) }
    )
    return try Set(beforeMap.keys).union(afterMap.keys).sorted().compactMap { delta in
      let first = beforeMap[delta, default: 0]
      let last = afterMap[delta, default: 0]
      guard last >= first else {
        throw ProbeFailure("PTS histogram moved backward for delta \(delta)")
      }
      let count = last - first
      return count > 0
        ? PiPCadenceProbeDeltaCount(deltaMicroseconds: delta, count: count)
        : nil
    }
  }

  private static func nativePTSDelta(
    before: PiPTimebaseDiagnosticSnapshot,
    after: PiPTimebaseDiagnosticSnapshot
  ) -> Int64? {
    guard
      let first = before.vmemOutputLastValidPTSUS,
      let last = after.vmemOutputLastValidPTSUS
    else { return nil }
    let result = last.subtractingReportingOverflow(first)
    return result.overflow ? nil : result.partialValue
  }

  private static func weightedDeltaSum(
    _ histogram: [PiPCadenceProbeDeltaCount]
  ) -> Int64? {
    var sum: Int64 = 0
    for entry in histogram {
      guard entry.count <= UInt64(Int64.max) else { return nil }
      let product = entry.deltaMicroseconds.multipliedReportingOverflow(
        by: Int64(entry.count)
      )
      guard !product.overflow else { return nil }
      let addition = sum.addingReportingOverflow(product.partialValue)
      guard !addition.overflow else { return nil }
      sum = addition.partialValue
    }
    return sum
  }

  private static func isConserved(_ value: PiPTimebaseDiagnosticSnapshot) -> Bool {
    guard
      let callbacks = value.vmemOutputCallbackCount,
      let submitted = value.vmemOutputSubmittedCount,
      let rejected = value.vmemOutputSwiftRejectedCount,
      let inFlight = value.vmemOutputInFlightCount
    else { return false }
    let first = submitted.addingReportingOverflow(rejected)
    guard !first.overflow else { return false }
    let second = first.partialValue.addingReportingOverflow(inFlight)
    return !second.overflow && callbacks == second.partialValue
  }

  private static func equalsSum(
    _ expected: UInt64,
    _ first: UInt64,
    _ second: UInt64
  ) -> Bool {
    let sum = first.addingReportingOverflow(second)
    return !sum.overflow && expected == sum.partialValue
  }

  fileprivate static func delta(
    _ before: UInt64?,
    _ after: UInt64?,
    name: String
  )
    throws -> UInt64 {
    let first = try require(before, name: "start \(name)")
    let last = try require(after, name: "end \(name)")
    guard last >= first else { throw ProbeFailure("\(name) counter moved backward") }
    return last - first
  }

  private static func require(_ value: UInt64?, name: String) throws -> UInt64 {
    guard let value else { throw ProbeFailure("Missing \(name)") }
    return value
  }

  private static func finiteDelta(_ before: Double?, _ after: Double?) -> Double? {
    guard let before, let after, before.isFinite, after.isFinite else { return nil }
    return after - before
  }
}

private struct ProbeRendererDeltas: Encodable {
  let vmemLockAttempts: UInt64
  let vmemLockSuccesses: UInt64
  let vmemPoolUnavailable: UInt64
  let vmemBaseAddressLockFailures: UInt64
  let vmemPendingInstallFailures: UInt64
  let vmemUnlockCallbacks: UInt64
  let vmemDisplayCallbacks: UInt64
  let vmemDisplayConsumeFailures: UInt64
  let enqueuedFrames: UInt64
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let presentationCopyFrames: UInt64
  let presentationCopyFailures: UInt64
  let decodePoolAllocationFailures: UInt64
  let renderPoolAllocationFailures: UInt64

  init(
    before: PiPTimebaseDiagnosticSnapshot,
    after: PiPTimebaseDiagnosticSnapshot
  )
    throws {
    func delta(_ first: UInt64, _ last: UInt64, _ name: String) throws -> UInt64 {
      guard last >= first else { throw ProbeFailure("\(name) moved backward") }
      return last - first
    }
    vmemLockAttempts = try delta(
      before.vmemLockAttemptCount, after.vmemLockAttemptCount, "vmem lock attempts"
    )
    vmemLockSuccesses = try delta(
      before.vmemLockSuccessCount, after.vmemLockSuccessCount, "vmem lock successes"
    )
    vmemPoolUnavailable = try delta(
      before.vmemPoolUnavailableCount, after.vmemPoolUnavailableCount, "vmem pool unavailable"
    )
    vmemBaseAddressLockFailures = try delta(
      before.vmemBaseAddressLockFailureCount,
      after.vmemBaseAddressLockFailureCount,
      "vmem base-address lock failures"
    )
    vmemPendingInstallFailures = try delta(
      before.vmemPendingInstallFailureCount,
      after.vmemPendingInstallFailureCount,
      "vmem pending-install failures"
    )
    vmemUnlockCallbacks = try delta(
      before.vmemUnlockCallbackCount, after.vmemUnlockCallbackCount, "vmem unlock callbacks"
    )
    vmemDisplayCallbacks = try delta(
      before.vmemDisplayCallbackCount, after.vmemDisplayCallbackCount, "vmem display callbacks"
    )
    vmemDisplayConsumeFailures = try delta(
      before.vmemDisplayConsumeFailureCount,
      after.vmemDisplayConsumeFailureCount,
      "vmem display-consume failures"
    )
    enqueuedFrames = try delta(
      before.enqueuedFrameCount, after.enqueuedFrameCount, "enqueued frames"
    )
    deliveredFrames = try delta(
      before.deliveredFrameCount, after.deliveredFrameCount, "delivered frames"
    )
    droppedFrames = try delta(
      before.droppedFrameCount, after.droppedFrameCount, "dropped frames"
    )
    presentationCopyFrames = try delta(
      before.presentationCopyFrameCount,
      after.presentationCopyFrameCount,
      "presentation-copy frames"
    )
    presentationCopyFailures = try delta(
      before.presentationCopyFailureCount,
      after.presentationCopyFailureCount,
      "presentation-copy failures"
    )
    decodePoolAllocationFailures = try delta(
      before.decodePoolAllocationFailureCount,
      after.decodePoolAllocationFailureCount,
      "decode-pool allocation failures"
    )
    renderPoolAllocationFailures = try delta(
      before.renderPoolAllocationFailureCount,
      after.renderPoolAllocationFailureCount,
      "render-pool allocation failures"
    )
  }
}

private struct ProbeLibVLCDeltas: Encodable {
  let decodedVideo: UInt64?
  let displayedPictures: UInt64?
  let lostPictures: UInt64?
  let latePictures: UInt64?

  init(
    before: PiPTimebaseDiagnosticSnapshot,
    after: PiPTimebaseDiagnosticSnapshot
  ) {
    decodedVideo = Self.delta(before.libVLCDecodedVideoCount, after.libVLCDecodedVideoCount)
    displayedPictures = Self.delta(
      before.libVLCDisplayedPictureCount, after.libVLCDisplayedPictureCount
    )
    lostPictures = Self.delta(before.libVLCLostPictureCount, after.libVLCLostPictureCount)
    latePictures = Self.delta(before.libVLCLatePictureCount, after.libVLCLatePictureCount)
  }

  private static func delta(_ first: UInt64?, _ last: UInt64?) -> UInt64? {
    guard let first, let last, last >= first else { return nil }
    return last - first
  }
}

private struct ProbeFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
