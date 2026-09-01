import Foundation

enum ProgressiveHTTPRangeSeekContract {
  static let fixtureID = "progressive-http-range-mp4"
  static let fixtureRelativePath = "oracles/progressive-range.mp4"
  static let targetMilliseconds: Int64 = 43500
  static let landingBoundaryMilliseconds: Int64 = 40000
  static let seekToleranceMilliseconds: Int64 = 750
  static let minimumFixtureBytes = 50_000_000
  static let expectedDurationMilliseconds: Int64 = 120_000
  static let secondHalfStartMilliseconds: Int64 = 60000
  static let maximumScreenshotCaptureIntervalSeconds = 1.0
  static let commandOriginHeader = "X-SwiftVLC-Progressive-Command-Origin"
  static let commandOrigin = "candidate-app-before-strict-request-seek-v1"

  enum Mode: String, Codable, CaseIterable {
    case range
    case noRange = "no-range"
  }

  static func mediaPath(token: String, mode: Mode) -> String {
    "progressive/\(token)/\(mode.rawValue)/media.mp4"
  }

  static func commandPath(token: String, mode: Mode) -> String {
    "progressive/\(token)/\(mode.rawValue)/command"
  }
}

struct ProgressiveHTTPRangeCommandMarkerAcknowledgment: Codable, Equatable {
  let kind: String
  let sequence: Int
  let token: String
  let mode: String
  let phase: String
  let origin: String
  let precommandRequestCount: Int
  let precommandTransferredBytes: UInt64
  let markedAtUTC: String
}

struct ProgressiveHTTPRangeCounterSnapshot: Codable, Equatable {
  let systemUptimeSeconds: Double
  let playbackGeneration: String
  let state: String
  let currentTimeMilliseconds: Int64
  let durationMilliseconds: Int64
  let isSeekable: Bool
  let readBytes: UInt64
  let demuxReadBytes: UInt64
  let decodedVideo: UInt64
  let displayedPictures: UInt64
  let lostPictures: UInt64
}

struct ProgressiveHTTPRangeTypedSeek: Codable, Equatable {
  let commandAttemptToken: String
  let playbackGeneration: String
  let targetMilliseconds: Int64
  let fast: Bool
  let initialOutcome: String
  let terminalOutcome: String
}

struct ProgressiveHTTPRangeTypedRejection: Codable, Equatable {
  let commandAttemptToken: String
  let playbackGeneration: String
  let errorDomain: String
  let errorCase: String
  let message: String
  let commandDispatched: Bool
}

struct ProgressiveHTTPRangeSuccess: Codable, Equatable {
  let mode: String
  let attemptToken: String
  let sourcePath: String
  let targetMilliseconds: Int64
  let landingBoundaryMilliseconds: Int64
  let typedSeek: ProgressiveHTTPRangeTypedSeek
  let start: ProgressiveHTTPRangeCounterSnapshot
  let landing: ProgressiveHTTPRangeCounterSnapshot
  let end: ProgressiveHTTPRangeCounterSnapshot
}

struct ProgressiveHTTPNoRangeSuccess: Codable, Equatable {
  let mode: String
  let attemptToken: String
  let sourcePath: String
  let targetMilliseconds: Int64
  let seekableAtCommand: Bool
  let typedRejection: ProgressiveHTTPRangeTypedRejection
  let start: ProgressiveHTTPRangeCounterSnapshot
  let end: ProgressiveHTTPRangeCounterSnapshot
}
