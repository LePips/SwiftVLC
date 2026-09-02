import Foundation

/// Machine-readable evidence produced by the Seeking showcase's UI-test-only
/// direct burst runner. This type deliberately has no SwiftVLC dependency so
/// the app and XCUITest targets decode the exact same contract.
struct SeekBurstEvidence: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let outcome: String
  let cadenceMilliseconds: Int
  let startedAt: Date
  let targets: [Double]
  let commands: [SeekBurstCommand]
  let fastDispatchSpanMilliseconds: Int64
  let recoveryMilliseconds: Int64?
  let expectedTargetTimeMilliseconds: Int64
  let finalState: String
  let finalTimeMilliseconds: Int64
  let finalPosition: Double
  let finalIsPlaybackRequestedActive: Bool
  let finalIsSeekable: Bool
  let finalDidReachEnd: Bool
  let finalActiveVideoOutputs: Int
  let finalHasVideoOutput: Bool
  let decodedVideoDelta: UInt64
  let displayedPicturesDelta: UInt64
  let failure: String?
}

/// One synchronous dispatch sample from a direct seek burst.
///
/// The `published*` values are intentionally named: they are useful forensic
/// state captured immediately after the call, but are not proof that libVLC
/// landed. `SeekBurstEvidence` proves recovery separately with advancing time
/// and decoder/output counters after the final precise seek.
struct SeekBurstCommand: Codable, Equatable, Sendable {
  let id: Int
  let target: Double
  let fast: Bool
  let scheduledOffsetMilliseconds: Int64
  let actualOffsetMilliseconds: Int64
  let callDurationMilliseconds: Int64
  let error: String?
  let publishedState: String
  let publishedTimeMilliseconds: Int64
  let publishedPosition: Double
  let publishedIsSeekable: Bool
  let publishedActiveVideoOutputs: Int
  let publishedDidReachEnd: Bool
}
