#if os(iOS) || os(macOS)

extension Player {
  enum QualificationPauseFaultMode: Equatable {
    case disabled
    case permanentRejection
    case transientRejection
  }

  struct QualificationPauseFaultSnapshot: Sendable, Equatable {
    let isEnabled: Bool
    let forcedRejectionCount: Int
    let nativePauseCommandCount: Int
    let remainingTransientRejections: Int
  }

  struct QualificationPauseFaultState {
    var mode: QualificationPauseFaultMode = .disabled
    var remainingTransientRejections = 0
    var forcedRejectionCount = 0
    var nativePauseCommandCount = 0
  }

  func configureQualificationPauseFault(
    mode: QualificationPauseFaultMode,
    transientRejections: Int = 0
  ) {
    qualificationPauseFault = QualificationPauseFaultState(
      mode: mode,
      remainingTransientRejections: max(0, transientRejections)
    )
  }

  /// Returns `false` while qualification deliberately suppresses native pause
  /// capability, or `nil` when the real libVLC probe remains authoritative.
  func consumeQualificationNativeCanPauseOverride() -> Bool? {
    switch qualificationPauseFault.mode {
    case .disabled:
      return nil
    case .permanentRejection:
      qualificationPauseFault.forcedRejectionCount += 1
      return false
    case .transientRejection:
      guard qualificationPauseFault.remainingTransientRejections > 0 else {
        return nil
      }
      qualificationPauseFault.remainingTransientRejections -= 1
      qualificationPauseFault.forcedRejectionCount += 1
      return false
    }
  }

  func recordQualificationNativePauseCommand() {
    guard qualificationPauseFault.mode != .disabled else { return }
    qualificationPauseFault.nativePauseCommandCount += 1
  }

  var qualificationPauseFaultSnapshot: QualificationPauseFaultSnapshot {
    QualificationPauseFaultSnapshot(
      isEnabled: qualificationPauseFault.mode != .disabled,
      forcedRejectionCount: qualificationPauseFault.forcedRejectionCount,
      nativePauseCommandCount: qualificationPauseFault.nativePauseCommandCount,
      remainingTransientRejections:
      qualificationPauseFault.remainingTransientRejections
    )
  }
}

#endif
