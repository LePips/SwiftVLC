import AVFoundation
import Darwin
import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Unattended two-hour direct-PiP clock lane. App-side samples are paired with
/// real system-PiP checks and an Audio System Trace by the device runner.
struct TimebaseSoakValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var result = "not-run"
  @State private var phase = "idle"
  @State private var progress = "0s"
  @State private var interruptionBegan = 0
  @State private var interruptionEnded = 0
  @State private var postInterruptionAudioBaseline: UInt64?
  @State private var postInterruptionAudioRecovered = false
  @State private var playbackError: String?
  @State private var isRunning = false

  private let baseURL = LaunchArguments.timebaseSoakBaseURLValue
  private let durationSeconds = max(1, LaunchArguments.timebaseSoakDurationValue ?? 7200)
  private let token = LaunchArguments.timebaseSoakTokenValue ?? "missing-token"
  private let mode = TimebaseSoakMode(
    rawValue: LaunchArguments.timebaseSoakModeValue ?? "vod"
  ) ?? .vod

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        DirectPiPValidationSurface(player: player, controller: $controller)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.TimebaseSoakValidation.videoView)
      }
      Section("Measured state") {
        valueRow("PiP possible", controller?.isPossible == true ? "yes" : "no", AccessibilityID.TimebaseSoakValidation.possibleLabel)
        valueRow("PiP active", controller?.isActive == true ? "yes" : "no", AccessibilityID.TimebaseSoakValidation.activeLabel)
        valueRow("Phase", phase, AccessibilityID.TimebaseSoakValidation.phaseLabel)
        valueRow("Elapsed", progress, AccessibilityID.TimebaseSoakValidation.progressLabel)
        valueRow("Interruptions", "\(interruptionBegan):\(interruptionEnded)", AccessibilityID.TimebaseSoakValidation.interruptionLabel)
        valueRow("Qualification", result, AccessibilityID.TimebaseSoakValidation.resultLabel)
      }
      Section("Timebase soak") {
        Button("Run \(mode.rawValue) timebase soak") { Task { await run() } }
          .accessibilityIdentifier(AccessibilityID.TimebaseSoakValidation.runButton)
          .disabled(isRunning || baseURL == nil || token == "missing-token")
        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.TimebaseSoakValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Direct PiP timebase soak")
    .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification)) {
      recordInterruption($0)
    }
    .onDisappear {
      controller?.stop()
      player.stop()
    }
  }

  private func run() async {
    guard let baseURL, token != "missing-token" else { return }
    isRunning = true
    playbackError = nil
    result = "running"
    postInterruptionAudioBaseline = nil
    postInterruptionAudioRecovered = false
    let capture: TimebaseRawCapture
    var correctionTask: Task<Void, Never>?
    do {
      capture = try TimebaseRawCapture(token: token, mode: mode)
    } catch {
      playbackError = String(describing: error)
      result = "failed"
      isRunning = false
      return
    }
    defer {
      correctionTask?.cancel()
      player.stop()
      isRunning = false
    }

    do {
      let fixtureURL = try qualifiedFixtureURL(baseURL: baseURL)
      try play(fixtureURL)
      try await waitUntil("Playback did not start", timeout: .seconds(30)) { player.state == .playing }
      try await waitUntil("Direct PiP did not become possible", timeout: .seconds(30)) { controller?.isPossible == true }
      guard let controller else { throw TimebaseSoakFailure("Direct PiP controller disappeared") }
      // The decoded-frame media clock is intentionally disabled for normal
      // clients. Enable the qualification probe before subscribing and
      // starting PiP so the raw one-second stream can bind each decoded frame
      // to the libVLC clock that produced it.
      controller.enableFrameContentDiagnostics()
      let correctionStream = controller.timebaseCorrections
      correctionTask = Task {
        for await correction in correctionStream {
          guard !Task.isCancelled else { return }
          await capture.append(correction: correction)
        }
      }
      await Task.yield()
      guard controller.start() == .accepted else { throw TimebaseSoakFailure("PiP start was not accepted") }
      try await waitUntil("Direct PiP did not become active", timeout: .seconds(30)) { controller.isActive }
      try await signalReady(baseURL: baseURL)
      let soakStarted = ProcessInfo.processInfo.systemUptime

      var clockSeries: [TimebaseClockSample] = []
      var audioSeries: [TimebaseAudioSample] = []
      var frameSeries: [TimebaseFrameSample] = []
      var transitions: [TimebaseTransition] = []
      var monotonicityViolations = 0
      var previousPresentation: (generation: UInt64, seconds: Double)?
      var didPause = false
      var didSeek = false
      var didReplace = false
      var didThermalLoad = false
      var thermalTask: Task<UInt64, Never>?
      var thermalStateBefore = "not-started"
      var currentRate: Float = 0
      var nextCompactSample = 0

      while Int(ProcessInfo.processInfo.systemUptime - soakStarted) < durationSeconds {
        try Task.checkCancellation()
        let elapsed = Int(ProcessInfo.processInfo.systemUptime - soakStarted)
        progress = "\(elapsed)s / \(durationSeconds)s"
        let rate = Self.rate(elapsed: elapsed, duration: durationSeconds)
        if rate != currentRate {
          try player.setPlaybackRate(PlaybackRate(rate))
          currentRate = rate
          transitions.append(.init(elapsedSeconds: elapsed, kind: "rate", outcome: String(rate)))
        }
        if elapsed >= 60, !didPause {
          player.pause()
          try await waitUntil("Pause did not settle", timeout: .seconds(10)) { !player.isActive }
          try await Task.sleep(for: .seconds(2))
          player.resume()
          try await waitUntil("Resume did not settle", timeout: .seconds(10)) { player.isActive }
          transitions.append(.init(elapsedSeconds: elapsed, kind: "pause-resume", outcome: "pass"))
          didPause = true
        }
        if elapsed >= 120, !didSeek {
          let outcome = mode == .vod ? (player.jump(by: .seconds(10)) ? "pass" : "rejected") : "not-applicable-live"
          if mode == .vod, outcome != "pass" {
            throw TimebaseSoakFailure("VOD seek was rejected")
          }
          transitions.append(.init(elapsedSeconds: elapsed, kind: "seek", outcome: outcome))
          didSeek = true
        }
        if elapsed >= 180, !didReplace {
          try play(fixtureURL)
          try await waitUntil("Replacement did not start", timeout: .seconds(30)) { player.state == .playing }
          // Direct playback can replace the underlying native player. Apply
          // the active third's rate to that new handle instead of assuming it
          // inherited the outgoing handle's value.
          try player.setPlaybackRate(PlaybackRate(currentRate))
          try await waitUntil("PiP did not survive replacement", timeout: .seconds(20)) { controller.isActive }
          transitions.append(.init(elapsedSeconds: elapsed, kind: "replacement", outcome: "pass"))
          didReplace = true
        }
        if elapsed >= 240, !didThermalLoad {
          thermalStateBefore = ProcessInfo.processInfo.thermalState.qualificationName
          thermalTask = Task.detached { await Self.runBoundedThermalLoad(seconds: 30) }
          transitions.append(.init(elapsedSeconds: elapsed, kind: "thermal-pressure-start", outcome: thermalStateBefore))
          didThermalLoad = true
        }
        phase = "direct-\(mode.rawValue)-\(currentRate)x"
        let snapshot = controller.timebaseDiagnosticSnapshot()
        let stats = player.statistics
        if
          let baseline = postInterruptionAudioBaseline,
          let playedAudioBuffers = stats?.playedAudioBuffers,
          playedAudioBuffers > baseline {
          postInterruptionAudioRecovered = true
        }
        let session = AVAudioSession.sharedInstance()
        let latency = session.outputLatency + session.ioBufferDuration
        let clockSample = TimebaseClockSample(elapsedSeconds: elapsed, snapshot: snapshot)
        let audioSample = TimebaseAudioSample(
          elapsedSeconds: elapsed,
          mediaTimeSeconds: snapshot.mediaTimeSeconds,
          estimatedPresentationSeconds: snapshot.mediaTimeSeconds - latency,
          outputLatencySeconds: session.outputLatency,
          ioBufferDurationSeconds: session.ioBufferDuration,
          playedBuffers: stats?.playedAudioBuffers ?? 0,
          lostBuffers: stats?.lostAudioBuffers ?? 0
        )
        if let presented = snapshot.lastDeliveredSampleTimeSeconds {
          if
            let previousPresentation,
            previousPresentation.generation == snapshot.playbackGeneration,
            presented + 0.001 < previousPresentation.seconds {
            monotonicityViolations += 1
          }
          previousPresentation = (snapshot.playbackGeneration, presented)
        }
        let frameSample = TimebaseFrameSample(elapsedSeconds: elapsed, snapshot: snapshot)
        try await capture.append(clock: clockSample, audio: audioSample, frame: frameSample)
        if elapsed >= nextCompactSample {
          clockSeries.append(clockSample)
          audioSeries.append(audioSample)
          frameSeries.append(frameSample)
          nextCompactSample = elapsed + 60
        }
        guard controller.isActive else { throw TimebaseSoakFailure("Direct PiP stopped during soak") }
        guard snapshot.displayLayerStatus != "failed" else { throw TimebaseSoakFailure("Display layer failed") }
        try await Task.sleep(for: .seconds(1))
      }

      correctionTask?.cancel()
      await correctionTask?.value
      try await capture.close()
      let correctionSeries = await capture.corrections
      if let thermalTask {
        let checksum = await thermalTask.value
        let after = ProcessInfo.processInfo.thermalState.qualificationName
        transitions.append(.init(
          elapsedSeconds: durationSeconds,
          kind: "thermal-pressure-complete",
          outcome: "\(thermalStateBefore)->\(after);checksum=\(checksum)"
        ))
      }
      let directDuration = Int(ProcessInfo.processInfo.systemUptime - soakStarted)
      controller.stop()
      player.stop()
      phase = "avplayer-baseline"
      let baseline = try await AVPlayerTimebaseBaseline.capture(
        url: fixtureURL,
        mode: mode,
        durationSeconds: min(180, max(60, durationSeconds / 40))
      )
      let maxDrift = clockSeries.compactMap(\.driftSeconds).map(abs).max() ?? 0
      let maxSteadyCorrection = correctionSeries
        .filter { $0.reason == .steadyStateDrift }
        .map { abs($0.driftSeconds) }
        .max() ?? 0
      guard monotonicityViolations == 0 else { throw TimebaseSoakFailure("Presented frame time moved backwards") }
      guard maxDrift <= 2.1 else { throw TimebaseSoakFailure("Clock drift exceeded 2.1 seconds") }
      guard maxSteadyCorrection <= 2.1 else { throw TimebaseSoakFailure("A steady correction exceeded 2.1 seconds") }
      guard didPause, didSeek, didReplace, didThermalLoad else { throw TimebaseSoakFailure("Transition schedule was incomplete") }
      guard interruptionBegan == 1, interruptionEnded == 1 else {
        throw TimebaseSoakFailure("Expected exactly one cross-process interruption pair")
      }
      guard postInterruptionAudioRecovered else {
        throw TimebaseSoakFailure("Audio buffers did not advance after interruption recovery")
      }

      let evidence = TimebaseSoakEvidence(
        durationSeconds: directDuration,
        mode: mode.rawValue,
        rates: [0.5, 1, 2],
        clockSeries: clockSeries,
        corrections: correctionSeries,
        audioPresentationSeries: .init(
          method: "libVLC media clock minus AVAudioSession outputLatency and ioBufferDuration; paired with host Audio System Trace",
          hostTraceStatus: "required-host-augmentation",
          samples: audioSeries
        ),
        presentedFrameSeries: frameSeries,
        driftBudget: .init(maximumSeconds: 2.1, observedMaximumSeconds: maxDrift),
        correctionBudget: .init(maximumSeconds: 2.1, observedMaximumSeconds: maxSteadyCorrection, count: correctionSeries.count),
        transitions: transitions,
        avPlayerBaseline: baseline,
        rawCapture: .init(
          status: "required-host-augmentation",
          fileName: capture.url.lastPathComponent,
          sampleIntervalSeconds: 1
        ),
        visibleSnapCount: -1,
        monotonicityViolations: monotonicityViolations,
        interruptionPairs: interruptionBegan,
        postInterruptionAudioRecovery: "pass",
        hostTraceRequirements: ["audioPresentationSeries": "Audio System Trace"]
      )
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
      phase = "complete"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      controller?.stop()
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func play(_ url: URL) throws {
    let media = try Media(url: url)
    try player.play(media)
  }

  private func qualifiedFixtureURL(baseURL: URL) throws -> URL {
    let url = switch mode {
    case .vod: baseURL.appending(path: "adaptive/\(token)/timebase-vod-ts/master.m3u8")
    case .live: baseURL.appending(path: "adaptive/\(token)/live-ts/master.m3u8")
    }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw TimebaseSoakFailure("Could not construct fixture URL")
    }
    components.queryItems = (components.queryItems ?? []) + [.init(name: "swiftvlcQualification", value: token)]
    guard let qualified = components.url else { throw TimebaseSoakFailure("Could not bind fixture request") }
    return qualified
  }

  private func signalReady(baseURL: URL) async throws {
    guard
      var components = URLComponents(
        url: baseURL.appending(path: "healthz"),
        resolvingAgainstBaseURL: false
      ) else { throw TimebaseSoakFailure("Could not construct readiness URL") }
    components.queryItems = [.init(name: "swiftvlcTimebaseReady", value: token)]
    guard let url = components.url else { throw TimebaseSoakFailure("Could not bind readiness URL") }
    let (_, response) = try await URLSession.shared.data(from: url)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
      throw TimebaseSoakFailure("Fixture origin rejected readiness signal")
    }
  }

  private func recordInterruption(_ notification: Notification) {
    guard
      let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    switch type {
    case .began:
      interruptionBegan += 1
    case .ended:
      interruptionEnded += 1
      postInterruptionAudioBaseline = player.statistics?.playedAudioBuffers
    @unknown default: break
    }
  }

  private func waitUntil(_ failure: String, timeout: Duration, condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw TimebaseSoakFailure(failure) }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func valueRow(_ title: String, _ value: String, _ identifier: String) -> some View {
    HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary) }
      .qualificationAccessibilityValue(value, title: title, identifier: identifier)
  }

  fileprivate static func rate(elapsed: Int, duration: Int) -> Float {
    switch elapsed / max(1, duration / 3) {
    case 0: 0.5
    case 1: 1
    default: 2
    }
  }

  private nonisolated static func runBoundedThermalLoad(seconds: Int) async -> UInt64 {
    await withTaskGroup(of: UInt64.self, returning: UInt64.self) { group in
      for seed in 1...max(1, min(2, ProcessInfo.processInfo.activeProcessorCount - 1)) {
        group.addTask {
          let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
          var value = UInt64(seed)
          while ProcessInfo.processInfo.systemUptime < deadline {
            value ^= value << 13
            value ^= value >> 7
            value ^= value << 17
          }
          return value
        }
      }
      var checksum: UInt64 = 0
      for await value in group {
        checksum ^= value
      }
      return checksum
    }
  }
}

private enum TimebaseSoakMode: String, Codable { case vod, live }

private actor TimebaseRawCapture {
  nonisolated let url: URL
  private let handle: FileHandle
  private let encoder = JSONEncoder()
  private var writeFailure: Error?
  private var isClosed = false
  private var correctionValues: [PiPTimebaseCorrection] = []
  private var sampleCount = 0

  init(token: String, mode: TimebaseSoakMode) throws {
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    let safeToken = token.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
    url = documents.appending(path: "swiftvlc-timebase-\(String(safeToken))-\(mode.rawValue).jsonl")
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    handle = try FileHandle(forWritingTo: url)
    encoder.outputFormatting = [.sortedKeys]
  }

  func append(
    clock: TimebaseClockSample,
    audio: TimebaseAudioSample,
    frame: TimebaseFrameSample
  )
    throws {
    sampleCount += 1
    try write(
      .init(kind: "sample", clock: clock, audio: audio, frame: frame),
      synchronize: sampleCount.isMultiple(of: 30)
    )
  }

  func append(correction: PiPTimebaseCorrection) {
    correctionValues.append(correction)
    do {
      try write(.init(kind: "correction", correction: correction), synchronize: true)
    } catch {
      writeFailure = writeFailure ?? error
    }
  }

  var corrections: [PiPTimebaseCorrection] {
    correctionValues
  }

  func close() throws {
    guard !isClosed else { return }
    isClosed = true
    try handle.synchronize()
    try handle.close()
    if let writeFailure {
      throw writeFailure
    }
  }

  private func write(_ line: TimebaseRawLine, synchronize: Bool) throws {
    guard !isClosed else { throw CocoaError(.fileWriteUnknown) }
    var data = try encoder.encode(line)
    data.append(0x0A)
    try handle.write(contentsOf: data)
    if synchronize {
      try handle.synchronize()
    }
  }
}

private struct TimebaseRawLine: Codable {
  let kind: String
  var clock: TimebaseClockSample?
  var audio: TimebaseAudioSample?
  var frame: TimebaseFrameSample?
  var correction: PiPTimebaseCorrection?
}

private struct TimebaseClockSample: Codable {
  let elapsedSeconds: Int
  let mediaTimeSeconds: Double
  let controlTimebaseSeconds: Double?
  let controlTimebaseRate: Double?
  let driftSeconds: Double?
  let playbackGeneration: UInt64
  let requestedRate: Float
  init(elapsedSeconds: Int, snapshot: PiPTimebaseDiagnosticSnapshot) {
    self.elapsedSeconds = elapsedSeconds
    mediaTimeSeconds = snapshot.mediaTimeSeconds
    controlTimebaseSeconds = snapshot.controlTimebaseSeconds
    controlTimebaseRate = snapshot.controlTimebaseRate
    driftSeconds = snapshot.driftSeconds
    playbackGeneration = snapshot.playbackGeneration
    requestedRate = snapshot.requestedRate
  }
}

private struct TimebaseAudioSample: Codable {
  let elapsedSeconds: Int
  let mediaTimeSeconds: Double
  let estimatedPresentationSeconds: Double
  let outputLatencySeconds: Double
  let ioBufferDurationSeconds: Double
  let playedBuffers: UInt64
  let lostBuffers: UInt64
}

private struct TimebaseFrameSample: Codable {
  let elapsedSeconds: Int
  let playbackGeneration: UInt64
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let presentedSeconds: Double?
  let decodedFrames: UInt64
  let decodedFrameMediaTimeSeconds: Double?
  init(elapsedSeconds: Int, snapshot: PiPTimebaseDiagnosticSnapshot) {
    self.elapsedSeconds = elapsedSeconds
    playbackGeneration = snapshot.playbackGeneration
    deliveredFrames = snapshot.deliveredFrameCount
    droppedFrames = snapshot.droppedFrameCount
    presentedSeconds = snapshot.lastDeliveredSampleTimeSeconds
    decodedFrames = snapshot.decodedFrameCount
    decodedFrameMediaTimeSeconds = snapshot.lastDecodedFrameMediaTimeSeconds
  }
}

private struct TimebaseTransition: Codable {
  let elapsedSeconds: Int
  let kind: String
  let outcome: String
}

private struct TimebaseBudget: Codable {
  let maximumSeconds: Double
  let observedMaximumSeconds: Double
}

private struct TimebaseCorrectionBudget: Codable {
  let maximumSeconds: Double
  let observedMaximumSeconds: Double
  let count: Int
}

private struct TimebaseAudioSeries: Codable {
  let method: String
  let hostTraceStatus: String
  let samples: [TimebaseAudioSample]
}

private struct TimebaseRawCaptureReference: Codable {
  let status: String
  let fileName: String
  let sampleIntervalSeconds: Int
}

private struct AVPlayerBaselineEvidence: Codable {
  let durationSeconds: Int
  let requestedRates: [Float]
  let observedRates: [Float]
  let samples: [AVPlayerBaselineSample]
  let maximumVideoClockDriftSeconds: Double
}

private struct AVPlayerBaselineSample: Codable {
  let elapsedSeconds: Int
  let requestedRate: Float
  let actualRate: Float
  let playerSeconds: Double
  let videoOutputSeconds: Double?
  let videoClockDriftSeconds: Double?
  let estimatedAudioPresentationSeconds: Double
}

@MainActor
private enum AVPlayerTimebaseBaseline {
  static func capture(
    url: URL,
    mode: TimebaseSoakMode,
    durationSeconds: Int
  )
    async throws -> AVPlayerBaselineEvidence {
    let item = AVPlayerItem(url: url)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: nil)
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.play()
    let readyDeadline = ContinuousClock.now.advanced(by: .seconds(30))
    while item.status == .unknown, ContinuousClock.now < readyDeadline {
      try await Task.sleep(for: .milliseconds(100))
    }
    guard item.status == .readyToPlay else {
      throw TimebaseSoakFailure("AVPlayer baseline did not become ready")
    }
    let started = ProcessInfo.processInfo.systemUptime
    var samples: [AVPlayerBaselineSample] = []
    var currentRate: Float = 0
    while Int(ProcessInfo.processInfo.systemUptime - started) < durationSeconds {
      let elapsed = Int(ProcessInfo.processInfo.systemUptime - started)
      let rate = TimebaseSoakValidationCase.rate(elapsed: elapsed, duration: durationSeconds)
      if rate != currentRate {
        player.playImmediately(atRate: rate)
        currentRate = rate
      }
      let playerSeconds = player.currentTime().seconds
      guard playerSeconds.isFinite else {
        try await Task.sleep(for: .seconds(1))
        continue
      }
      if
        mode == .vod,
        (item.duration.seconds.isFinite && playerSeconds >= item.duration.seconds - 1)
        || player.timeControlStatus == .paused {
        await player.seek(to: .zero)
        player.playImmediately(atRate: rate)
        try await Task.sleep(for: .milliseconds(200))
        continue
      }
      let videoTime = output.itemTime(forHostTime: ProcessInfo.processInfo.systemUptime)
      let rawVideoSeconds = videoTime.isValid ? videoTime.seconds : .nan
      let videoSeconds = rawVideoSeconds.isFinite ? rawVideoSeconds : nil
      let latency = AVAudioSession.sharedInstance().outputLatency + AVAudioSession.sharedInstance().ioBufferDuration
      samples.append(.init(
        elapsedSeconds: elapsed,
        requestedRate: rate,
        actualRate: player.rate,
        playerSeconds: playerSeconds,
        videoOutputSeconds: videoSeconds,
        videoClockDriftSeconds: videoSeconds.map { playerSeconds - $0 },
        estimatedAudioPresentationSeconds: playerSeconds - latency
      ))
      try await Task.sleep(for: .seconds(2))
    }
    player.pause()
    guard samples.count >= durationSeconds / 3 else { throw TimebaseSoakFailure("AVPlayer baseline produced too few samples") }
    let videoClockDrifts = samples.compactMap(\.videoClockDriftSeconds)
    guard !videoClockDrifts.isEmpty else {
      throw TimebaseSoakFailure("AVPlayer baseline produced no video-clock comparison")
    }
    let observedRates = Array(Set(samples.map(\.actualRate))).sorted()
    guard
      [Float(0.5), 1, 2].allSatisfy({ expected in
        observedRates.contains { abs($0 - expected) < 0.01 }
      }) else {
      throw TimebaseSoakFailure("AVPlayer baseline did not apply every requested rate")
    }
    let maximum = videoClockDrifts.map(abs).max() ?? 0
    return .init(
      durationSeconds: durationSeconds,
      requestedRates: [0.5, 1, 2],
      observedRates: observedRates,
      samples: samples,
      maximumVideoClockDriftSeconds: maximum
    )
  }
}

private struct TimebaseSoakEvidence: Codable {
  let durationSeconds: Int
  let mode: String
  let rates: [Float]
  let clockSeries: [TimebaseClockSample]
  let corrections: [PiPTimebaseCorrection]
  let audioPresentationSeries: TimebaseAudioSeries
  let presentedFrameSeries: [TimebaseFrameSample]
  let driftBudget: TimebaseBudget
  let correctionBudget: TimebaseCorrectionBudget
  let transitions: [TimebaseTransition]
  let avPlayerBaseline: AVPlayerBaselineEvidence
  let rawCapture: TimebaseRawCaptureReference
  let visibleSnapCount: Int
  let monotonicityViolations: Int
  let interruptionPairs: Int
  let postInterruptionAudioRecovery: String
  let hostTraceRequirements: [String: String]
}

private struct TimebaseSoakFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}

extension ProcessInfo.ThermalState {
  fileprivate var qualificationName: String {
    switch self {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
