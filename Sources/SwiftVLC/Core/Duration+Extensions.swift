import Foundation

/// Millisecond limits which remain representable after the pinned libVLC 4
/// converts public `libvlc_time_t` values with `VLC_TICK_FROM_MS`.
///
/// VLC's internal clock runs at one million ticks per second, so the public
/// millisecond value is multiplied by 1,000. Accepting the wider `Int64`
/// millisecond range would overflow inside VLC before it can reject the input.
enum LibVLCTimeMilliseconds {
  static let minimum: Int64 = .min / 1000
  static let maximum: Int64 = .max / 1000

  static func contains(_ value: Int64) -> Bool {
    (minimum...maximum).contains(value)
  }
}

extension Duration {
  /// Total duration in milliseconds.
  ///
  /// Values outside `Int64`'s representable millisecond range saturate
  /// to `Int64.min` or `Int64.max` instead of trapping.
  public var milliseconds: Int64 {
    converted(toUnitsPerSecond: 1000).value
  }

  /// Total duration in microseconds.
  ///
  /// Values outside `Int64`'s representable microsecond range saturate
  /// to `Int64.min` or `Int64.max` instead of trapping.
  public var microseconds: Int64 {
    converted(toUnitsPerSecond: 1_000_000).value
  }

  /// Formats the duration as a human-readable time string (e.g. "1:23:45" or "3:05").
  ///
  /// Negative durations are prefixed with "-" (e.g. "-0:05").
  public var formatted: String {
    let ms = milliseconds
    let isNegative = ms < 0
    // Divide before `abs` so `Int64.min` (whose negation overflows) doesn't trap.
    let totalSeconds = Int(abs(ms / 1000))
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60
    let prefix = isNegative ? "-" : ""
    if hours > 0 {
      return String(format: "%@%d:%02d:%02d", prefix, hours, minutes, seconds)
    }
    return String(format: "%@%d:%02d", prefix, minutes, seconds)
  }
}

extension Duration {
  func checkedMilliseconds(parameter: String) throws(VLCError) -> Int64 {
    let conversion = converted(toUnitsPerSecond: 1000)
    guard !conversion.overflow else {
      throw .invalidInput("\(parameter) is outside the supported millisecond range")
    }
    return conversion.value
  }

  func checkedNonnegativeMilliseconds(parameter: String) throws(VLCError) -> Int64 {
    let value = try checkedMilliseconds(parameter: parameter)
    guard value >= 0 else {
      throw .invalidInput("\(parameter) must be non-negative")
    }
    return value
  }

  /// Converts to the narrower millisecond domain accepted safely by the
  /// pinned libVLC build's `VLC_TICK_FROM_MS` boundary.
  func checkedLibVLCTimeMilliseconds(parameter: String) throws(VLCError) -> Int64 {
    let value = try checkedMilliseconds(parameter: parameter)
    guard LibVLCTimeMilliseconds.contains(value) else {
      throw .invalidInput(
        "\(parameter) must be between \(LibVLCTimeMilliseconds.minimum) and "
          + "\(LibVLCTimeMilliseconds.maximum) milliseconds"
      )
    }
    return value
  }

  func checkedNonnegativeLibVLCTimeMilliseconds(
    parameter: String
  )
    throws(VLCError) -> Int64 {
    let value = try checkedLibVLCTimeMilliseconds(parameter: parameter)
    guard value >= 0 else {
      throw .invalidInput("\(parameter) must be non-negative")
    }
    return value
  }

  func checkedNonnegativeInt32Milliseconds(parameter: String) throws(VLCError) -> Int32 {
    let value = try checkedNonnegativeMilliseconds(parameter: parameter)
    guard value <= Int64(Int32.max) else {
      throw .invalidInput("\(parameter) must fit in \(Int32.max) milliseconds")
    }
    return Int32(value)
  }

  func checkedMicroseconds(parameter: String) throws(VLCError) -> Int64 {
    let conversion = converted(toUnitsPerSecond: 1_000_000)
    guard !conversion.overflow else {
      throw .invalidInput("\(parameter) is outside the supported microsecond range")
    }
    return conversion.value
  }

  private func converted(toUnitsPerSecond unitsPerSecond: Int64) -> (value: Int64, overflow: Bool) {
    let (seconds, attoseconds) = components
    let attosecondsPerSecond: Int64 = 1_000_000_000_000_000_000
    let subsecondUnits = attoseconds / (attosecondsPerSecond / unitsPerSecond)

    let multiplied = seconds.multipliedReportingOverflow(by: unitsPerSecond)
    guard !multiplied.overflow else {
      return (seconds >= 0 ? .max : .min, true)
    }

    let added = multiplied.partialValue.addingReportingOverflow(subsecondUnits)
    guard !added.overflow else {
      return (subsecondUnits >= 0 ? .max : .min, true)
    }
    return (added.partialValue, false)
  }
}
