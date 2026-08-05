import Darwin
import Foundation
import SwiftUI
import SwiftVLC

/// Candidate-bound native PiP subtitle/OSD matrix. XCTest inspects the real
/// SpringBoard pixels and drives resize gestures while this view owns media,
/// subtitle, pause, seek, replacement, and adaptive-resolution transitions.
struct NativeSubtitleMatrixValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var result = "not-run"
  @State private var progress = "0s"
  @State private var profileName = "idle"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let baseURL = LaunchArguments.nativeSubtitleBaseURLValue
  private let durationSeconds = max(1, LaunchArguments.nativeSubtitleDurationValue ?? 900)
  private let token = LaunchArguments.nativeSubtitleTokenValue ?? "missing-token"

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        PiPVideoView(player, controller: $controller)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.NativeSubtitleMatrixValidation.videoView)
      }
      Section("Measured state") {
        valueRow("Playback", value: String(describing: player.state), identifier: AccessibilityID.NativeSubtitleMatrixValidation.stateLabel)
        valueRow("PiP possible", value: controller?.isPossible == true ? "yes" : "no", identifier: AccessibilityID.NativeSubtitleMatrixValidation.possibleLabel)
        valueRow("PiP active", value: controller?.isActive == true ? "yes" : "no", identifier: AccessibilityID.NativeSubtitleMatrixValidation.activeLabel)
        valueRow("Elapsed", value: progress, identifier: AccessibilityID.NativeSubtitleMatrixValidation.progressLabel)
        valueRow("Profile", value: profileName, identifier: AccessibilityID.NativeSubtitleMatrixValidation.profileLabel)
        valueRow("Qualification", value: result, identifier: AccessibilityID.NativeSubtitleMatrixValidation.resultLabel)
      }
      Section("Native subtitle matrix") {
        Button("Run native subtitle matrix") { Task { await run() } }
          .accessibilityIdentifier(AccessibilityID.NativeSubtitleMatrixValidation.runButton)
          .disabled(isRunning || baseURL == nil || token == "missing-token")
        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.NativeSubtitleMatrixValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Native PiP subtitles")
    .onDisappear {
      player.withMarquee { $0.hide() }
      controller?.stop()
      player.stop()
    }
  }

  private func run() async {
    guard baseURL != nil, token != "missing-token" else { return }
    isRunning = true
    playbackError = nil
    result = "running"
    defer { isRunning = false }
    do {
      let started = ProcessInfo.processInfo.systemUptime
      let phaseSeconds = max(55, (durationSeconds - 60) / SubtitleProfile.allCases.count)
      var transitions: [SubtitleTransitionEvidence] = []
      var samples: [SubtitleProcessSample] = []
      let support = Dictionary(
        uniqueKeysWithValues: SubtitleProfile.supportProfiles.map { ($0.supportKey, "app-played") }
      )

      try play(.baseline)
      try await waitForPlayback(.baseline)
      try await waitUntil("Native PiP did not become possible", timeout: .seconds(30)) {
        controller?.isPossible == true
      }
      guard controller?.overlaySupport == .composited else {
        throw SubtitleMatrixFailure("Linked native backend does not advertise overlay composition")
      }
      guard controller?.start() == .accepted else {
        throw SubtitleMatrixFailure("Native PiP start was not accepted")
      }
      try await waitUntil("Native PiP did not become active", timeout: .seconds(30)) {
        controller?.isActive == true
      }

      for (index, profile) in SubtitleProfile.allCases.enumerated() {
        try Task.checkCancellation()
        if index > 0 {
          player.withMarquee { $0.hide() }
          try play(profile)
          try await waitForPlayback(profile)
          try await waitUntil("PiP did not survive \(profile.rawValue) replacement", timeout: .seconds(30)) {
            controller?.isActive == true
          }
        }
        if profile == .osd {
          player.withMarquee {
            $0.show(
              text: "SWIFTVLC OSD MATRIX  %H:%M:%S",
              fontSize: 36,
              color: 0xFFFF00,
              position: OverlayPosition.bottomRight.rawValue
            )
          }
        }
        // The UI test treats this label as the readiness signal for its
        // SpringBoard capture. Publish it only after replacement, subtitle
        // selection, PiP survival, and OSD setup have all settled.
        profileName = profile.rawValue

        let phaseStarted = ProcessInfo.processInfo.systemUptime
        var paused = false
        var pausePassed = false
        var seekAttempted = false
        var seekAccepted: Bool?
        var selectedSubtitle = profile == .baseline || profile == .osd
        var previousStatistics = player.statistics
        var displayedPictures: UInt64 = 0
        var lostPictures: UInt64 = 0

        while Int(ProcessInfo.processInfo.systemUptime - phaseStarted) < phaseSeconds {
          try Task.checkCancellation()
          let phaseElapsed = Int(ProcessInfo.processInfo.systemUptime - phaseStarted)
          let totalElapsed = Int(ProcessInfo.processInfo.systemUptime - started)
          progress = "\(totalElapsed)s / \(durationSeconds)s"
          if profile.expectsSubtitle, !selectedSubtitle, let track = player.subtitleTracks.first {
            player.selectedSubtitleTrack = track
            selectedSubtitle = true
          }
          if phaseElapsed >= 15, !paused {
            player.pause()
            try await waitUntil("Pause did not settle", timeout: .seconds(10)) { !player.isActive }
            try await Task.sleep(for: .seconds(2))
            player.resume()
            try await waitUntil("Resume did not settle", timeout: .seconds(10)) { player.isActive }
            pausePassed = true
            paused = true
          }
          if phaseElapsed >= 30, !seekAttempted {
            seekAccepted = profile.isLive ? nil : player.jump(by: .seconds(8))
            seekAttempted = true
          }
          if phaseElapsed.isMultiple(of: 5) {
            samples.append(Self.processSample(elapsed: totalElapsed, profile: profile.rawValue))
          }
          if let current = player.statistics {
            if let previousStatistics {
              displayedPictures &+= Self.delta(current.displayedPictures, previousStatistics.displayedPictures)
              lostPictures &+= Self.delta(current.lostPictures, previousStatistics.lostPictures)
            }
            previousStatistics = current
          }
          guard controller?.isActive == true else {
            throw SubtitleMatrixFailure("Native PiP stopped during \(profile.rawValue)")
          }
          try await Task.sleep(for: .seconds(1))
        }
        guard pausePassed else {
          throw SubtitleMatrixFailure("Pause/resume was not exercised for \(profile.rawValue)")
        }
        if !profile.isLive, seekAccepted != true {
          throw SubtitleMatrixFailure("Seek was not accepted for \(profile.rawValue)")
        }
        if profile.expectsSubtitle, !selectedSubtitle {
          throw SubtitleMatrixFailure("No subtitle track appeared for \(profile.rawValue)")
        }
        let pictureTotal = displayedPictures + lostPictures
        let dropRate = pictureTotal > 0 ? Double(lostPictures) / Double(pictureTotal) : 1
        guard displayedPictures > 0, dropRate <= 0.10 else {
          throw SubtitleMatrixFailure("\(profile.rawValue) exceeded the presentation budget")
        }
        transitions.append(
          SubtitleTransitionEvidence(
            profile: profile.rawValue,
            pauseResume: "pass",
            seek: profile.isLive ? "not-applicable-live" : "pass",
            replacement: index == 0 ? "initial" : "pass",
            selectedSubtitle: selectedSubtitle,
            displayedPictures: displayedPictures,
            lostPictures: lostPictures,
            dropRate: dropRate,
            pipRemainedActive: true
          )
        )
      }

      let adaptive = try await adaptiveMetrics()
      guard
        Set(adaptive.variants) == ["low", "high"],
        adaptive.successfulSegmentsByVariant["low", default: 0] > 0,
        adaptive.successfulSegmentsByVariant["high", default: 0] > 0
      else {
        throw SubtitleMatrixFailure("Adaptive subtitle phases did not change resolution")
      }
      let elapsedBeforeMinimum = Int(ProcessInfo.processInfo.systemUptime - started)
      if elapsedBeforeMinimum < durationSeconds {
        try await Task.sleep(for: .seconds(durationSeconds - elapsedBeforeMinimum))
      }
      guard controller?.isActive == true else {
        throw SubtitleMatrixFailure("Native PiP stopped before the minimum duration")
      }
      let completedDuration = Int(ProcessInfo.processInfo.systemUptime - started)
      samples.append(Self.processSample(elapsed: completedDuration, profile: "complete"))
      let cpuStart = samples.first?.cpuSeconds ?? 0
      let cpuEnd = samples.last?.cpuSeconds ?? cpuStart
      let evidence = NativeSubtitleEvidence(
        durationSeconds: completedDuration,
        phaseSeconds: phaseSeconds,
        profileSequence: SubtitleProfile.allCases.map(\.rawValue),
        supportMatrix: support,
        timingTransitions: transitions,
        adaptiveResolution: adaptive,
        metrics: NativeSubtitleMetrics(
          cpu: NativeSubtitleCPUMetric(
            value: max(0, cpuEnd - cpuStart),
            unit: "cpu-seconds",
            source: "Mach task thread times",
            hostTraceStatus: "required-host-augmentation"
          ),
          gpu: NativeSubtitleTraceMetric(
            status: "required-host-augmentation",
            source: "Instruments Game Performance"
          ),
          colorHDRImpact: NativeSubtitleColorMetric(
            sourceCodec: "hevc",
            sourcePixelFormat: "yuv420p10le",
            colorPrimaries: "bt2020",
            transferFunction: "smpte2084",
            matrix: "bt2020nc",
            screenshotMeasurements: "required-ui-augmentation",
            hostTraceStatus: "required-host-augmentation"
          ),
          thermalStates: Array(Set(samples.map(\.thermalState))).sorted(),
          samples: samples
        ),
        hostTraceRequirements: [
          "cpu": "Time Profiler",
          "gpu": "Game Performance",
          "colorHDRImpact": "Metal System Trace"
        ]
      )
      result = try "pass:\(JSONEncoder().encode(evidence).base64EncodedString())"
      progress = "\(completedDuration)s / \(durationSeconds)s"
      profileName = "complete"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      controller?.stop()
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func play(_ profile: SubtitleProfile) throws {
    guard let baseURL else { throw SubtitleMatrixFailure("Missing fixture origin") }
    let mediaURL: URL = switch profile {
    case .live:
      baseURL.appending(path: "live/subtitles/live.ts")
    case .adaptiveLow:
      baseURL.appending(path: "adaptive/\(token)/abr-low-ts/master.m3u8")
    case .adaptiveHigh:
      baseURL.appending(path: "adaptive/\(token)/abr-high-fmp4/master.m3u8")
    default:
      baseURL.appending(path: "files/subtitles/\(profile.fileName)")
    }
    let media = try Media(url: qualificationURL(mediaURL))
    if profile.isAdaptive {
      try media.addSlave(
        from: baseURL.appending(path: "files/subtitles/text.srt"),
        type: .subtitle
      )
    }
    try player.play(media)
  }

  private func qualificationURL(_ url: URL) throws -> URL {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
      throw SubtitleMatrixFailure("Could not bind the fixture URL to this run")
    }
    var queryItems = components.queryItems ?? []
    queryItems.append(URLQueryItem(name: "swiftvlcQualification", value: token))
    components.queryItems = queryItems
    guard let qualified = components.url else {
      throw SubtitleMatrixFailure("Could not construct the candidate-bound fixture URL")
    }
    return qualified
  }

  private func waitForPlayback(_ profile: SubtitleProfile) async throws {
    try await waitUntil("\(profile.rawValue) did not start", timeout: .seconds(30)) {
      player.state == .playing
    }
    if profile.expectsSubtitle {
      try await waitUntil("\(profile.rawValue) published no subtitle track", timeout: .seconds(30)) {
        !player.subtitleTracks.isEmpty
      }
      if let track = player.subtitleTracks.first {
        player.selectedSubtitleTrack = track
      }
      try await waitUntil("\(profile.rawValue) subtitle selection did not settle", timeout: .seconds(10)) {
        player.selectedSubtitleTrack != nil
      }
    }
  }

  private func adaptiveMetrics() async throws -> AdaptiveSubtitleEvidence {
    guard let url = baseURL?.appending(path: "adaptive/\(token)/metrics") else {
      throw SubtitleMatrixFailure("Missing adaptive metrics endpoint")
    }
    let (data, response) = try await URLSession.shared.data(from: url)
    guard
      (response as? HTTPURLResponse)?.statusCode == 200,
      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw SubtitleMatrixFailure("Adaptive metrics request failed") }
    return AdaptiveSubtitleEvidence(
      variants: payload["variants"] as? [String] ?? [],
      variantTransitions: payload["variantTransitions"] as? Int ?? 0,
      successfulSegments: payload["successfulSegments"] as? Int ?? 0,
      successfulSegmentsByVariant: payload["successfulSegmentsByVariant"]
        as? [String: Int] ?? [:]
    )
  }

  private func waitUntil(_ failure: String, timeout: Duration, condition: @escaping @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else { throw SubtitleMatrixFailure(failure) }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack { Text(title); Spacer(); Text(value).foregroundStyle(.secondary).accessibilityIdentifier(identifier) }
  }

  private static func delta(_ current: UInt64, _ previous: UInt64) -> UInt64 {
    current >= previous ? current - previous : current
  }

  private static func processSample(elapsed: Int, profile: String) -> SubtitleProcessSample {
    var basic = mach_task_basic_info()
    var basicCount = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let basicStatus = withUnsafeMutablePointer(to: &basic) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &basicCount)
      }
    }
    var times = task_thread_times_info()
    var timesCount = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<natural_t>.size)
    let timesStatus = withUnsafeMutablePointer(to: &times) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(timesCount)) {
        task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &timesCount)
      }
    }
    let cpu = timesStatus == KERN_SUCCESS
      ? Double(times.user_time.seconds + times.system_time.seconds)
      + Double(times.user_time.microseconds + times.system_time.microseconds) / 1_000_000
      : 0
    return SubtitleProcessSample(
      elapsedSeconds: elapsed,
      profile: profile,
      residentBytes: basicStatus == KERN_SUCCESS ? basic.resident_size : 0,
      cpuSeconds: cpu,
      thermalState: ProcessInfo.processInfo.thermalState.subtitleQualificationName
    )
  }
}

private enum SubtitleProfile: String, CaseIterable {
  case baseline, text, styled, bitmap, forced, live
  case adaptiveLow = "adaptive-low"
  case adaptiveHigh = "adaptive-high"
  case hdr, osd

  static let supportProfiles: [SubtitleProfile] = [.text, .styled, .bitmap, .forced, .live, .osd]
  var supportKey: String {
    rawValue
  }

  var isLive: Bool {
    self == .live
  }

  var isAdaptive: Bool {
    self == .adaptiveLow || self == .adaptiveHigh
  }

  var expectsSubtitle: Bool {
    self != .baseline && self != .osd
  }

  var fileName: String {
    switch self {
    case .baseline, .osd: "base.mp4"
    case .hdr: "hdr-text.mkv"
    case .text, .styled, .bitmap, .forced: "\(rawValue).mkv"
    case .live: "live.ts"
    case .adaptiveLow, .adaptiveHigh: "text.srt"
    }
  }
}

private struct SubtitleProcessSample: Encodable {
  let elapsedSeconds: Int
  let profile: String
  let residentBytes: UInt64
  let cpuSeconds: Double
  let thermalState: String
}

private struct SubtitleTransitionEvidence: Encodable {
  let profile: String
  let pauseResume: String
  let seek: String
  let replacement: String
  let selectedSubtitle: Bool
  let displayedPictures: UInt64
  let lostPictures: UInt64
  let dropRate: Double
  let pipRemainedActive: Bool
}

private struct AdaptiveSubtitleEvidence: Encodable {
  let variants: [String]
  let variantTransitions: Int
  let successfulSegments: Int
  let successfulSegmentsByVariant: [String: Int]
}

private struct NativeSubtitleEvidence: Encodable {
  let durationSeconds: Int
  let phaseSeconds: Int
  let profileSequence: [String]
  let supportMatrix: [String: String]
  let timingTransitions: [SubtitleTransitionEvidence]
  let adaptiveResolution: AdaptiveSubtitleEvidence
  let metrics: NativeSubtitleMetrics
  let hostTraceRequirements: [String: String]
}

private struct NativeSubtitleMetrics: Encodable {
  let cpu: NativeSubtitleCPUMetric
  let gpu: NativeSubtitleTraceMetric
  let colorHDRImpact: NativeSubtitleColorMetric
  let thermalStates: [String]
  let samples: [SubtitleProcessSample]
}

private struct NativeSubtitleCPUMetric: Encodable {
  let value: Double
  let unit: String
  let source: String
  let hostTraceStatus: String
}

private struct NativeSubtitleTraceMetric: Encodable { let status: String; let source: String }

private struct NativeSubtitleColorMetric: Encodable {
  let sourceCodec: String
  let sourcePixelFormat: String
  let colorPrimaries: String
  let transferFunction: String
  let matrix: String
  let screenshotMeasurements: String
  let hostTraceStatus: String
}

private struct SubtitleMatrixFailure: Error, CustomStringConvertible {
  let description: String
  init(_ description: String) {
    self.description = description
  }
}

extension ProcessInfo.ThermalState {
  fileprivate var subtitleQualificationName: String {
    switch self {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious"
    case .critical: "critical"
    @unknown default: "unknown"
    }
  }
}
