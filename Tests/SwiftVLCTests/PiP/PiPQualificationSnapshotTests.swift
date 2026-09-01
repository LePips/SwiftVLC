#if os(iOS)
@_spi(Qualification) @testable import SwiftVLC
import AVKit
import CLibVLC
import CustomDump
import Testing

extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct PiPQualificationSnapshotTests {
    @Test
    func `qualification snapshot reports the policy applied to native and direct AVKit`() throws {
      let nativePlayer = Player(instance: TestInstance.shared)
      let backend = IOSNativePiPBackend()
      backend.attach(to: nativePlayer)
      let native = PiPController(player: nativePlayer, nativeBackend: backend)
      native.playbackStateObservation = .init(duration: nil, isSeekable: false)

      expectNoDifference(
        native.playbackQualificationSnapshot,
        PiPPlaybackQualificationSnapshot(
          requiresLinearPlayback: true,
          durationMilliseconds: nil,
          isSeekable: false
        )
      )
      expectNoDifference(
        native.nativePlaybackQualificationSnapshot,
        NativePiPPlaybackQualificationSnapshot(
          mediaGeneration: nativePlayer.playbackQualificationGeneration.value,
          durationMilliseconds: 0,
          currentTimeMilliseconds: 0,
          isSeekable: false
        )
      )

      let directPlayer = Player(instance: TestInstance.shared)
      let direct = PiPController(player: directPlayer)
      let avController = try #require(direct.pipController)
      avController.requiresLinearPlayback = false
      direct.playbackStateObservation = .init(duration: .seconds(42), isSeekable: true)

      expectNoDifference(
        direct.playbackQualificationSnapshot,
        PiPPlaybackQualificationSnapshot(
          requiresLinearPlayback: false,
          durationMilliseconds: 42000,
          isSeekable: true
        )
      )
      #expect(direct.nativePlaybackQualificationSnapshot == nil)
      #expect(direct.nativeRendererRecoveryQualificationSnapshot == nil)
    }

    @Test
    func `native renderer qualification preserves every coherent counter and flag`() throws {
      var native = swiftvlc_sample_buffer_renderer_snapshot_t()
      native.abi_version = 1
      native.flags = UInt32(
        swiftvlc_sample_buffer_renderer_current.rawValue
          | swiftvlc_sample_buffer_renderer_failed.rawValue
          | swiftvlc_sample_buffer_renderer_recovery_sample_available.rawValue
      )
      native.display_generation = 11
      native.recovery_episode_count = 12
      native.recovered_episode_count = 13
      native.requirement_notification_count = 14
      native.revocation_notification_count = 15
      native.decode_failure_notification_count = 16
      native.foreground_check_count = 17
      native.recovery_flush_count = 18
      native.revocation_flush_count = 19
      native.failure_flush_count = 20
      native.discontinuity_flush_count = 21
      native.successful_submission_count = 22
      native.recovery_submission_count = 23
      native.retryable_submission_count = 24
      native.recovery_sample_failure_count = 25
      native.permanent_failure_count = 26

      let snapshot = try #require(
        NativeSampleBufferRendererQualificationSnapshot(native)
      )
      #expect(snapshot.abiVersion == 1)
      #expect(snapshot.displayGeneration == 11)
      #expect(snapshot.recoveryEpisodeCount == 12)
      #expect(snapshot.recoveredEpisodeCount == 13)
      #expect(snapshot.requirementNotificationCount == 14)
      #expect(snapshot.revocationNotificationCount == 15)
      #expect(snapshot.decodeFailureNotificationCount == 16)
      #expect(snapshot.foregroundCheckCount == 17)
      #expect(snapshot.recoveryFlushCount == 18)
      #expect(snapshot.revocationFlushCount == 19)
      #expect(snapshot.failureFlushCount == 20)
      #expect(snapshot.discontinuityFlushCount == 21)
      #expect(snapshot.successfulSubmissionCount == 22)
      #expect(snapshot.recoverySubmissionCount == 23)
      #expect(snapshot.retryableSubmissionCount == 24)
      #expect(snapshot.recoverySampleFailureCount == 25)
      #expect(snapshot.permanentFailureCount == 26)
      #expect(snapshot.isCurrent)
      #expect(!snapshot.requiresFlush)
      #expect(snapshot.isFailed)
      #expect(!snapshot.isRecoveryInProgress)
      #expect(snapshot.hasRecoverySample)
    }

    @Test
    func `Native renderer snapshot rejects an unknown ABI version`() {
      var native = swiftvlc_sample_buffer_renderer_snapshot_t()
      native.abi_version = 2

      #expect(NativeSampleBufferRendererQualificationSnapshot(native) == nil)
    }
  }
}
#endif
