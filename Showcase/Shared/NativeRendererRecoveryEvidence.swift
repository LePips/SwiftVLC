import Foundation

/// Machine-readable, candidate-produced state for one native Apple
/// sample-buffer renderer. This deliberately preserves the native counters;
/// screenshot evidence is recorded separately by the UI-test process.
struct NativeRendererRecoveryEvidenceSnapshot: Codable, Equatable {
  let abiVersion: UInt32
  let rawFlags: UInt32
  let displayGeneration: UInt64
  let recoveryEpisodeCount: UInt64
  let recoveredEpisodeCount: UInt64
  let requirementNotificationCount: UInt64
  let revocationNotificationCount: UInt64
  let decodeFailureNotificationCount: UInt64
  let foregroundCheckCount: UInt64
  let recoveryFlushCount: UInt64
  let revocationFlushCount: UInt64
  let failureFlushCount: UInt64
  let discontinuityFlushCount: UInt64
  let successfulSubmissionCount: UInt64
  let recoverySubmissionCount: UInt64
  let retryableSubmissionCount: UInt64
  let recoverySampleFailureCount: UInt64
  let permanentFailureCount: UInt64
  let isCurrent: Bool
  let requiresFlush: Bool
  let isFailed: Bool
  let isRecoveryInProgress: Bool
  let hasRecoverySample: Bool
}

struct NativeRendererRecoveryCounterDeltas: Codable, Equatable {
  let recoveryEpisodeCount: UInt64
  let recoveredEpisodeCount: UInt64
  let requirementNotificationCount: UInt64
  let revocationNotificationCount: UInt64
  let decodeFailureNotificationCount: UInt64
  let foregroundCheckCount: UInt64
  let recoveryFlushCount: UInt64
  let revocationFlushCount: UInt64
  let failureFlushCount: UInt64
  let discontinuityFlushCount: UInt64
  let successfulSubmissionCount: UInt64
  let recoverySubmissionCount: UInt64
  let retryableSubmissionCount: UInt64
  let recoverySampleFailureCount: UInt64
  let permanentFailureCount: UInt64
}

struct NativeRendererRecoveryChecks: Codable, Equatable {
  let sameDisplayGeneration: Bool
  let countersMonotonic: Bool
  let actualResourceRevocationObserved: Bool
  let requirementNotificationAdvanced: Bool
  let revocationNotificationAdvanced: Bool
  let foregroundCheckAdvanced: Bool
  let recoveryEpisodeAdvanced: Bool
  let recoveredEpisodeAdvanced: Bool
  let recoveryFlushAdvanced: Bool
  let revocationFlushAdvanced: Bool
  let successfulSubmissionAdvanced: Bool
  let recoverySubmissionAdvanced: Bool
  let permanentFailureUnchanged: Bool
  let episodesBalanced: Bool
  let currentRenderer: Bool
  let requiresFlushCleared: Bool
  let failedCleared: Bool
  let recoveryInProgressCleared: Bool
  let recoverySampleAvailable: Bool
}

enum NativeRendererRecoveryMechanicsOutcome: String, Codable, Equatable {
  case pass
  case notExercised = "not-exercised"
  case failed
}

struct NativeRendererRecoveryMechanicsEvidence: Codable, Equatable {
  let formatVersion: Int
  let outcome: NativeRendererRecoveryMechanicsOutcome
  let reason: String
  let baseline: NativeRendererRecoveryEvidenceSnapshot
  let postForeground: NativeRendererRecoveryEvidenceSnapshot
  let deltas: NativeRendererRecoveryCounterDeltas
  let checks: NativeRendererRecoveryChecks
}

enum NativeRendererRecoveryEvidenceEvaluator {
  static func evaluate(
    baseline: NativeRendererRecoveryEvidenceSnapshot,
    postForeground: NativeRendererRecoveryEvidenceSnapshot
  ) -> NativeRendererRecoveryMechanicsEvidence {
    let monotonic = countersAreMonotonic(from: baseline, to: postForeground)
    let deltas = makeDeltas(from: baseline, to: postForeground)
    let actualResourceRevocationObserved = deltas.revocationNotificationCount > 0
    let checks = NativeRendererRecoveryChecks(
      sameDisplayGeneration: baseline.displayGeneration == postForeground.displayGeneration,
      countersMonotonic: monotonic,
      actualResourceRevocationObserved: actualResourceRevocationObserved,
      requirementNotificationAdvanced: deltas.requirementNotificationCount > 0,
      revocationNotificationAdvanced: deltas.revocationNotificationCount > 0,
      foregroundCheckAdvanced: deltas.foregroundCheckCount > 0,
      recoveryEpisodeAdvanced: deltas.recoveryEpisodeCount > 0,
      recoveredEpisodeAdvanced: deltas.recoveredEpisodeCount > 0,
      recoveryFlushAdvanced: deltas.recoveryFlushCount > 0,
      revocationFlushAdvanced: deltas.revocationFlushCount > 0,
      successfulSubmissionAdvanced: deltas.successfulSubmissionCount > 0,
      recoverySubmissionAdvanced: deltas.recoverySubmissionCount > 0,
      permanentFailureUnchanged: deltas.permanentFailureCount == 0,
      episodesBalanced:
      postForeground.recoveryEpisodeCount == postForeground.recoveredEpisodeCount,
      currentRenderer: postForeground.isCurrent,
      requiresFlushCleared: !postForeground.requiresFlush,
      failedCleared: !postForeground.isFailed,
      recoveryInProgressCleared: !postForeground.isRecoveryInProgress,
      recoverySampleAvailable: postForeground.hasRecoverySample
    )

    let outcome: NativeRendererRecoveryMechanicsOutcome
    let reason: String
    if !checks.sameDisplayGeneration {
      outcome = .failed
      reason = "display-generation-changed"
    } else if !checks.countersMonotonic {
      outcome = .failed
      reason = "native-counter-regression"
    } else if !checks.permanentFailureUnchanged || !checks.failedCleared {
      outcome = .failed
      reason = "permanent-renderer-failure"
    } else if !actualResourceRevocationObserved {
      outcome = .notExercised
      reason = "os-resource-revocation-not-observed"
    } else if checksSatisfyRecoveryContract(checks) {
      outcome = .pass
      reason = "renderer-recovered-after-real-os-revocation"
    } else {
      outcome = .failed
      reason = "observed-revocation-did-not-complete-recovery"
    }

    return NativeRendererRecoveryMechanicsEvidence(
      formatVersion: 1,
      outcome: outcome,
      reason: reason,
      baseline: baseline,
      postForeground: postForeground,
      deltas: deltas,
      checks: checks
    )
  }

  private static func checksSatisfyRecoveryContract(
    _ checks: NativeRendererRecoveryChecks
  ) -> Bool {
    checks.sameDisplayGeneration
      && checks.countersMonotonic
      && checks.actualResourceRevocationObserved
      && checks.requirementNotificationAdvanced
      && checks.revocationNotificationAdvanced
      && checks.foregroundCheckAdvanced
      && checks.recoveryEpisodeAdvanced
      && checks.recoveredEpisodeAdvanced
      && checks.recoveryFlushAdvanced
      && checks.revocationFlushAdvanced
      && checks.successfulSubmissionAdvanced
      && checks.recoverySubmissionAdvanced
      && checks.permanentFailureUnchanged
      && checks.episodesBalanced
      && checks.currentRenderer
      && checks.requiresFlushCleared
      && checks.failedCleared
      && checks.recoveryInProgressCleared
      && checks.recoverySampleAvailable
  }

  private static func makeDeltas(
    from baseline: NativeRendererRecoveryEvidenceSnapshot,
    to postForeground: NativeRendererRecoveryEvidenceSnapshot
  ) -> NativeRendererRecoveryCounterDeltas {
    NativeRendererRecoveryCounterDeltas(
      recoveryEpisodeCount: delta(
        postForeground.recoveryEpisodeCount,
        baseline.recoveryEpisodeCount
      ),
      recoveredEpisodeCount: delta(
        postForeground.recoveredEpisodeCount,
        baseline.recoveredEpisodeCount
      ),
      requirementNotificationCount: delta(
        postForeground.requirementNotificationCount,
        baseline.requirementNotificationCount
      ),
      revocationNotificationCount: delta(
        postForeground.revocationNotificationCount,
        baseline.revocationNotificationCount
      ),
      decodeFailureNotificationCount: delta(
        postForeground.decodeFailureNotificationCount,
        baseline.decodeFailureNotificationCount
      ),
      foregroundCheckCount: delta(
        postForeground.foregroundCheckCount,
        baseline.foregroundCheckCount
      ),
      recoveryFlushCount: delta(
        postForeground.recoveryFlushCount,
        baseline.recoveryFlushCount
      ),
      revocationFlushCount: delta(
        postForeground.revocationFlushCount,
        baseline.revocationFlushCount
      ),
      failureFlushCount: delta(
        postForeground.failureFlushCount,
        baseline.failureFlushCount
      ),
      discontinuityFlushCount: delta(
        postForeground.discontinuityFlushCount,
        baseline.discontinuityFlushCount
      ),
      successfulSubmissionCount: delta(
        postForeground.successfulSubmissionCount,
        baseline.successfulSubmissionCount
      ),
      recoverySubmissionCount: delta(
        postForeground.recoverySubmissionCount,
        baseline.recoverySubmissionCount
      ),
      retryableSubmissionCount: delta(
        postForeground.retryableSubmissionCount,
        baseline.retryableSubmissionCount
      ),
      recoverySampleFailureCount: delta(
        postForeground.recoverySampleFailureCount,
        baseline.recoverySampleFailureCount
      ),
      permanentFailureCount: delta(
        postForeground.permanentFailureCount,
        baseline.permanentFailureCount
      )
    )
  }

  private static func countersAreMonotonic(
    from baseline: NativeRendererRecoveryEvidenceSnapshot,
    to postForeground: NativeRendererRecoveryEvidenceSnapshot
  ) -> Bool {
    postForeground.recoveryEpisodeCount >= baseline.recoveryEpisodeCount
      && postForeground.recoveredEpisodeCount >= baseline.recoveredEpisodeCount
      && postForeground.requirementNotificationCount
      >= baseline.requirementNotificationCount
      && postForeground.revocationNotificationCount >= baseline.revocationNotificationCount
      && postForeground.decodeFailureNotificationCount
      >= baseline.decodeFailureNotificationCount
      && postForeground.foregroundCheckCount >= baseline.foregroundCheckCount
      && postForeground.recoveryFlushCount >= baseline.recoveryFlushCount
      && postForeground.revocationFlushCount >= baseline.revocationFlushCount
      && postForeground.failureFlushCount >= baseline.failureFlushCount
      && postForeground.discontinuityFlushCount >= baseline.discontinuityFlushCount
      && postForeground.successfulSubmissionCount >= baseline.successfulSubmissionCount
      && postForeground.recoverySubmissionCount >= baseline.recoverySubmissionCount
      && postForeground.retryableSubmissionCount >= baseline.retryableSubmissionCount
      && postForeground.recoverySampleFailureCount
      >= baseline.recoverySampleFailureCount
      && postForeground.permanentFailureCount >= baseline.permanentFailureCount
  }

  private static func delta(_ newer: UInt64, _ older: UInt64) -> UInt64 {
    newer >= older ? newer - older : 0
  }
}
