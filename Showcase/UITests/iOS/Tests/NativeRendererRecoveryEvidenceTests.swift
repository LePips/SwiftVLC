import XCTest

final class NativeRendererRecoveryEvidenceTests: XCTestCase {
  func test_realRevocationAndCompleteRecoveryPasses() {
    let evidence = NativeRendererRecoveryEvidenceEvaluator.evaluate(
      baseline: snapshot(successfulSubmissions: 20),
      postForeground: snapshot(
        recoveryEpisodes: 1,
        recoveredEpisodes: 1,
        requirementNotifications: 1,
        revocationNotifications: 1,
        foregroundChecks: 1,
        recoveryFlushes: 1,
        revocationFlushes: 1,
        successfulSubmissions: 21,
        recoverySubmissions: 1
      )
    )

    XCTAssertEqual(evidence.outcome, .pass)
    XCTAssertTrue(evidence.checks.actualResourceRevocationObserved)
    XCTAssertTrue(evidence.checks.episodesBalanced)
  }

  func test_foregroundWithoutResourceRevocationIsNotExercised() {
    let evidence = NativeRendererRecoveryEvidenceEvaluator.evaluate(
      baseline: snapshot(successfulSubmissions: 20),
      postForeground: snapshot(
        foregroundChecks: 1,
        successfulSubmissions: 20
      )
    )

    XCTAssertEqual(evidence.outcome, .notExercised)
    XCTAssertEqual(evidence.reason, "os-resource-revocation-not-observed")
    XCTAssertFalse(evidence.checks.actualResourceRevocationObserved)
  }

  func test_observedRevocationWithoutRecoveryFails() {
    let evidence = NativeRendererRecoveryEvidenceEvaluator.evaluate(
      baseline: snapshot(successfulSubmissions: 20),
      postForeground: snapshot(
        recoveryEpisodes: 1,
        requirementNotifications: 1,
        revocationNotifications: 1,
        foregroundChecks: 1,
        recoveryFlushes: 1,
        revocationFlushes: 1,
        successfulSubmissions: 20,
        isRecoveryInProgress: true
      )
    )

    XCTAssertEqual(evidence.outcome, .failed)
    XCTAssertEqual(evidence.reason, "observed-revocation-did-not-complete-recovery")
    XCTAssertFalse(evidence.checks.recoverySubmissionAdvanced)
  }

  func test_displayGenerationChangeCannotProveRecovery() {
    let evidence = NativeRendererRecoveryEvidenceEvaluator.evaluate(
      baseline: snapshot(displayGeneration: 7, successfulSubmissions: 20),
      postForeground: snapshot(
        displayGeneration: 8,
        foregroundChecks: 1,
        successfulSubmissions: 20
      )
    )

    XCTAssertEqual(evidence.outcome, .failed)
    XCTAssertEqual(evidence.reason, "display-generation-changed")
  }

  func test_permanentFailureCannotPassEvenWithRecoveryCounters() {
    let evidence = NativeRendererRecoveryEvidenceEvaluator.evaluate(
      baseline: snapshot(successfulSubmissions: 20),
      postForeground: snapshot(
        recoveryEpisodes: 1,
        recoveredEpisodes: 1,
        requirementNotifications: 1,
        revocationNotifications: 1,
        foregroundChecks: 1,
        recoveryFlushes: 1,
        revocationFlushes: 1,
        successfulSubmissions: 21,
        recoverySubmissions: 1,
        permanentFailures: 1,
        isFailed: true
      )
    )

    XCTAssertEqual(evidence.outcome, .failed)
    XCTAssertEqual(evidence.reason, "permanent-renderer-failure")
  }

  private func snapshot(
    displayGeneration: UInt64 = 7,
    recoveryEpisodes: UInt64 = 0,
    recoveredEpisodes: UInt64 = 0,
    requirementNotifications: UInt64 = 0,
    revocationNotifications: UInt64 = 0,
    foregroundChecks: UInt64 = 0,
    recoveryFlushes: UInt64 = 0,
    revocationFlushes: UInt64 = 0,
    successfulSubmissions: UInt64 = 0,
    recoverySubmissions: UInt64 = 0,
    permanentFailures: UInt64 = 0,
    isFailed: Bool = false,
    isRecoveryInProgress: Bool = false
  ) -> NativeRendererRecoveryEvidenceSnapshot {
    NativeRendererRecoveryEvidenceSnapshot(
      abiVersion: 1,
      rawFlags: 0,
      displayGeneration: displayGeneration,
      recoveryEpisodeCount: recoveryEpisodes,
      recoveredEpisodeCount: recoveredEpisodes,
      requirementNotificationCount: requirementNotifications,
      revocationNotificationCount: revocationNotifications,
      decodeFailureNotificationCount: 0,
      foregroundCheckCount: foregroundChecks,
      recoveryFlushCount: recoveryFlushes,
      revocationFlushCount: revocationFlushes,
      failureFlushCount: 0,
      discontinuityFlushCount: 0,
      successfulSubmissionCount: successfulSubmissions,
      recoverySubmissionCount: recoverySubmissions,
      retryableSubmissionCount: 0,
      recoverySampleFailureCount: 0,
      permanentFailureCount: permanentFailures,
      isCurrent: true,
      requiresFlush: false,
      isFailed: isFailed,
      isRecoveryInProgress: isRecoveryInProgress,
      hasRecoverySample: true
    )
  }
}
