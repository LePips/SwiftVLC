import AVFoundation
import Foundation
@_spi(Qualification) import SwiftVLC

@MainActor
enum AppleAudioQualificationSupport {
  static func nativeRecord(
    from value: AppleAudioRecoveryQualificationSnapshot
  ) -> AppleAudioNativeRecoveryRecord {
    AppleAudioNativeRecoveryRecord(
      version: value.version,
      brokerPhase: value.brokerPhase.rawValue,
      commandOrigin: value.commandOrigin.rawValue,
      brokerEpoch: value.brokerEpoch,
      brokerResetEpoch: value.brokerResetEpoch,
      commandGeneration: value.commandGeneration,
      commandResetEpoch: value.commandResetEpoch,
      acknowledgedResetEpoch: value.acknowledgedResetEpoch,
      outputIncarnationCount: value.outputIncarnationCount,
      successfulRebuildCount: value.successfulRebuildCount,
      explicitResumeAttemptCount: value.explicitResumeAttemptCount,
      explicitResumeFailureCount: value.explicitResumeFailureCount,
      commandWasDispatched: value.commandWasDispatched,
      liveOutputCount: value.liveOutputCount,
      brokerActiveOwnerCount: value.brokerActiveOwnerCount,
      brokerLiveLeaseCount: value.brokerLiveLeaseCount,
      brokerSuccessfulDeactivationCount:
      value.brokerSuccessfulDeactivationCount,
      brokerFailedDeactivationCount: value.brokerFailedDeactivationCount
    )
  }

  static func playbackRecord(from player: Player) -> AppleAudioPlaybackCounterRecord {
    let statistics = player.statistics
    return AppleAudioPlaybackCounterRecord(
      mediaTimeMilliseconds: player.currentTime.milliseconds,
      decodedAudio: statistics?.decodedAudio ?? 0,
      playedAudioBuffers: statistics?.playedAudioBuffers ?? 0,
      lostAudioBuffers: statistics?.lostAudioBuffers ?? 0,
      decodedVideo: statistics?.decodedVideo ?? 0,
      displayedPictures: statistics?.displayedPictures ?? 0,
      lostPictures: statistics?.lostPictures ?? 0
    )
  }

  static func checkpoint(
    _ player: Player,
    timeout: Duration = .seconds(3)
  )
    async throws -> AppleAudioRecoveryCheckpoint {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    repeat {
      if let snapshot = player.appleAudioRecoveryQualificationSnapshot {
        return AppleAudioRecoveryCheckpoint(
          systemUptime: ProcessInfo.processInfo.systemUptime,
          playerState: player.state.description,
          playbackRequestedActive: player.isPlaybackRequestedActive,
          native: nativeRecord(from: snapshot),
          playback: playbackRecord(from: player)
        )
      }
      try await Task.sleep(for: .milliseconds(50))
    } while ContinuousClock.now < deadline
    throw AppleAudioQualificationFailure("Native recovery snapshot stayed unstable")
  }

  static func sessionRecord(
    _ session: AVAudioSession = .sharedInstance()
  ) -> AppleAudioSessionConfigurationRecord {
    AppleAudioSessionConfigurationRecord(
      category: session.category.rawValue,
      mode: session.mode.rawValue,
      categoryOptionsRawValue: session.categoryOptions.rawValue,
      routeSharingPolicyRawValue: session.routeSharingPolicy.rawValue,
      preferredSampleRate: session.preferredSampleRate,
      preferredIOBufferDuration: session.preferredIOBufferDuration,
      preferredInputNumberOfChannels: session.preferredInputNumberOfChannels,
      preferredOutputNumberOfChannels: session.preferredOutputNumberOfChannels
    )
  }

  static func waitUntil(
    timeout: Duration,
    pollInterval: Duration = .milliseconds(100),
    _ predicate: @MainActor () throws -> Bool
  )
    async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    repeat {
      if try predicate() {
        return
      }
      try await Task.sleep(for: pollInterval)
    } while ContinuousClock.now < deadline
    throw AppleAudioQualificationFailure("Timed out waiting for device audio state")
  }

  static func encodedLabel(_ value: some Encodable) throws -> String {
    try "pass:\(JSONEncoder().encode(value).base64EncodedString())"
  }
}

struct AppleAudioQualificationFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
