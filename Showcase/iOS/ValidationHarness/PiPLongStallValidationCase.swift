import Darwin
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-bound recovery exercise for an externally gated network stall.
/// The UI test triggers the fixture only after system PiP is active, avoiding
/// false passes where libVLC prefetched through a byte-position-based stall.
struct PiPLongStallValidationCase: View {
  @State private var player = Player()
  @State private var controller: PiPController?
  @State private var lifecycleEvents: [String] = []
  @State private var healthEvents: [String] = []
  @State private var stallObservation: StallObservation?
  @State private var bufferingBeganAt: ContinuousClock.Instant?
  @State private var result = "not-run"
  @State private var playbackError: String?
  @State private var isRunning = false
  @State private var baselineResidentBytes: UInt64 = 0
  @State private var peakResidentBytes: UInt64 = 0
  @State private var memorySampler: Task<Void, Never>?

  private var renderingPath: LongStallRenderingPath {
    LongStallRenderingPath(
      rawValue: LaunchArguments.pipRenderingPathValue ?? "native"
    ) ?? .native
  }

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        videoSurface
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(AccessibilityID.PiPLongStallValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.PiPLongStallValidation.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.PiPLongStallValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.PiPLongStallValidation.activeLabel
        )
        valueRow(
          "Playback health",
          value: healthEvents.last ?? "none",
          identifier: AccessibilityID.PiPLongStallValidation.healthLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.PiPLongStallValidation.resultLabel
        )
      }

      Section("Picture in Picture") {
        Button("Arm sustained-stall qualification") {
          Task { await runQualification() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPLongStallValidation.runButton)
        .disabled(isRunning || controller?.isPossible != true || player.state != .playing)

        Button("Trigger controlled network stall") {
          Task { await triggerStall() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPLongStallValidation.triggerButton)
        .disabled(result != "armed" || controller?.isActive != true)

        Button("Stop and finalize evidence") {
          Task { await stopAndFinalize() }
        }
        .accessibilityIdentifier(AccessibilityID.PiPLongStallValidation.stopButton)
        .disabled(result != "ready-for-stop" || controller?.isActive != true)

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.PiPLongStallValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("PiP stall recovery")
    .task { startPlayback() }
    .task(id: controller.map(ObjectIdentifier.init)) {
      lifecycleEvents.removeAll()
      guard let controller else { return }
      for await envelope in controller.pipEventEnvelopes {
        lifecycleEvents.append(envelope.event.longStallQualificationName)
      }
    }
    .task(id: player.generation) {
      healthEvents.removeAll()
      stallObservation = nil
      bufferingBeganAt = nil
      for await event in player.playbackHealthEvents {
        recordHealthEvent(event)
      }
    }
    .task(id: player.generation) {
      for await snapshot in player.playbackHealthSnapshots {
        recordHealthSnapshot(snapshot)
      }
    }
    .onDisappear {
      memorySampler?.cancel()
      controller?.stop()
      player.stop()
    }
  }

  @ViewBuilder
  private var videoSurface: some View {
    switch renderingPath {
    case .native:
      PiPVideoView(player, controller: $controller, startsAutomaticallyFromInline: false)
    case .direct:
      DirectPiPValidationSurface(player: player, controller: $controller)
    }
  }

  private func startPlayback() {
    guard let url = LaunchArguments.pipLiveURLValue else {
      playbackError = "Missing gated-stall validation stream"
      return
    }
    do {
      try player.play(url: url)
    } catch {
      playbackError = String(describing: error)
    }
  }

  private func runQualification() async {
    guard let controller else { return }
    isRunning = true
    result = "starting"
    playbackError = nil
    healthEvents.removeAll()
    stallObservation = nil
    bufferingBeganAt = nil
    do {
      guard controller.start() == .accepted else {
        throw LongStallQualificationFailure("PiP start was not accepted")
      }
      try await waitUntil("PiP did not become active") { controller.isActive }
      try await waitUntil("Playback did not become healthy") {
        if case .healthy = player.playbackHealth.state {
          return true
        }
        return false
      }
      baselineResidentBytes = Self.residentBytes()
      guard baselineResidentBytes > 0 else {
        throw LongStallQualificationFailure("Resident-memory sampling failed")
      }
      peakResidentBytes = baselineResidentBytes
      startMemorySampling()
      result = "armed"
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
      controller.stop()
    }
    isRunning = false
  }

  private func recordHealthEvent(_ event: PlaybackHealthEvent) {
    switch event.kind {
    case .stalled(let reason):
      let name = String(describing: reason)
      healthEvents.append("stalled:\(name)")
      stallObservation = StallObservation(
        reason: name,
        stalledAtMilliseconds: event.snapshot.lastStalledAt.map(Self.milliseconds),
        recoveredAtMilliseconds: nil,
        durationMilliseconds: nil
      )
    case .recovered(let reason):
      let name = String(describing: reason)
      healthEvents.append("recovered:\(name)")
      guard var observation = stallObservation, observation.reason == name else { return }
      observation.recoveredAtMilliseconds = event.snapshot.lastRecoveredAt.map(Self.milliseconds)
      if
        let stalledAt = observation.stalledAtMilliseconds,
        let recoveredAt = observation.recoveredAtMilliseconds {
        observation.durationMilliseconds = recoveredAt - stalledAt
      }
      stallObservation = observation
      if isFaultArmed, controller?.isActive == true {
        result = "ready-for-stop"
      }
    case .terminalFailure(let failure):
      healthEvents.append("terminalFailure:\(String(describing: failure))")
      playbackError = "Playback health reached a terminal failure"
      result = "failed"
    case .firstDecodedFrame:
      healthEvents.append("firstDecodedFrame")
    case .firstPresentedFrame:
      healthEvents.append("firstPresentedFrame")
    case .waiting(let reason):
      healthEvents.append("waiting:\(String(describing: reason))")
      if reason == .buffering, isFaultArmed, bufferingBeganAt == nil {
        bufferingBeganAt = ContinuousClock.now
      }
    }
  }

  private func recordHealthSnapshot(_ snapshot: PlaybackHealthSnapshot) {
    guard
      case .healthy = snapshot.state,
      let beganAt = bufferingBeganAt,
      stallObservation == nil,
      isFaultArmed,
      controller?.isActive == true
    else { return }
    let elapsed = Self.milliseconds(beganAt.duration(to: ContinuousClock.now))
    guard elapsed >= 2000 else { return }
    healthEvents.append("recovered:buffering")
    stallObservation = StallObservation(
      reason: "buffering",
      stalledAtMilliseconds: 0,
      recoveredAtMilliseconds: elapsed,
      durationMilliseconds: elapsed
    )
    result = "ready-for-stop"
  }

  private var isFaultArmed: Bool {
    result == "armed" || result == "triggering" || result == "triggered"
  }

  private func startMemorySampling() {
    memorySampler?.cancel()
    memorySampler = Task { @MainActor in
      while !Task.isCancelled {
        peakResidentBytes = max(peakResidentBytes, Self.residentBytes())
        try? await Task.sleep(for: .milliseconds(250))
      }
    }
  }

  private func triggerStall() async {
    guard
      let streamURL = LaunchArguments.pipLiveURLValue,
      var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
    else {
      playbackError = "Cannot construct controlled-stall trigger URL"
      result = "failed"
      return
    }
    components.path = "/fault/trigger/long-stall"
    components.query = nil
    components.fragment = nil
    guard let triggerURL = components.url else {
      playbackError = "Cannot construct controlled-stall trigger URL"
      result = "failed"
      return
    }
    result = "triggering"
    do {
      let (_, response) = try await URLSession.shared.data(from: triggerURL)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else {
        throw LongStallQualificationFailure("Fixture rejected controlled-stall trigger")
      }
      result = "triggered"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private func stopAndFinalize() async {
    guard let controller, let observation = stallObservation else { return }
    result = "stopping"
    memorySampler?.cancel()
    peakResidentBytes = max(peakResidentBytes, Self.residentBytes())
    do {
      guard
        let stalledAt = observation.stalledAtMilliseconds,
        let recoveredAt = observation.recoveredAtMilliseconds,
        let duration = observation.durationMilliseconds,
        duration >= 2000
      else {
        throw LongStallQualificationFailure("Observed stall was shorter than two seconds")
      }
      guard controller.isActive else {
        throw LongStallQualificationFailure("PiP stopped before recovery evidence finalized")
      }
      let memoryGrowthBytes = peakResidentBytes > baselineResidentBytes
        ? peakResidentBytes - baselineResidentBytes
        : 0
      let memoryLimitBytes: UInt64 = 96 * 1_048_576
      guard memoryGrowthBytes <= memoryLimitBytes else {
        throw LongStallQualificationFailure("Resident-memory growth exceeded 96 MiB")
      }

      controller.stop()
      try await waitUntil("PiP did not stop") { !controller.isActive }
      try await waitUntil("Programmatic stop event did not arrive") {
        lifecycleEvents.contains("didStop:programmatic")
      }
      guard lifecycleOrderPasses else {
        throw LongStallQualificationFailure("Lifecycle events were incomplete or reordered")
      }

      let unexpectedStops = lifecycleEvents.filter {
        $0.hasPrefix("didStop:") && $0 != "didStop:programmatic"
      }.count
      guard unexpectedStops == 0 else {
        throw LongStallQualificationFailure("PiP stopped unexpectedly during stall recovery")
      }
      let evidence = LongStallQualificationEvidence(
        backend: renderingPath.rawValue,
        orderedEvents: lifecycleEvents,
        healthEvents: healthEvents,
        events: LongStallEventEvidence(
          started: true,
          unexpectedStopCount: unexpectedStops,
          order: "pass"
        ),
        stall: LongStallEvidence(
          reason: observation.reason,
          stalledAtMilliseconds: stalledAt,
          recoveredAtMilliseconds: recoveredAt,
          durationMilliseconds: duration,
          activeAfterRecovery: true
        ),
        memory: LongStallMemoryEvidence(
          baselineResidentBytes: baselineResidentBytes,
          peakResidentBytes: peakResidentBytes,
          growthBytes: memoryGrowthBytes,
          limitBytes: memoryLimitBytes
        )
      )
      let data = try JSONEncoder().encode(evidence)
      result = "pass:\(data.base64EncodedString())"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
    }
  }

  private var lifecycleOrderPasses: Bool {
    let required = ["willStart", "didStart", "willStop:programmatic", "didStop:programmatic"]
    var searchStart = lifecycleEvents.startIndex
    for value in required {
      guard let index = lifecycleEvents[searchStart...].firstIndex(of: value) else { return false }
      searchStart = lifecycleEvents.index(after: index)
    }
    return true
  }

  private func waitUntil(
    _ failure: String,
    timeout: Duration = .seconds(15),
    condition: @escaping @MainActor () -> Bool
  )
    async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while !condition() {
      try Task.checkCancellation()
      guard clock.now < deadline else { throw LongStallQualificationFailure(failure) }
      try await Task.sleep(for: .milliseconds(50))
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

  private static func residentBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
      MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
      }
    }
    return status == KERN_SUCCESS ? info.resident_size : 0
  }

  private static func milliseconds(_ duration: Duration) -> Int64 {
    let components = duration.components
    return components.seconds * 1000 + Int64(components.attoseconds / 1_000_000_000_000_000)
  }
}

private enum LongStallRenderingPath: String {
  case native
  case direct
}

private struct StallObservation {
  let reason: String
  let stalledAtMilliseconds: Int64?
  var recoveredAtMilliseconds: Int64?
  var durationMilliseconds: Int64?
}

private struct LongStallQualificationEvidence: Encodable {
  let formatVersion = 1
  let scenario = "long-stall"
  let backend: String
  let orderedEvents: [String]
  let healthEvents: [String]
  let events: LongStallEventEvidence
  let stall: LongStallEvidence
  let memory: LongStallMemoryEvidence
}

private struct LongStallEventEvidence: Encodable {
  let started: Bool
  let unexpectedStopCount: Int
  let order: String
}

private struct LongStallEvidence: Encodable {
  let reason: String
  let stalledAtMilliseconds: Int64
  let recoveredAtMilliseconds: Int64
  let durationMilliseconds: Int64
  let activeAfterRecovery: Bool
}

private struct LongStallMemoryEvidence: Encodable {
  let baselineResidentBytes: UInt64
  let peakResidentBytes: UInt64
  let growthBytes: UInt64
  let limitBytes: UInt64
}

private struct LongStallQualificationFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension PiPEvent {
  fileprivate var longStallQualificationName: String {
    switch self {
    case .willStart: "willStart"
    case .didStart: "didStart"
    case .willStop(let reason): "willStop:\(String(describing: reason))"
    case .didStop(let reason): "didStop:\(String(describing: reason))"
    case .failedToStart: "failedToStart"
    }
  }
}
