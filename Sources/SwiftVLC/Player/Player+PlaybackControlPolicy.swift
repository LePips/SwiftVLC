extension Player {
  /// The lifecycle state to publish when libVLC refuses to start.
  ///
  /// No session exists for the current media, so an *active* state can only
  /// have been inherited from the previous one. Leaving it would describe
  /// that previous session while every other public field already describes
  /// the current media — the mixed identity a rejected start has to avoid —
  /// so it is replaced with one terminal outcome. A state that is already
  /// non-active is left alone: there is no stale session to displace, and
  /// inventing a failure the caller never had would be its own lie.
  ///
  /// Pure so the rule is testable: `libvlc_media_player_play` returning `-1`
  /// is not something a test can force, including on an empty player.
  nonisolated static func stateAfterRejectedStart(previous: PlayerState) -> PlayerState {
    previous.isActive ? .error : previous
  }

  var shouldResumeForExternalPlayRequest: Bool {
    pauseTransition == .pausing
      || state == .paused
      || (!isPlaybackRequestedActive && state.isActive)
      || nativePlaybackState == .paused
  }
}
