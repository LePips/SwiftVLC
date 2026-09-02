#if os(iOS)

@_spi(Qualification) @testable import SwiftVLC
import CLibVLC
import Testing

@Suite(.tags(.logic))
struct AppleAudioRecoveryQualificationSnapshotTests {
  private func nativeSnapshot() -> swiftvlc_apple_audio_recovery_snapshot_t {
    var snapshot = swiftvlc_apple_audio_recovery_snapshot_t()
    snapshot.version = 1
    snapshot.size = UInt32(
      MemoryLayout<swiftvlc_apple_audio_recovery_snapshot_t>.size
    )
    snapshot.broker_phase = UInt32(
      swiftvlc_apple_audio_media_services_ready.rawValue
    )
    snapshot.command_origin = UInt32(
      swiftvlc_apple_audio_command_explicit_resume.rawValue
    )
    snapshot.broker_epoch = 11
    snapshot.broker_reset_epoch = 10
    snapshot.command_generation = 23
    snapshot.command_reset_epoch = 10
    snapshot.acknowledged_reset_epoch = 10
    snapshot.output_incarnation_count = 7
    snapshot.successful_rebuild_count = 3
    snapshot.explicit_resume_attempt_count = 2
    snapshot.explicit_resume_failure_count = 1
    snapshot.command_dispatched = 1
    snapshot.live_output_count = 2
    snapshot.broker_active_owner_count = 4
    snapshot.broker_live_lease_count = 2
    snapshot.broker_successful_deactivation_count = 5
    snapshot.broker_failed_deactivation_count = 1
    return snapshot
  }

  @Test
  func `Native recovery snapshot maps every causal field`() throws {
    let mapped = try #require(
      AppleAudioRecoveryQualificationSnapshot(nativeSnapshot())
    )

    #expect(mapped.version == 1)
    #expect(mapped.brokerPhase == .ready)
    #expect(mapped.commandOrigin == .explicitResume)
    #expect(mapped.brokerEpoch == 11)
    #expect(mapped.brokerResetEpoch == 10)
    #expect(mapped.commandGeneration == 23)
    #expect(mapped.commandResetEpoch == 10)
    #expect(mapped.acknowledgedResetEpoch == 10)
    #expect(mapped.outputIncarnationCount == 7)
    #expect(mapped.successfulRebuildCount == 3)
    #expect(mapped.explicitResumeAttemptCount == 2)
    #expect(mapped.explicitResumeFailureCount == 1)
    #expect(mapped.commandWasDispatched)
    #expect(mapped.liveOutputCount == 2)
    #expect(mapped.brokerActiveOwnerCount == 4)
    #expect(mapped.brokerLiveLeaseCount == 2)
    #expect(mapped.brokerSuccessfulDeactivationCount == 5)
    #expect(mapped.brokerFailedDeactivationCount == 1)
  }

  @Test
  func `Snapshot rejects ABI and Boolean mutations`() {
    var wrongVersion = nativeSnapshot()
    wrongVersion.version = 2
    #expect(AppleAudioRecoveryQualificationSnapshot(wrongVersion) == nil)

    var wrongSize = nativeSnapshot()
    wrongSize.size -= 1
    #expect(AppleAudioRecoveryQualificationSnapshot(wrongSize) == nil)

    var invalidDispatch = nativeSnapshot()
    invalidDispatch.command_dispatched = 2
    #expect(AppleAudioRecoveryQualificationSnapshot(invalidDispatch) == nil)

    var invalidPhase = nativeSnapshot()
    invalidPhase.broker_phase = 99
    #expect(AppleAudioRecoveryQualificationSnapshot(invalidPhase) == nil)

    var invalidOrigin = nativeSnapshot()
    invalidOrigin.command_origin = 99
    #expect(AppleAudioRecoveryQualificationSnapshot(invalidOrigin) == nil)
  }

  @Test
  func `Lost invalidating snapshot remains representable`() throws {
    var native = nativeSnapshot()
    native.broker_phase = UInt32(
      swiftvlc_apple_audio_media_services_lost.rawValue
    )
    native.command_origin = UInt32(
      swiftvlc_apple_audio_command_invalidating.rawValue
    )
    native.command_dispatched = 0

    let mapped = try #require(
      AppleAudioRecoveryQualificationSnapshot(native)
    )
    #expect(mapped.brokerPhase == .lost)
    #expect(mapped.commandOrigin == .invalidating)
    #expect(!mapped.commandWasDispatched)
  }
}

#endif
