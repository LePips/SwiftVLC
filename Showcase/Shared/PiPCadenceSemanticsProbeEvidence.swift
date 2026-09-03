import Foundation

/// One reviewed wall-clock contract shared by the probe app and its physical
/// UI test. The app must reach either a report or an explicit failure before
/// SpringBoard capture ends; XCTest then retains a separate collection reserve.
enum PiPCadenceSemanticsProbeTiming {
  static let applicationRunBudgetSeconds: TimeInterval = 270
  static let springBoardCaptureBudgetSeconds: TimeInterval = 300
  static let reportCollectionBudgetSeconds: TimeInterval = 30
  static let captureBoundaryGuardSeconds: TimeInterval = 0.1
  static let xctestExecutionAllowanceSeconds = 420
  static let runnerIdleWatchdogSeconds = 480
  static let runnerWallWatchdogSeconds = 780
}

/// Fixture profile understood by the direct-vmem cadence evidence producers.
/// The names match `generate-fixtures.sh`; no inferred/average track rate is
/// used to classify native PTS deltas.
enum PiPCadenceProbeProfile: String, Codable, CaseIterable, Sendable {
  case fps23976 = "23.976"
  case fps24 = "24"
  case fps25 = "25"
  case fps2997 = "29.97"
  case fps30 = "30"
  case fps50 = "50"
  case fps5994 = "59.94"
  case fps60 = "60"
  case vfr = "vfr-24-60"

  var fileName: String {
    switch self {
    case .fps23976: "23_976"
    case .fps2997: "29_97"
    case .fps5994: "59_94"
    case .vfr: "vfr"
    default: rawValue
    }
  }

  fileprivate var rationalRates: [(numerator: Int64, denominator: Int64)] {
    switch self {
    case .fps23976: [(24000, 1001)]
    case .fps24: [(24, 1)]
    case .fps25: [(25, 1)]
    case .fps2997: [(30000, 1001)]
    case .fps30: [(30, 1)]
    case .fps50: [(50, 1)]
    case .fps5994: [(60000, 1001)]
    case .fps60: [(60, 1)]
    // This fixture alternates exact two-second 24 and 60 fps regimes. A
    // cross-regime gap remains reportable but is never forced into a bucket.
    case .vfr: [(24, 1), (60, 1)]
    }
  }
}

struct PiPCadenceProbeDeltaCount: Codable, Equatable, Sendable {
  let deltaMicroseconds: Int64
  let count: UInt64
}

/// Exact/multiple classification of a lossless native PTS delta histogram.
/// Counts describe post-filter/vout-selected output attempts, not decoder
/// output and not necessarily visible SpringBoard frames.
struct PiPCadenceProbeMultipleClassification: Codable, Equatable, Sendable {
  let exactIntervalCount: UInt64
  let multipleIntervalCount: UInt64
  let estimatedSkippedPictureCount: UInt64
  let redisplayCount: UInt64
  let backwardCount: UInt64
  let unclassifiedIntervalCount: UInt64
  let deltaOverflowCount: UInt64
}

enum PiPCadenceProbeDeltaAnalyzer {
  static func classify(
    profile: PiPCadenceProbeProfile,
    histogram: [PiPCadenceProbeDeltaCount],
    deltaOverflowCount: UInt64
  ) -> PiPCadenceProbeMultipleClassification {
    var exact: UInt64 = 0
    var multiple: UInt64 = 0
    var skipped: UInt64 = 0
    var redisplay: UInt64 = 0
    var backward: UInt64 = 0
    var unclassified: UInt64 = 0

    for entry in histogram where entry.count != .zero {
      if entry.deltaMicroseconds == 0 {
        add(entry.count, to: &redisplay)
        continue
      }
      guard entry.deltaMicroseconds > 0 else {
        add(entry.count, to: &backward)
        continue
      }
      let matches = profile.rationalRates.compactMap { rate in
        matchingMultiple(deltaMicroseconds: entry.deltaMicroseconds, rate: rate)
      }
      guard let match = matches.min(by: { $0.skipped < $1.skipped }) else {
        add(entry.count, to: &unclassified)
        continue
      }
      if match.multiple == 1 {
        add(entry.count, to: &exact)
      } else {
        add(entry.count, to: &multiple)
        let skippedForEntry = UInt64(match.skipped)
          .multipliedReportingOverflow(by: entry.count)
        add(skippedForEntry.overflow ? .max : skippedForEntry.partialValue, to: &skipped)
      }
    }

    return PiPCadenceProbeMultipleClassification(
      exactIntervalCount: exact,
      multipleIntervalCount: multiple,
      estimatedSkippedPictureCount: skipped,
      redisplayCount: redisplay,
      backwardCount: backward,
      unclassifiedIntervalCount: unclassified,
      deltaOverflowCount: deltaOverflowCount
    )
  }

  private static func matchingMultiple(
    deltaMicroseconds: Int64,
    rate: (numerator: Int64, denominator: Int64)
  ) -> (multiple: Int64, skipped: Int64)? {
    let estimated =
      Double(deltaMicroseconds) * Double(rate.numerator)
        / (1_000_000 * Double(rate.denominator))
    guard estimated.isFinite, estimated >= 0.5, estimated < Double(Int64.max - 3) else {
      return nil
    }
    let center = max(Int64(1), Int64(estimated.rounded()))
    let lower = max(Int64(1), center - 2)
    let upper = center + 2
    for multiple in lower...upper {
      let first = multiple.multipliedReportingOverflow(by: 1_000_000)
      guard !first.overflow else { continue }
      let scaled = first.partialValue.multipliedReportingOverflow(
        by: rate.denominator
      )
      guard !scaled.overflow else { continue }
      let floorValue = scaled.partialValue / rate.numerator
      let remainder = scaled.partialValue % rate.numerator
      let ceilingValue = floorValue + (remainder == 0 ? 0 : 1)
      if deltaMicroseconds == floorValue || deltaMicroseconds == ceilingValue {
        return (multiple, multiple - 1)
      }
    }
    return nil
  }

  private static func add(_ amount: UInt64, to value: inout UInt64) {
    let result = value.addingReportingOverflow(amount)
    value = result.overflow ? .max : result.partialValue
  }
}
