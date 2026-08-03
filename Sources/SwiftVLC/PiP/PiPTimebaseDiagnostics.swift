#if os(iOS) || os(macOS)
import CoreMedia
import Foundation

/// Why SwiftVLC wrote a new value into PiP's control timebase.
///
/// This is qualification SPI rather than stable API. It exists so long-running
/// device runs can prove that clock corrections are bounded and invisible.
@_spi(Qualification)
public enum PiPTimebaseCorrectionReason: String, Codable, Sendable {
  case initialSynchronization
  case playbackStateTransition
  case playbackRateTransition
  case steadyStateDrift
  case skipLanding
}

/// One lossless control-timebase write emitted during PiP qualification.
@_spi(Qualification)
public struct PiPTimebaseCorrection: Codable, Sendable, Equatable {
  public let sequence: UInt64
  public let capturedAt: TimeInterval
  public let systemUptime: TimeInterval
  public let playbackGeneration: UInt64
  public let reason: PiPTimebaseCorrectionReason
  public let mediaTimeSeconds: Double
  public let previousTimebaseSeconds: Double
  public let correctedTimebaseSeconds: Double
  public let driftSeconds: Double
  public let previousTimebaseRate: Double?
  public let correctedTimebaseRate: Double?
}

/// A pollable direct-PiP clock and renderer sample for multi-hour runs.
///
/// `mediaTimeSeconds` is libVLC's player clock. It is not mislabeled as an
/// audio presentation timestamp: device qualification must pair this record
/// with an audio measurement or capture when evaluating audible A/V sync.
@_spi(Qualification)
public struct PiPTimebaseDiagnosticSnapshot: Codable, Sendable, Equatable {
  public let capturedAt: TimeInterval
  public let systemUptime: TimeInterval
  public let playbackGeneration: UInt64
  public let isPlaybackActive: Bool
  public let isPictureInPictureActive: Bool
  public let requestedRate: Float
  public let mediaTimeSeconds: Double
  public let controlTimebaseSeconds: Double?
  public let controlTimebaseRate: Double?
  public let driftSeconds: Double?
  public let decodedFrameCount: UInt64
  public let enqueuedFrameCount: UInt64
  public let deliveredFrameCount: UInt64
  public let droppedFrameCount: UInt64
  public let lastDeliveredSampleTimeSeconds: Double?
  public let lastDeliveredSamplePlaybackGeneration: UInt64?
  public let correctionCount: UInt64
}

@_spi(Qualification)
extension PiPController {
  /// Every control-timebase write, in issue order, without a sampling gap.
  public nonisolated var timebaseCorrections: AsyncStream<PiPTimebaseCorrection> {
    timebaseCorrectionBroadcaster.subscribe(policy: .unbounded)
  }

  /// Captures one clock-series row without changing playback or the timebase.
  public func timebaseDiagnosticSnapshot() -> PiPTimebaseDiagnosticSnapshot {
    let mediaTime = player.currentTime
    let mediaTimeSeconds = Double(mediaTime.components.seconds)
      + Double(mediaTime.components.attoseconds) / 1e18
    let timebaseSeconds = controlTimebase.map { CMTimebaseGetTime($0).seconds }
    let telemetry = renderer.telemetrySnapshot

    return PiPTimebaseDiagnosticSnapshot(
      capturedAt: Date().timeIntervalSince1970,
      systemUptime: ProcessInfo.processInfo.systemUptime,
      playbackGeneration: player.sessionGeneration,
      isPlaybackActive: player.isActive,
      isPictureInPictureActive: isActive,
      requestedRate: player.rate,
      mediaTimeSeconds: mediaTimeSeconds,
      controlTimebaseSeconds: timebaseSeconds,
      controlTimebaseRate: controlTimebase.map { CMTimebaseGetRate($0) },
      driftSeconds: timebaseSeconds.map { mediaTimeSeconds - $0 },
      decodedFrameCount: telemetry.decodedFrameCount,
      enqueuedFrameCount: telemetry.enqueuedFrameCount,
      deliveredFrameCount: telemetry.presentedFrameCount,
      droppedFrameCount: telemetry.droppedFrameCount,
      lastDeliveredSampleTimeSeconds: telemetry.lastPresentedSampleTimeSeconds,
      lastDeliveredSamplePlaybackGeneration: telemetry.lastPresentedSamplePlaybackGeneration,
      correctionCount: timebaseCorrectionSequence
    )
  }

  func recordTimebaseCorrection(
    reason: PiPTimebaseCorrectionReason,
    previousTimebaseSeconds: Double,
    correctedTimebaseSeconds: Double,
    mediaTimeSeconds: Double,
    previousTimebaseRate: Double? = nil,
    correctedTimebaseRate: Double? = nil
  ) {
    timebaseCorrectionSequence &+= 1
    timebaseCorrectionBroadcaster.broadcast(PiPTimebaseCorrection(
      sequence: timebaseCorrectionSequence,
      capturedAt: Date().timeIntervalSince1970,
      systemUptime: ProcessInfo.processInfo.systemUptime,
      playbackGeneration: player.sessionGeneration,
      reason: reason,
      mediaTimeSeconds: mediaTimeSeconds,
      previousTimebaseSeconds: previousTimebaseSeconds,
      correctedTimebaseSeconds: correctedTimebaseSeconds,
      driftSeconds: mediaTimeSeconds - previousTimebaseSeconds,
      previousTimebaseRate: previousTimebaseRate,
      correctedTimebaseRate: correctedTimebaseRate
    ))
  }

  /// Writes and records a control-timebase rate change without fabricating a
  /// clock correction. Rate-only changes are just as important to a soak log:
  /// they prove when 0.5×/1×/2× playback was actually applied.
  func setTimebaseRate(
    _ rate: Double,
    reason: PiPTimebaseCorrectionReason,
    mediaTimeSeconds: Double
  ) {
    guard let timebase = controlTimebase else { return }
    let previousSeconds = CMTimebaseGetTime(timebase).seconds
    let previousRate = CMTimebaseGetRate(timebase)
    CMTimebaseSetRate(timebase, rate: rate)
    recordTimebaseCorrection(
      reason: reason,
      previousTimebaseSeconds: previousSeconds,
      correctedTimebaseSeconds: CMTimebaseGetTime(timebase).seconds,
      mediaTimeSeconds: mediaTimeSeconds,
      previousTimebaseRate: previousRate,
      correctedTimebaseRate: rate
    )
  }

  /// Sets the control timebase to the player's current position.
  func syncTimebaseTime(reason: PiPTimebaseCorrectionReason) {
    guard let timebase = controlTimebase else { return }
    let time = player.currentTime
    let seconds = Double(time.components.seconds)
      + Double(time.components.attoseconds) / 1e18
    let previousSeconds = CMTimebaseGetTime(timebase).seconds
    CMTimebaseSetTime(
      timebase,
      time: CMTime(seconds: seconds, preferredTimescale: 1000)
    )
    recordTimebaseCorrection(
      reason: reason,
      previousTimebaseSeconds: previousSeconds,
      correctedTimebaseSeconds: seconds,
      mediaTimeSeconds: seconds
    )
  }

  /// Updates the control timebase time and rate to match playback state.
  func syncTimebase(
    playing: Bool,
    reason: PiPTimebaseCorrectionReason = .playbackStateTransition
  ) {
    guard controlTimebase != nil else { return }
    let mediaTime = player.currentTime
    let mediaTimeSeconds = Double(mediaTime.components.seconds)
      + Double(mediaTime.components.attoseconds) / 1e18
    syncTimebaseTime(reason: reason)
    setTimebaseRate(
      playing ? Float64(player.rate) : 0.0,
      reason: reason,
      mediaTimeSeconds: mediaTimeSeconds
    )
  }
}
#endif
