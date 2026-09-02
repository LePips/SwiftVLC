#if os(iOS)

import CLibVLC

/// Coherent native evidence for one Apple media-services recovery boundary.
///
/// This is release-qualification SPI rather than public playback API. It
/// exposes only counters and causal tokens already owned by the pinned native
/// engine; reading it performs no AVAudioSession or transport mutation.
@_spi(Qualification)
public struct AppleAudioRecoveryQualificationSnapshot: Sendable, Equatable {
  public enum BrokerPhase: String, Sendable, Equatable {
    case ready
    case lost
  }

  public enum CommandOrigin: String, Sendable, Equatable {
    case invalidating
    case explicitResume
  }

  public let version: UInt32
  public let brokerPhase: BrokerPhase
  public let commandOrigin: CommandOrigin
  public let brokerEpoch: UInt64
  public let brokerResetEpoch: UInt64
  public let commandGeneration: UInt64
  public let commandResetEpoch: UInt64
  public let acknowledgedResetEpoch: UInt64
  public let outputIncarnationCount: UInt64
  public let successfulRebuildCount: UInt64
  public let explicitResumeAttemptCount: UInt64
  public let explicitResumeFailureCount: UInt64
  public let commandWasDispatched: Bool
  public let liveOutputCount: UInt32
  public let brokerActiveOwnerCount: UInt32
  public let brokerLiveLeaseCount: UInt32
  public let brokerSuccessfulDeactivationCount: UInt64
  public let brokerFailedDeactivationCount: UInt64

  init?(_ native: swiftvlc_apple_audio_recovery_snapshot_t) {
    let expectedSize = UInt32(
      MemoryLayout<swiftvlc_apple_audio_recovery_snapshot_t>.size
    )
    guard native.version == 1, native.size == expectedSize else { return nil }
    guard native.command_dispatched == 0 || native.command_dispatched == 1 else {
      return nil
    }

    switch native.broker_phase {
    case UInt32(swiftvlc_apple_audio_media_services_ready.rawValue):
      brokerPhase = .ready
    case UInt32(swiftvlc_apple_audio_media_services_lost.rawValue):
      brokerPhase = .lost
    default:
      return nil
    }

    switch native.command_origin {
    case UInt32(swiftvlc_apple_audio_command_invalidating.rawValue):
      commandOrigin = .invalidating
    case UInt32(swiftvlc_apple_audio_command_explicit_resume.rawValue):
      commandOrigin = .explicitResume
    default:
      return nil
    }

    version = native.version
    brokerEpoch = native.broker_epoch
    brokerResetEpoch = native.broker_reset_epoch
    commandGeneration = native.command_generation
    commandResetEpoch = native.command_reset_epoch
    acknowledgedResetEpoch = native.acknowledged_reset_epoch
    outputIncarnationCount = native.output_incarnation_count
    successfulRebuildCount = native.successful_rebuild_count
    explicitResumeAttemptCount = native.explicit_resume_attempt_count
    explicitResumeFailureCount = native.explicit_resume_failure_count
    commandWasDispatched = native.command_dispatched == 1
    liveOutputCount = native.live_output_count
    brokerActiveOwnerCount = native.broker_active_owner_count
    brokerLiveLeaseCount = native.broker_live_lease_count
    brokerSuccessfulDeactivationCount =
      native.broker_successful_deactivation_count
    brokerFailedDeactivationCount = native.broker_failed_deactivation_count
  }
}

extension Player {
  /// Reads the exact native reset command/output snapshot for the current
  /// media-player handle. Returns nil when the linked artifact predates the
  /// version-8 contract or returns a malformed layout.
  @_spi(Qualification)
  public var appleAudioRecoveryQualificationSnapshot:
    AppleAudioRecoveryQualificationSnapshot? {
    var native = swiftvlc_apple_audio_recovery_snapshot_t()
    native.version = 1
    native.size = UInt32(
      MemoryLayout<swiftvlc_apple_audio_recovery_snapshot_t>.size
    )
    guard
      swiftvlc_libvlc_media_player_get_apple_audio_recovery_snapshot(
        pointer,
        &native
      )
    else { return nil }
    return AppleAudioRecoveryQualificationSnapshot(native)
  }
}

#endif
