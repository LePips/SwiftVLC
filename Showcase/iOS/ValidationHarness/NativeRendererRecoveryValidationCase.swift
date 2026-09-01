import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Candidate-side producer for the physical native-renderer recovery row.
/// The app records only native mechanics. The owning UI test independently
/// records moving pixels from the actual system Picture in Picture window.
struct NativeRendererRecoveryValidationCase: View {
  @State private var player = Player()
  @State private var loopingPlayer: MediaListPlayer?
  @State private var controller: PiPController?
  @State private var baseline: NativeRendererRecoveryEvidenceSnapshot?
  @State private var phase = "starting"
  @State private var result = "not-run"
  @State private var playbackError: String?
  @State private var isRunning = false

  private let mediaURL = LaunchArguments.nativeRendererRecoveryURLValue
    ?? LaunchArguments.fixtureURLValue
  private let observationDurationSeconds = max(
    1,
    min(30, LaunchArguments.nativeRendererRecoveryObservationDurationValue ?? 4)
  )

  var body: some View {
    _ = player.currentTime
    return Form {
      Section {
        PiPVideoView(
          player,
          controller: $controller,
          startsAutomaticallyFromInline: false
        )
        .frame(height: 220)
        .listRowInsets(EdgeInsets())
        .accessibilityIdentifier(AccessibilityID.NativeRendererRecoveryValidation.videoView)
      }

      Section("Measured state") {
        valueRow(
          "Playback",
          value: String(describing: player.state),
          identifier: AccessibilityID.NativeRendererRecoveryValidation.stateLabel
        )
        valueRow(
          "PiP possible",
          value: controller?.isPossible == true ? "yes" : "no",
          identifier: AccessibilityID.NativeRendererRecoveryValidation.possibleLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier: AccessibilityID.NativeRendererRecoveryValidation.activeLabel
        )
        valueRow(
          "Phase",
          value: phase,
          identifier: AccessibilityID.NativeRendererRecoveryValidation.phaseLabel
        )
        resultRow
      }

      Section("Real OS recovery") {
        Button("Prepare native PiP") {
          Task { await prepare() }
        }
        .accessibilityIdentifier(AccessibilityID.NativeRendererRecoveryValidation.prepareButton)
        .disabled(
          isRunning || phase != "starting" || controller?.isPossible != true
            || player.state != .playing
        )

        Button("Arm paused recovery") {
          Task { await arm() }
        }
        .accessibilityIdentifier(AccessibilityID.NativeRendererRecoveryValidation.armButton)
        .disabled(isRunning || phase != "ready" || controller?.isActive != true)

        Button("Evaluate foreground recovery") {
          Task { await evaluateForegroundRecovery() }
        }
        .accessibilityIdentifier(AccessibilityID.NativeRendererRecoveryValidation.evaluateButton)
        .disabled(isRunning || phase != "armed")

        Button("Resume for pixel oracle") {
          resumeForPixelOracle()
        }
        .accessibilityIdentifier(AccessibilityID.NativeRendererRecoveryValidation.resumeButton)
        .disabled(isRunning || !result.hasPrefix("pass:"))

        if let playbackError {
          Text(playbackError)
            .foregroundStyle(.red)
            .accessibilityIdentifier(AccessibilityID.NativeRendererRecoveryValidation.errorLabel)
        }
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Native renderer recovery")
    .task { startPlayback() }
    .onDisappear {
      controller?.stop()
      loopingPlayer?.stop()
    }
  }

  private var resultRow: some View {
    LabeledContent("Qualification", value: resultSummary)
      .qualificationAccessibilityValue(
        label: "Qualification",
        value: result,
        identifier: AccessibilityID.NativeRendererRecoveryValidation.resultLabel
      )
  }

  private var resultSummary: String {
    if result.hasPrefix("pass:") {
      return "pass"
    }
    if result.hasPrefix("not-exercised:") {
      return "not-exercised"
    }
    if result.hasPrefix("failed:") {
      return "failed"
    }
    return result
  }

  private func startPlayback() {
    guard let mediaURL else {
      playbackError = "Missing native renderer recovery fixture URL"
      phase = "failed"
      return
    }
    do {
      let media = try Media(url: mediaURL)
      let list = MediaList()
      try list.append(media)
      let loopingPlayer = MediaListPlayer()
      loopingPlayer.mediaPlayer = player
      loopingPlayer.mediaList = list
      loopingPlayer.playbackMode = .loop
      self.loopingPlayer = loopingPlayer
      loopingPlayer.play()
    } catch {
      playbackError = String(describing: error)
      phase = "failed"
    }
  }

  private func prepare() async {
    guard let controller else { return }
    await runAction {
      guard controller.isNativeRendererRecoveryQualificationAvailable else {
        throw NativeRendererRecoveryFailure(
          "Linked libVLC does not export native renderer recovery evidence"
        )
      }
      guard controller.start() == .accepted else {
        throw NativeRendererRecoveryFailure("Native PiP start was not accepted")
      }
      try await waitUntil("Native PiP did not become active") {
        controller.isActive
      }
      try await waitUntil("Native renderer did not publish a current recovery sample") {
        guard let snapshot = controller.nativeRendererRecoveryQualificationSnapshot else {
          return false
        }
        return snapshot.abiVersion == 1
          && snapshot.isCurrent
          && snapshot.hasRecoverySample
          && snapshot.successfulSubmissionCount > 0
          && !snapshot.requiresFlush
          && !snapshot.isFailed
          && !snapshot.isRecoveryInProgress
      }
      phase = "ready"
      result = "ready"
    }
  }

  private func arm() async {
    guard let controller else { return }
    await runAction {
      player.pause()
      try await waitUntil("Playback did not pause before the OS trigger") {
        player.state == .paused
      }
      guard
        let native = controller.nativeRendererRecoveryQualificationSnapshot,
        native.abiVersion == 1,
        native.isCurrent,
        native.hasRecoverySample,
        native.successfulSubmissionCount > 0,
        !native.requiresFlush,
        !native.isFailed,
        !native.isRecoveryInProgress
      else {
        throw NativeRendererRecoveryFailure(
          "Native renderer baseline was not current, healthy, and replayable"
        )
      }
      baseline = NativeRendererRecoveryEvidenceSnapshot(native)
      phase = "armed"
      result = "armed"
    }
  }

  private func evaluateForegroundRecovery() async {
    guard let controller, let baseline else { return }
    result = "evaluating"
    await runAction {
      guard player.state == .paused else {
        throw NativeRendererRecoveryFailure(
          "Playback was not paused when foreground recovery was evaluated"
        )
      }

      let deadline = ContinuousClock.now + .seconds(observationDurationSeconds)
      var latest: NativeRendererRecoveryMechanicsEvidence?
      repeat {
        guard let native = controller.nativeRendererRecoveryQualificationSnapshot else {
          throw NativeRendererRecoveryFailure(
            "Native renderer recovery snapshot became unavailable"
          )
        }
        latest = NativeRendererRecoveryEvidenceEvaluator.evaluate(
          baseline: baseline,
          postForeground: NativeRendererRecoveryEvidenceSnapshot(native)
        )
        if
          latest?.outcome == .pass
          || latest?.reason == "display-generation-changed"
          || latest?.reason == "permanent-renderer-failure" {
          break
        }
        try await Task.sleep(for: .milliseconds(250))
      } while
        ContinuousClock.now < deadline

      guard let mechanics = latest else {
        throw NativeRendererRecoveryFailure("No post-foreground snapshot was captured")
      }
      let evidence = NativeRendererRecoveryCaseEvidence(
        formatVersion: 1,
        scenario: "playback-foreground-displaylayer-recovery",
        renderingPath: "native",
        trigger: "real-os-home-background-foreground-v1",
        syntheticNotificationsPosted: false,
        playbackStateAtBaseline: "paused",
        playbackStateAtEvaluation: String(describing: player.state),
        mechanics: mechanics
      )
      let payload = try JSONEncoder().encode(evidence).base64EncodedString()
      result = "\(mechanics.outcome.rawValue):\(payload)"
    }
  }

  private func resumeForPixelOracle() {
    do {
      try player.play()
      phase = "resumed-for-pixel-oracle"
    } catch {
      playbackError = String(describing: error)
      phase = "failed"
    }
  }

  private func runAction(_ operation: () async throws -> Void) async {
    isRunning = true
    playbackError = nil
    defer { isRunning = false }
    do {
      try await operation()
    } catch is CancellationError {
      result = "cancelled"
    } catch {
      playbackError = String(describing: error)
      result = "failed"
      phase = "failed"
    }
  }

  private func waitUntil(
    _ message: String,
    timeout: Duration = .seconds(30),
    condition: () -> Bool
  )
    async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
      try Task.checkCancellation()
      guard ContinuousClock.now < deadline else {
        throw NativeRendererRecoveryFailure(message)
      }
      try await Task.sleep(for: .milliseconds(100))
    }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    LabeledContent(title, value: value)
      .qualificationAccessibilityValue(label: title, value: value, identifier: identifier)
  }
}

private struct NativeRendererRecoveryCaseEvidence: Codable {
  let formatVersion: Int
  let scenario: String
  let renderingPath: String
  let trigger: String
  let syntheticNotificationsPosted: Bool
  let playbackStateAtBaseline: String
  let playbackStateAtEvaluation: String
  let mechanics: NativeRendererRecoveryMechanicsEvidence
}

private struct NativeRendererRecoveryFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension NativeRendererRecoveryEvidenceSnapshot {
  fileprivate init(_ native: NativeSampleBufferRendererQualificationSnapshot) {
    self.init(
      abiVersion: native.abiVersion,
      rawFlags: native.rawFlags,
      displayGeneration: native.displayGeneration,
      recoveryEpisodeCount: native.recoveryEpisodeCount,
      recoveredEpisodeCount: native.recoveredEpisodeCount,
      requirementNotificationCount: native.requirementNotificationCount,
      revocationNotificationCount: native.revocationNotificationCount,
      decodeFailureNotificationCount: native.decodeFailureNotificationCount,
      foregroundCheckCount: native.foregroundCheckCount,
      recoveryFlushCount: native.recoveryFlushCount,
      revocationFlushCount: native.revocationFlushCount,
      failureFlushCount: native.failureFlushCount,
      discontinuityFlushCount: native.discontinuityFlushCount,
      successfulSubmissionCount: native.successfulSubmissionCount,
      recoverySubmissionCount: native.recoverySubmissionCount,
      retryableSubmissionCount: native.retryableSubmissionCount,
      recoverySampleFailureCount: native.recoverySampleFailureCount,
      permanentFailureCount: native.permanentFailureCount,
      isCurrent: native.isCurrent,
      requiresFlush: native.requiresFlush,
      isFailed: native.isFailed,
      isRecoveryInProgress: native.isRecoveryInProgress,
      hasRecoverySample: native.hasRecoverySample
    )
  }
}
