/// Pure qualification predicate sampled after the deferred-pause quiet period.
/// Keeping every field explicit prevents a stable counter snapshot from hiding
/// playback or controls that reverted while the harness was waiting.
struct DeferredPauseSettlementObservation: Equatable {
  let taskIsInFlight: Bool
  let countersStayedUnchanged: Bool
  let terminalOutcomeStayedExpected: Bool
  let playerIsPaused: Bool
  let playbackIntentIsActive: Bool
  let controlsArePlaying: Bool

  var taskStayedSettled: Bool {
    !taskIsInFlight
      && countersStayedUnchanged
      && terminalOutcomeStayedExpected
  }

  var pausedTruthStayedSettled: Bool {
    playerIsPaused
      && !playbackIntentIsActive
      && !controlsArePlaying
  }
}
