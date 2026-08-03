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
  case steadyStateDrift
  case skipLanding
}

/// One lossless control-timebase write emitted during PiP qualification.
@_spi(Qualification)
public struct PiPTimebaseCorrection: Codable, Sendable, Equatable {
  public let sequence: UInt64
  public let capturedAt: TimeInterval
  public let playbackGeneration: UInt64
  public let reason: PiPTimebaseCorrectionReason
  public let mediaTimeSeconds: Double
  public let previousTimebaseSeconds: Double
  public let correctedTimebaseSeconds: Double
  public let driftSeconds: Double
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
      correctionCount: timebaseCorrectionSequence
    )
  }

  func recordTimebaseCorrection(
    reason: PiPTimebaseCorrectionReason,
    previousTimebaseSeconds: Double,
    correctedTimebaseSeconds: Double,
    mediaTimeSeconds: Double
  ) {
    timebaseCorrectionSequence &+= 1
    timebaseCorrectionBroadcaster.broadcast(PiPTimebaseCorrection(
      sequence: timebaseCorrectionSequence,
      capturedAt: Date().timeIntervalSince1970,
      playbackGeneration: player.sessionGeneration,
      reason: reason,
      mediaTimeSeconds: mediaTimeSeconds,
      previousTimebaseSeconds: previousTimebaseSeconds,
      correctedTimebaseSeconds: correctedTimebaseSeconds,
      driftSeconds: mediaTimeSeconds - previousTimebaseSeconds
    ))
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
    guard let timebase = controlTimebase else { return }
    syncTimebaseTime(reason: reason)
    CMTimebaseSetRate(timebase, rate: playing ? Float64(player.rate) : 0.0)
  }
}
#endif
