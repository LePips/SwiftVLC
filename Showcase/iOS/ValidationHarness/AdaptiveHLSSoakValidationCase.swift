import Darwin
import Foundation
import SwiftUI
import SwiftVLC

/// Runs the exact candidate against a deterministic, telemetry-bearing HLS
/// origin. The default physical lane lasts two hours; shorter runs are useful
/// for harness development but are rejected later by the qualification matrix.
struct AdaptiveHLSSoakValidationCase: View {
  @State private var player = Player()
  @State private var result = "not-run"
  @State private var progress = "0s"
  @State private var phase = "idle"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let durationSeconds = max(1, LaunchArguments.adaptiveSoakDurationValue ?? 7200)
  private let token = LaunchArguments.adaptiveSoakTokenValue ?? "missing-token"
  private let streams = HarnessStreams.load()?.streams

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        VideoView(player)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.AdaptiveHLSSoakValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.AdaptiveHLSSoakValidation.stateLabel
        )
        valueRow(
          "Elapsed",
          value: progress,
          identifier: AccessibilityID.AdaptiveHLSSoakValidation.progressLabel
        )
        valueRow(
          "Phase",
          value: phase,
          identifier: AccessibilityID.AdaptiveHLSSoakValidation.phaseLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.AdaptiveHLSSoakValidation.resultLabel
        )
      }

      Section("Adaptive HLS soak") {
        Button("Run " + String(durationSeconds) + "-second soak") {
          Task { await run() }
        }
        .accessibilityIdentifier(AccessibilityID.AdaptiveHLSSoakValidation.runButton)
        .disabled(isRunning || fixtureBaseURL == nil || token == "missing-token")

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.AdaptiveHLSSoakValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Adaptive HLS soak")
    .onDisappear { player.stop() }
  }

  private func run() async {
    guard fixtureBaseURL != nil, token != "missing-token" else { return }
    isRunning = true
    playbackError = nil
    result = "running"

    let started = ProcessInfo.processInfo.systemUptime
    var memorySeries: [AdaptiveMemorySample] = []
    var cancellationCount = 0
    let errorRecorder = AdaptiveErrorRecorder()
    let logTask = Task {
      for await entry in VLCInstance.shared.logStream(minimumLevel: .error) {
        await errorRecorder.record(entry)
      }
    }
    defer {
      logTask.cancel()
      player.stop()
      isRunning = false
    }

    do {
      let modes = [
        "abr-low-ts",
        "abr-high-fmp4",
        "vod-ts",
        "event-fmp4",
        "live-ts",
        "live-fmp4",
        "retry-ts",
        "abr-ts"
      ]
      let perPhase = max(4, min(45, durationSeconds / modes.count))
      var phaseIndex = 0

      while Int(ProcessInfo.processInfo.systemUptime - started) < durationSeconds {
        let mode = modes[phaseIndex % modes.count]
        phaseIndex += 1
        phase = mode
        if phaseIndex > 1 {
          player.stop()
          cancellationCount += 1
          try await Task.sleep(for: .milliseconds(200))
        }
        try player.play(url: masterURL(mode: mode))
        do {
          try await waitUntil("Playback did not start for " + mode, timeout: .seconds(30)) {
            player.state == .playing
          }
        } catch {
          throw error
        }

        let phaseBaselineElapsed = Int(ProcessInfo.processInfo.systemUptime - started)
        Self.appendProgressingMemorySample(
          elapsedSeconds: phaseBaselineElapsed,
          mode: mode,
          player: player,
          to: &memorySeries
        )

        let phaseDeadline = min(
          started + Double(durationSeconds),
          ProcessInfo.processInfo.systemUptime + Double(perPhase)
        )
        var inactiveSince: TimeInterval?
        var nextMemorySample = phaseBaselineElapsed + 15
        while ProcessInfo.processInfo.systemUptime < phaseDeadline {
          try Task.checkCancellation()
          let elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
          progress = "\(elapsed)s / \(durationSeconds)s"
          if elapsed >= nextMemorySample {
            Self.appendProgressingMemorySample(
              elapsedSeconds: elapsed,
              mode: mode,
              player: player,
              to: &memorySeries
            )
            nextMemorySample = elapsed + 15
          }

          if player.state == .playing {
            inactiveSince = nil
          } else {
            inactiveSince = inactiveSince ?? ProcessInfo.processInfo.systemUptime
            if ProcessInfo.processInfo.systemUptime - (inactiveSince ?? 0) > 20 {
              throw AdaptiveSoakFailure("Playback failed to recover in " + mode)
            }
          }
          try await Task.sleep(for: .seconds(2))
        }
        Self.appendProgressingMemorySample(
          elapsedSeconds: min(
            durationSeconds,
            Int(ProcessInfo.processInfo.systemUptime - started)
          ),
          mode: mode,
          player: player,
          to: &memorySeries
        )
      }

      let metrics = try await serverMetrics()
      let coverage = try AdaptivePlaylistCoverage(metrics: metrics, cancellations: cancellationCount)
      let analysis = try Self.analyze(memorySeries)
      let playbackProgress = try AdaptivePlaybackProgress(samples: memorySeries)
      let logs = await errorRecorder.snapshot
      let sanitizerFindings = logs.sanitizerFindings
      guard sanitizerFindings == 0 else {
        throw AdaptiveSoakFailure("Sanitizer diagnostic signature observed")
      }
      guard analysis.monotonicGrowth == false else {
        throw AdaptiveSoakFailure("Resident memory shows sustained monotonic growth")
      }
      let completedDuration = Int(ProcessInfo.processInfo.systemUptime - started)
      guard completedDuration >= durationSeconds else {
        throw AdaptiveSoakFailure("Adaptive soak ended before its requested duration")
      }

      let evidence = AdaptiveSoakEvidence(
        durationSeconds: completedDuration,
        playlistCoverage: coverage,
        allocationProvenance: AdaptiveAllocationProvenance(
          allocator: "Darwin default malloc zone",
          measurement: "malloc_zone_statistics plus Mach resident size",
          sourceOwnershipRegression: "SegmentChunkOwnership_test",
          expectedSourceReleaseCount: 1,
          sampleCount: memorySeries.count
        ),
        memorySeries: memorySeries,
        playbackProgress: playbackProgress,
        memoryAnalysis: analysis,
        sanitizerFindings: sanitizerFindings,
        sanitizerInstrumentationActive: Self.addressSanitizerIsActive,
        sanitizerEvidenceScope: "candidate runtime diagnostic signatures",
        crashes: 0,
        unboundedRecoveries: 0,
        monotonicGrowth: analysis.monotonicGrowth,
        libraryErrorCount: logs.totalCount,
        libraryErrors: logs.records,
        upstreamCrossLink: "https://code.videolan.org/videolan/vlc/-/work_items/29845"
      )
      try await markServerComplete()
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
      progress = "\(durationSeconds)s / \(durationSeconds)s"
      phase = "complete"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private var fixtureBaseURL: URL? {
    guard let vod = streams?.vod else { return nil }
    var components = URLComponents(url: vod, resolvingAgainstBaseURL: false)
    components?.path = ""
    components?.query = nil
    components?.fragment = nil
    return components?.url
  }

  private func masterURL(mode: String) throws -> URL {
    guard let url = fixtureBaseURL?.appending(path: "adaptive/\(token)/\(mode)/master.m3u8")
    else { throw AdaptiveSoakFailure("Missing adaptive fixture origin") }
    return url
  }

  private func serverMetrics() async throws -> [String: Any] {
    guard let url = fixtureBaseURL?.appending(path: "adaptive/\(token)/metrics")
    else { throw AdaptiveSoakFailure("Missing adaptive metrics endpoint") }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw AdaptiveSoakFailure("Adaptive metrics endpoint failed")
    }
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw AdaptiveSoakFailure("Adaptive metrics payload was malformed") }
    return value
  }

  private func markServerComplete() async throws {
    guard let url = fixtureBaseURL?.appending(path: "adaptive/\(token)/complete")
    else { throw AdaptiveSoakFailure("Missing adaptive completion endpoint") }
    let (_, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw AdaptiveSoakFailure("Adaptive completion endpoint failed")
    }
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
      guard clock.now < deadline else { throw AdaptiveSoakFailure(failure) }
      try await Task.sleep(for: .milliseconds(100))
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

  private static func memorySample(
    elapsedSeconds: Int,
    mode: String,
    player: Player
  ) -> AdaptiveMemorySample {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    var mallocStats = malloc_statistics_t()
    if let zone = malloc_default_zone() {
      malloc_zone_statistics(zone, &mallocStats)
    }
    let statistics = player.statistics
    return AdaptiveMemorySample(
      elapsedSeconds: elapsedSeconds,
      mode: mode,
      residentBytes: status == KERN_SUCCESS ? info.resident_size : 0,
      mallocBytesInUse: UInt64(mallocStats.size_in_use),
      mallocBytesAllocated: UInt64(mallocStats.size_allocated),
      playerState: String(describing: player.state),
      readBytes: statistics?.readBytes ?? 0,
      decodedVideoFrames: statistics?.decodedVideo ?? 0,
      displayedPictures: statistics?.displayedPictures ?? 0,
      demuxDiscontinuities: statistics?.demuxDiscontinuity ?? 0
    )
  }

  /// Retains only strictly chronological same-mode counter windows whose
  /// network, decode, and display seams all advanced. A stalled poll remains
  /// absent rather than being converted into a false progress window; if a
  /// mode never produces a real advancing pair, `AdaptivePlaybackProgress`
  /// fails the whole scenario.
  private static func appendProgressingMemorySample(
    elapsedSeconds: Int,
    mode: String,
    player: Player,
    to samples: inout [AdaptiveMemorySample]
  ) {
    let sample = memorySample(elapsedSeconds: elapsedSeconds, mode: mode, player: player)
    guard samples.last.map({ sample.elapsedSeconds > $0.elapsedSeconds }) ?? true else {
      return
    }
    if let previous = samples.last, previous.mode == mode {
      guard
        sample.readBytes > previous.readBytes,
        sample.decodedVideoFrames > previous.decodedVideoFrames,
        sample.displayedPictures > previous.displayedPictures
      else { return }
    }
    samples.append(sample)
  }

  private static func analyze(_ samples: [AdaptiveMemorySample]) throws -> AdaptiveMemoryAnalysis {
    guard samples.count >= 2, samples.allSatisfy({ $0.residentBytes > 0 }) else {
      throw AdaptiveSoakFailure("Memory sampling produced insufficient data")
    }
    let resident = samples.map(\.residentBytes)
    let baseline = resident.first ?? 0
    let peak = resident.max() ?? baseline
    let final = resident.last ?? baseline
    let growth = final > baseline ? final - baseline : 0
    let strictlyNondecreasing = zip(resident, resident.dropFirst()).allSatisfy { $1 >= $0 }
    let windowSize = max(1, samples.count / 4)
    let firstWindowStart = min(samples.count - 1, samples.count / 4)
    let firstWindowEnd = min(samples.count, firstWindowStart + windowSize)
    let lastWindowStart = max(0, samples.count - windowSize)
    let firstResidentMedian = median(
      Array(samples[firstWindowStart..<firstWindowEnd].map(\.residentBytes))
    )
    let lastResidentMedian = median(Array(samples[lastWindowStart...].map(\.residentBytes)))
    let firstMallocMedian = median(
      Array(samples[firstWindowStart..<firstWindowEnd].map(\.mallocBytesInUse))
    )
    let lastMallocMedian = median(Array(samples[lastWindowStart...].map(\.mallocBytesInUse)))
    let residentTrend = Int64(lastResidentMedian) - Int64(firstResidentMedian)
    let mallocTrend = Int64(lastMallocMedian) - Int64(firstMallocMedian)
    let residentSlope = slope(
      samples.map { (Double($0.elapsedSeconds), Double($0.residentBytes)) }
    )
    let mallocSlope = slope(
      samples.map { (Double($0.elapsedSeconds), Double($0.mallocBytesInUse)) }
    )
    let monotonicGrowth =
      (residentTrend > 32 * 1_048_576 && residentSlope > 4096)
        || (mallocTrend > 16 * 1_048_576 && mallocSlope > 2048)
    let growthLimit: UInt64 = 128 * 1_048_576
    guard growth <= growthLimit else {
      throw AdaptiveSoakFailure("Resident-memory growth exceeded 128 MiB")
    }
    return AdaptiveMemoryAnalysis(
      baselineResidentBytes: baseline,
      peakResidentBytes: peak,
      finalResidentBytes: final,
      growthBytes: growth,
      growthLimitBytes: growthLimit,
      firstSteadyResidentMedianBytes: firstResidentMedian,
      lastResidentMedianBytes: lastResidentMedian,
      residentSlopeBytesPerSecond: residentSlope,
      firstSteadyMallocMedianBytes: firstMallocMedian,
      lastMallocMedianBytes: lastMallocMedian,
      mallocSlopeBytesPerSecond: mallocSlope,
      observedDownwardSample: !strictlyNondecreasing,
      monotonicGrowth: monotonicGrowth
    )
  }

  private static func median(_ values: [UInt64]) -> UInt64 {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[sorted.count / 2]
  }

  private static func slope(_ values: [(x: Double, y: Double)]) -> Double {
    guard values.count >= 2 else { return 0 }
    let xMean = values.map(\.x).reduce(0, +) / Double(values.count)
    let yMean = values.map(\.y).reduce(0, +) / Double(values.count)
    let numerator = values.reduce(0) { result, value in
      result + (value.x - xMean) * (value.y - yMean)
    }
    let denominator = values.reduce(0) { result, value in
      result + (value.x - xMean) * (value.x - xMean)
    }
    return denominator > 0 ? numerator / denominator : 0
  }

  private static var addressSanitizerIsActive: Bool {
    dlsym(UnsafeMutableRawPointer(bitPattern: -2), "__asan_get_current_allocated_bytes") != nil
  }
}

private actor AdaptiveErrorRecorder {
  private static let evidenceLimit = 20
  private static let messageLimit = 1024
  private var values: [AdaptiveLogEvidence] = []
  private var totalCount = 0
  private var sanitizerFindings = 0

  func record(_ entry: LogEntry) {
    let complete = AdaptiveLogEvidence(module: entry.module, message: entry.message)
    totalCount += 1
    if complete.isSanitizerFinding {
      sanitizerFindings += 1
    }
    if values.count < Self.evidenceLimit {
      values.append(
        AdaptiveLogEvidence(
          module: entry.module,
          message: String(entry.message.prefix(Self.messageLimit))
        )
      )
    }
  }

  var snapshot: AdaptiveLogSnapshot {
    AdaptiveLogSnapshot(
      records: values,
      totalCount: totalCount,
      sanitizerFindings: sanitizerFindings
    )
  }
}

private struct AdaptiveLogSnapshot: Sendable {
  let records: [AdaptiveLogEvidence]
  let totalCount: Int
  let sanitizerFindings: Int
}

private struct AdaptivePlaylistCoverage: Encodable {
  let playlistTypes: [String]
  let containers: [String]
  let modes: [String]
  let variants: [String]
  let masterRequests: Int
  let mediaPlaylistRequests: Int
  let segmentRequests: Int
  let successfulSegments: Int
  let variantTransitions: Int
  let discontinuityManifests: Int
  let expiredWindows: Int
  let retryFailures: Int
  let retryRecoveries: Int
  let cancellations: Int

  init(metrics: [String: Any], cancellations: Int) throws {
    func strings(_ key: String) throws -> [String] {
      guard let value = metrics[key] as? [String] else {
        throw AdaptiveSoakFailure("Missing server metric \(key)")
      }
      return value
    }
    func integer(_ key: String) throws -> Int {
      guard let value = metrics[key] as? Int else {
        throw AdaptiveSoakFailure("Missing server metric \(key)")
      }
      return value
    }
    playlistTypes = try strings("playlistTypes")
    containers = try strings("containers")
    modes = try strings("modes")
    variants = try strings("variants")
    masterRequests = try integer("masterRequests")
    mediaPlaylistRequests = try integer("mediaPlaylistRequests")
    segmentRequests = try integer("segmentRequests")
    successfulSegments = try integer("successfulSegments")
    variantTransitions = try integer("variantTransitions")
    discontinuityManifests = try integer("discontinuityManifests")
    expiredWindows = try integer("expiredWindows")
    retryFailures = try integer("retryFailures")
    retryRecoveries = try integer("retryRecoveries")
    self.cancellations = cancellations

    guard Set(playlistTypes) == ["vod", "event", "live"] else {
      throw AdaptiveSoakFailure("VOD/event/live playlist coverage was incomplete")
    }
    guard Set(containers) == ["ts", "fmp4"], Set(variants) == ["low", "high"] else {
      throw AdaptiveSoakFailure("TS/fMP4 or representation coverage was incomplete")
    }
    guard
      segmentRequests > 0,
      successfulSegments > 0,
      variantTransitions > 0,
      discontinuityManifests > 0,
      expiredWindows > 0,
      retryFailures > 0,
      retryRecoveries > 0,
      cancellations > 0
    else { throw AdaptiveSoakFailure("Adaptive edge-case telemetry was incomplete") }
  }
}

private struct AdaptiveAllocationProvenance: Encodable {
  let allocator: String
  let measurement: String
  let sourceOwnershipRegression: String
  let expectedSourceReleaseCount: Int
  let sampleCount: Int
}

private struct AdaptiveMemorySample: Encodable {
  let elapsedSeconds: Int
  let mode: String
  let residentBytes: UInt64
  let mallocBytesInUse: UInt64
  let mallocBytesAllocated: UInt64
  let playerState: String
  let readBytes: UInt64
  let decodedVideoFrames: UInt64
  let displayedPictures: UInt64
  let demuxDiscontinuities: UInt64
}

private struct AdaptivePlaybackProgress: Encodable {
  let formatVersion = 1
  let windowSeconds = 60
  let modes: [String]
  let windows: [AdaptivePlaybackProgressWindow]

  init(samples: [AdaptiveMemorySample]) throws {
    modes = [
      "abr-high-fmp4",
      "abr-low-ts",
      "abr-ts",
      "event-fmp4",
      "live-fmp4",
      "live-ts",
      "retry-ts",
      "vod-ts"
    ]
    windows = zip(samples, samples.dropFirst()).compactMap { previous, current in
      guard previous.mode == current.mode else { return nil }
      return AdaptivePlaybackProgressWindow(previous: previous, current: current)
    }
    guard
      Set(windows.map(\.mode)) == Set(modes),
      windows.allSatisfy({
        $0.endElapsedSeconds > $0.startElapsedSeconds
          && $0.endElapsedSeconds - $0.startElapsedSeconds <= windowSeconds
          && $0.readBytesDelta > 0
          && $0.decodedVideoFramesDelta > 0
          && $0.displayedPicturesDelta > 0
      })
    else {
      throw AdaptiveSoakFailure("Every adaptive mode did not produce retained playback progress")
    }
  }
}

private struct AdaptivePlaybackProgressWindow: Encodable {
  let mode: String
  let startElapsedSeconds: Int
  let endElapsedSeconds: Int
  let readBytesDelta: UInt64
  let decodedVideoFramesDelta: UInt64
  let displayedPicturesDelta: UInt64

  init(previous: AdaptiveMemorySample, current: AdaptiveMemorySample) {
    mode = current.mode
    startElapsedSeconds = previous.elapsedSeconds
    endElapsedSeconds = current.elapsedSeconds
    readBytesDelta = current.readBytes - previous.readBytes
    decodedVideoFramesDelta = current.decodedVideoFrames - previous.decodedVideoFrames
    displayedPicturesDelta = current.displayedPictures - previous.displayedPictures
  }
}

private struct AdaptiveMemoryAnalysis: Encodable {
  let baselineResidentBytes: UInt64
  let peakResidentBytes: UInt64
  let finalResidentBytes: UInt64
  let growthBytes: UInt64
  let growthLimitBytes: UInt64
  let firstSteadyResidentMedianBytes: UInt64
  let lastResidentMedianBytes: UInt64
  let residentSlopeBytesPerSecond: Double
  let firstSteadyMallocMedianBytes: UInt64
  let lastMallocMedianBytes: UInt64
  let mallocSlopeBytesPerSecond: Double
  let observedDownwardSample: Bool
  let monotonicGrowth: Bool
}

private struct AdaptiveLogEvidence: Encodable, Sendable {
  let module: String?
  let message: String

  var isSanitizerFinding: Bool {
    let lower = message.lowercased()
    return lower.contains("addresssanitizer")
      || lower.contains("threadsanitizer")
      || lower.contains("heap-use-after-free")
      || lower.contains("double free")
  }
}

private struct AdaptiveSoakEvidence: Encodable {
  let durationSeconds: Int
  let playlistCoverage: AdaptivePlaylistCoverage
  let allocationProvenance: AdaptiveAllocationProvenance
  let memorySeries: [AdaptiveMemorySample]
  let playbackProgress: AdaptivePlaybackProgress
  let memoryAnalysis: AdaptiveMemoryAnalysis
  let sanitizerFindings: Int
  let sanitizerInstrumentationActive: Bool
  let sanitizerEvidenceScope: String
  let crashes: Int
  let unboundedRecoveries: Int
  let monotonicGrowth: Bool
  let libraryErrorCount: Int
  let libraryErrors: [AdaptiveLogEvidence]
  let upstreamCrossLink: String
}

private struct AdaptiveSoakFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}
