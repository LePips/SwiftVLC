// swift-format-ignore-file: AlwaysUseLowerCamelCase

#if os(iOS) || os(macOS)
import Foundation
import Synchronization

/// Cumulative interval classifications for the pictures that reached one
/// direct-vmem output callback generation.
///
/// These are **not** decoded/source-frame counts. VLC invokes the callback
/// after video filters and vout selection, so decoder/vout drops can happen
/// before SwiftVLC observes a picture. A multi-frame PTS delta can therefore
/// be a truthful output-attempt gap rather than a new nominal source cadence.
@_spi(Qualification)
public struct PiPVmemOutputIntervalCounts: Codable, Sendable, Equatable {
  public let fps23_976: UInt64
  public let fps24: UInt64
  public let fps25: UInt64
  public let fps29_97: UInt64
  public let fps30: UInt64
  public let fps50: UInt64
  public let fps59_94: UInt64
  public let fps60: UInt64
  public let other: UInt64

  init(_ counters: NativePictureIntervalCounters) {
    fps23_976 = counters.fps23_976
    fps24 = counters.fps24
    fps25 = counters.fps25
    fps29_97 = counters.fps29_97
    fps30 = counters.fps30
    fps50 = counters.fps50
    fps59_94 = counters.fps59_94
    fps60 = counters.fps60
    other = counters.other
  }
}

/// Compatibility spelling retained while qualification evidence migrates to
/// the truthful post-filter/vout-selected terminology.
@_spi(Qualification)
public typealias PiPSourceIntervalCounts = PiPVmemOutputIntervalCounts

/// One exact native PTS delta and its occurrence count.
///
/// The histogram is sorted by `deltaMicroseconds` when it is published. It is
/// lossless for every representable valid-to-valid subtraction, including
/// duplicate (`0`) and backward (negative) values.
@_spi(Qualification)
public struct PiPVmemOutputPTSDeltaCount: Codable, Sendable, Equatable {
  public let deltaMicroseconds: Int64
  public let count: UInt64
}

enum NativePictureIntervalBucket: Sendable, Equatable {
  case fps23_976
  case fps24
  case fps25
  case fps29_97
  case fps30
  case fps50
  case fps59_94
  case fps60
  case other
}

struct NativePictureIntervalCounters: Sendable, Equatable {
  var fps23_976: UInt64 = 0
  var fps24: UInt64 = 0
  var fps25: UInt64 = 0
  var fps29_97: UInt64 = 0
  var fps30: UInt64 = 0
  var fps50: UInt64 = 0
  var fps59_94: UInt64 = 0
  var fps60: UInt64 = 0
  var other: UInt64 = 0

  mutating func record(_ bucket: NativePictureIntervalBucket) {
    switch bucket {
    case .fps23_976: Self.increment(&fps23_976)
    case .fps24: Self.increment(&fps24)
    case .fps25: Self.increment(&fps25)
    case .fps29_97: Self.increment(&fps29_97)
    case .fps30: Self.increment(&fps30)
    case .fps50: Self.increment(&fps50)
    case .fps59_94: Self.increment(&fps59_94)
    case .fps60: Self.increment(&fps60)
    case .other: Self.increment(&other)
    }
  }

  private static func increment(_ value: inout UInt64) {
    if value < .max {
      value += 1
    }
  }
}

/// Internal accounting snapshot used by deterministic seam/race tests. The
/// public qualification snapshot exposes only the exact evidence contract.
struct NativePictureTimestampTelemetrySnapshot: Sendable, Equatable {
  let isAvailable: Bool
  let playbackGeneration: UInt64
  let voutGeneration: UInt64?
  let callbackCount: UInt64
  let submittedCount: UInt64
  let swiftRejectedCount: UInt64
  let inFlightCount: UInt64
  let validTimestampCount: UInt64
  let invalidTimestampCount: UInt64
  let duplicateTimestampCount: UInt64
  let backwardTimestampCount: UInt64
  let deltaOverflowCount: UInt64
  let discontinuityCount: UInt64
  let firstPicturePTSUS: Int64?
  let lastPicturePTSUS: Int64?
  let firstValidPicturePTSUS: Int64?
  let lastValidPicturePTSUS: Int64?
  let deltaHistogram: [PiPVmemOutputPTSDeltaCount]
  let counters: NativePictureIntervalCounters

  var vmemOutputIntervalCounts: PiPVmemOutputIntervalCounts? {
    isAvailable ? PiPVmemOutputIntervalCounts(counters) : nil
  }

  var vmemOutputTimestampProvenance: String? {
    isAvailable ? NativePictureTimestampTelemetry.provenance : nil
  }

  /// Compatibility accessors for already-written qualification producers.
  var sourceIntervalCounts: PiPSourceIntervalCounts? {
    vmemOutputIntervalCounts
  }

  var sourceTimestampProvenance: String? {
    isAvailable ? NativePictureTimestampTelemetry.legacyProvenance : nil
  }
}

/// Lossless callback-seam accumulator for native picture dates.
///
/// One instance belongs to an exact handle-level callback opaque. Calls are
/// serialized by the mutex, while playback and vout identities prevent late
/// callbacks from an older output from contaminating or resetting the current
/// segment.
final class NativePictureTimestampTelemetry: Sendable {
  static let invalidPicturePTSUS = Int64.min
  static let provenance =
    "libvlc-vmem-post-filter-vout-selected-output-attempt-pts-v1"
  static let legacyProvenance = "libvlc-picture_t.date-native-callback-v1"

  private struct State: Sendable {
    var isAvailable = false
    var playbackGeneration: UInt64
    var voutGeneration: UInt64?
    var callbackCount: UInt64 = 0
    var submittedCount: UInt64 = 0
    var swiftRejectedCount: UInt64 = 0
    var inFlightCount: UInt64 = 0
    var validTimestampCount: UInt64 = 0
    var invalidTimestampCount: UInt64 = 0
    var duplicateTimestampCount: UInt64 = 0
    var backwardTimestampCount: UInt64 = 0
    var deltaOverflowCount: UInt64 = 0
    var discontinuityCount: UInt64 = 0
    var firstPicturePTSUS: Int64?
    var lastPicturePTSUS: Int64?
    var firstValidPicturePTSUS: Int64?
    var lastValidPicturePTSUS: Int64?
    var deltaHistogram: [Int64: UInt64] = [:]
    var counters = NativePictureIntervalCounters()

    init(
      isAvailable: Bool = false,
      playbackGeneration: UInt64,
      voutGeneration: UInt64? = nil
    ) {
      self.isAvailable = isAvailable
      self.playbackGeneration = playbackGeneration
      self.voutGeneration = voutGeneration
    }

    mutating func resetSegment(voutGeneration: UInt64?) {
      self.voutGeneration = voutGeneration
      callbackCount = 0
      submittedCount = 0
      swiftRejectedCount = 0
      inFlightCount = 0
      validTimestampCount = 0
      invalidTimestampCount = 0
      duplicateTimestampCount = 0
      backwardTimestampCount = 0
      deltaOverflowCount = 0
      discontinuityCount = 0
      firstPicturePTSUS = nil
      lastPicturePTSUS = nil
      firstValidPicturePTSUS = nil
      lastValidPicturePTSUS = nil
      deltaHistogram = [:]
      counters = NativePictureIntervalCounters()
    }
  }

  private let state: Mutex<State>

  init(playbackGeneration: UInt64 = 0) {
    state = Mutex(State(playbackGeneration: playbackGeneration))
  }

  /// Marks whether this handle selected the v6 timestamp-bearing ABI. The
  /// capability persists across a callback clear/reinstall so evidence resets
  /// only at an actual playback or vout boundary. An older ABI deliberately
  /// exposes neither zero counts nor provenance.
  func setAvailable(_ available: Bool) {
    state.withLock { state in
      guard state.isAvailable != available else { return }
      state.isAvailable = available
      state.resetSegment(voutGeneration: nil)
    }
  }

  /// Starts a distinct playback segment. Rebinding a successor controller to
  /// the same generation is idempotent and preserves cumulative evidence.
  func beginPlaybackGeneration(_ generation: UInt64) {
    state.withLock { state in
      guard generation > state.playbackGeneration else { return }
      state.playbackGeneration = generation
      state.resetSegment(voutGeneration: nil)
    }
  }

  /// Begins one v6 callback and records its exact native PTS argument before
  /// any picture validation or output work.
  ///
  /// Returns `true` when the callback belongs to the published generation. A
  /// matching ``recordSubmissionResult`` must then close the in-flight entry.
  /// Invalid timing resets the interval baseline but never rejects a picture.
  /// A newer vout starts a fresh segment; callbacks from a superseded vout are
  /// ignored for the current-generation snapshot.
  @discardableResult
  func record(
    picturePTSUS: Int64,
    playbackGeneration: UInt64,
    voutGeneration: UInt64
  ) -> Bool {
    state.withLock { state in
      guard state.isAvailable else { return false }
      guard playbackGeneration == state.playbackGeneration else { return false }

      if let current = state.voutGeneration {
        guard voutGeneration >= current else { return false }
        if voutGeneration > current {
          state.resetSegment(voutGeneration: voutGeneration)
        }
      } else {
        state.resetSegment(voutGeneration: voutGeneration)
      }

      Self.increment(&state.callbackCount)
      Self.increment(&state.inFlightCount)
      if state.firstPicturePTSUS == nil {
        state.firstPicturePTSUS = picturePTSUS
      }
      state.lastPicturePTSUS = picturePTSUS
      guard picturePTSUS != Self.invalidPicturePTSUS else {
        Self.increment(&state.invalidTimestampCount)
        state.lastValidPicturePTSUS = nil
        return true
      }
      Self.increment(&state.validTimestampCount)
      if state.firstValidPicturePTSUS == nil {
        state.firstValidPicturePTSUS = picturePTSUS
      }

      guard let previous = state.lastValidPicturePTSUS else {
        state.lastValidPicturePTSUS = picturePTSUS
        return true
      }
      let subtraction = picturePTSUS.subtractingReportingOverflow(previous)
      if subtraction.overflow {
        Self.increment(&state.deltaOverflowCount)
        Self.increment(&state.discontinuityCount)
        state.counters.record(.other)
      } else {
        let delta = subtraction.partialValue
        Self.incrementHistogram(delta, in: &state.deltaHistogram)
        if delta == 0 {
          Self.increment(&state.duplicateTimestampCount)
        } else if delta < 0 {
          Self.increment(&state.backwardTimestampCount)
          Self.increment(&state.discontinuityCount)
        } else {
          let bucket = Self.classify(deltaMicroseconds: delta)
          if bucket == .other {
            Self.increment(&state.discontinuityCount)
          }
          state.counters.record(bucket)
        }
      }
      state.lastValidPicturePTSUS = picturePTSUS
      return true
    }
  }

  /// Closes a callback begun by ``record`` with the exact synchronous Swift
  /// submission result returned to VLC.
  func recordSubmissionResult(
    submitted: Bool,
    playbackGeneration: UInt64,
    voutGeneration: UInt64
  ) {
    state.withLock { state in
      guard state.isAvailable else { return }
      guard playbackGeneration == state.playbackGeneration else { return }
      guard voutGeneration == state.voutGeneration else { return }
      guard state.inFlightCount > 0 else { return }
      state.inFlightCount -= 1
      if submitted {
        Self.increment(&state.submittedCount)
      } else {
        Self.increment(&state.swiftRejectedCount)
      }
    }
  }

  var snapshot: NativePictureTimestampTelemetrySnapshot {
    state.withLock { state in
      NativePictureTimestampTelemetrySnapshot(
        isAvailable: state.isAvailable,
        playbackGeneration: state.playbackGeneration,
        voutGeneration: state.voutGeneration,
        callbackCount: state.callbackCount,
        submittedCount: state.submittedCount,
        swiftRejectedCount: state.swiftRejectedCount,
        inFlightCount: state.inFlightCount,
        validTimestampCount: state.validTimestampCount,
        invalidTimestampCount: state.invalidTimestampCount,
        duplicateTimestampCount: state.duplicateTimestampCount,
        backwardTimestampCount: state.backwardTimestampCount,
        deltaOverflowCount: state.deltaOverflowCount,
        discontinuityCount: state.discontinuityCount,
        firstPicturePTSUS: state.firstPicturePTSUS,
        lastPicturePTSUS: state.lastPicturePTSUS,
        firstValidPicturePTSUS: state.firstValidPicturePTSUS,
        lastValidPicturePTSUS: state.lastValidPicturePTSUS,
        deltaHistogram: state.deltaHistogram
          .map {
            PiPVmemOutputPTSDeltaCount(
              deltaMicroseconds: $0.key,
              count: $0.value
            )
          }
          .sorted { $0.deltaMicroseconds < $1.deltaMicroseconds },
        counters: state.counters
      )
    }
  }

  /// The fixture rates are rational, while the ABI is integral microseconds.
  /// Accepting both floor and ceiling values classifies the expected rounding
  /// alternation without widening adjacent rates into one another.
  static func classify(deltaMicroseconds: Int64) -> NativePictureIntervalBucket {
    switch deltaMicroseconds {
    case 41708, 41709: .fps23_976
    case 41666, 41667: .fps24
    case 40000: .fps25
    case 33366, 33367: .fps29_97
    case 33333, 33334: .fps30
    case 20000: .fps50
    case 16683, 16684: .fps59_94
    case 16666, 16667: .fps60
    default: .other
    }
  }

  private static func increment(_ value: inout UInt64) {
    if value < .max {
      value += 1
    }
  }

  private static func incrementHistogram(
    _ delta: Int64,
    in histogram: inout [Int64: UInt64]
  ) {
    var count = histogram[delta, default: 0]
    increment(&count)
    histogram[delta] = count
  }
}
#endif
