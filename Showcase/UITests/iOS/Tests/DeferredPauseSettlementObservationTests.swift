import XCTest

final class DeferredPauseSettlementObservationTests: XCTestCase {
  func testStableCountersCannotHidePlaybackThatResumedDuringSettlement() {
    let observation = DeferredPauseSettlementObservation(
      taskIsInFlight: false,
      countersStayedUnchanged: true,
      terminalOutcomeStayedExpected: true,
      playerIsPaused: false,
      playbackIntentIsActive: true,
      controlsArePlaying: true
    )

    XCTAssertTrue(observation.taskStayedSettled)
    XCTAssertFalse(observation.pausedTruthStayedSettled)
  }

  func testChangedTerminalOutcomeFailsTaskSettlement() {
    let observation = DeferredPauseSettlementObservation(
      taskIsInFlight: false,
      countersStayedUnchanged: true,
      terminalOutcomeStayedExpected: false,
      playerIsPaused: true,
      playbackIntentIsActive: false,
      controlsArePlaying: false
    )

    XCTAssertFalse(observation.taskStayedSettled)
    XCTAssertTrue(observation.pausedTruthStayedSettled)
  }
}
