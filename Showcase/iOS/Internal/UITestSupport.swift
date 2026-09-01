import Foundation
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Test-mode infrastructure for the showcase app. Every entry point is
/// gated on `LaunchArguments.isUITestMode`; in normal use, none of this code
/// runs.
enum UITestSupport {
  private static let logMirrorHealthModule = "swiftvlc.qualification.log-mirror"
  private static let logMirrorStartedMessage = "mirror-start/v1"

  /// Subscribes to `VLCInstance.shared.logStream` and writes one JSONL record
  /// per entry to the file at `-UITestLogPath`. Idempotent — safe to call
  /// once from `ShowcaseApp.init`.
  ///
  /// `fsync` after every write so the test process can read entries even if
  /// the app is forcibly terminated mid-scenario.
  static func startLogMirrorIfRequested() {
    guard
      LaunchArguments.isUITestMode,
      let path = LaunchArguments.logPathValue
    else { return }

    // A relative path is resolved under Documents so the device's log file
    // can be pulled back with `devicectl device copy from`, whose
    // appDataContainer domain is rooted at the app container.
    let url: URL
    if path.hasPrefix("/") {
      url = URL(fileURLWithPath: path)
    } else {
      let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      url = documents.appendingPathComponent(path)
    }
    let handle: FileHandle
    do {
      if !FileManager.default.fileExists(atPath: url.path) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
          throw LogMirrorError.couldNotCreateFile(url.path)
        }
      }
      handle = try FileHandle(forWritingTo: url)
      _ = try handle.seekToEnd()
      guard
        let logStream = VLCInstance.shared.qualificationLogStream(minimumLevel: .debug)
      else {
        throw LogMirrorError.callbackInstallationFailed
      }
      try writeLogRecord(
        LogRecord(
          ts: Date(),
          level: "debug",
          module: logMirrorHealthModule,
          message: logMirrorStartedMessage
        ),
        to: handle
      )

      Task.detached(priority: .utility) {
        defer {
          do {
            try handle.close()
          } catch {
            fatalError("Could not close the qualification log mirror: \(error)")
          }
        }

        do {
          for await entry in logStream {
            try writeLogRecord(
              LogRecord(
                ts: Date(),
                level: entry.level.description,
                module: entry.module,
                message: entry.message
              ),
              to: handle
            )
          }
        } catch {
          // Do not silently continue a qualification run after losing its
          // diagnostic channel. Terminating the UI-test-only app makes the
          // owning XCTest attempt fail instead of certifying incomplete logs.
          fatalError("Qualification log mirroring failed: \(error)")
        }
      }
    } catch {
      // Qualification must fail closed. A missing mirror can otherwise make
      // an error-free-looking, zero-byte file indistinguishable from a clean
      // run. This path is reachable only under the explicit UI-test launch
      // contract.
      fatalError("Could not start the qualification log mirror: \(error)")
    }
  }

  /// Mirrors one non-shared qualification instance into a child JSONL file.
  ///
  /// Some physical rows deliberately create separate libVLC instances to
  /// force distinct native audio-output modules or application-managed audio
  /// policy. `VLCInstance.shared` cannot see those instances' diagnostics, so
  /// each receives its own host-declared child log. The child name is part of
  /// the release-policy allowlist; arbitrary filenames are never accepted by
  /// the host evidence validator.
  static func startAdditionalLogMirrorIfRequested(
    from instance: VLCInstance,
    childName: String
  ) {
    guard
      LaunchArguments.isUITestMode,
      let path = LaunchArguments.logPathValue
    else { return }
    precondition(
      !childName.isEmpty
        && childName.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" },
      "Qualification child log names must be host-safe"
    )

    let baseURL = resolvedLogURL(path: path)
    let childURL = URL(
      fileURLWithPath:
      baseURL.deletingPathExtension().path + "-\(childName).jsonl"
    )
    do {
      if !FileManager.default.fileExists(atPath: childURL.path) {
        guard FileManager.default.createFile(atPath: childURL.path, contents: nil) else {
          throw LogMirrorError.couldNotCreateFile(childURL.path)
        }
      }
      let handle = try FileHandle(forWritingTo: childURL)
      _ = try handle.seekToEnd()
      guard
        let logStream = instance.qualificationLogStream(minimumLevel: .debug)
      else {
        throw LogMirrorError.callbackInstallationFailed
      }
      try writeLogRecord(
        LogRecord(
          ts: Date(),
          level: "debug",
          module: logMirrorHealthModule,
          message: logMirrorStartedMessage
        ),
        to: handle
      )

      Task.detached(priority: .utility) {
        defer { try? handle.close() }
        do {
          for await entry in logStream {
            try writeLogRecord(
              LogRecord(
                ts: Date(),
                level: entry.level.description,
                module: entry.module,
                message: entry.message
              ),
              to: handle
            )
          }
        } catch {
          fatalError("Additional qualification log mirroring failed: \(error)")
        }
      }
    } catch {
      fatalError("Could not start additional qualification log mirror: \(error)")
    }
  }

  private static func resolvedLogURL(path: String) -> URL {
    if path.hasPrefix("/") {
      return URL(fileURLWithPath: path)
    }
    let documents = FileManager.default.urls(
      for: .documentDirectory,
      in: .userDomainMask
    )[0]
    return documents.appendingPathComponent(path)
  }

  private static func writeLogRecord(_ record: LogRecord, to handle: FileHandle) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = try encoder.encode(record)
    data.append(0x0A)
    try handle.write(contentsOf: data)
    try handle.synchronize()
  }

  private enum LogMirrorError: Error {
    case couldNotCreateFile(String)
    case callbackInstallationFailed
  }

  private struct LogRecord: Codable {
    let ts: Date
    let level: String
    let module: String?
    let message: String
  }
}

extension View {
  /// Applies `.accessibilityIdentifier(_:)` only when `identifier` is
  /// non-nil. Avoids setting an empty-string identifier, which would
  /// make multiple sliders/rows share the same ambiguous ID and break
  /// UI test queries.
  @ViewBuilder
  func accessibilityIdentifier(ifPresent identifier: String?) -> some View {
    if let identifier {
      accessibilityIdentifier(identifier)
    } else {
      self
    }
  }
}

@MainActor
extension UITestRoute {
  /// The case-study view this route resolves to. Add a case here as each
  /// showcase grows UI tests.
  @ViewBuilder
  var view: some View {
    switch self {
    case .videoPlayer: VideoPlayerApp()
    case .musicPlayer: MusicPlayerApp()
    case .simplePlayback: SimplePlaybackCase()
    case .playerState: PlayerStateCase()
    case .seeking: SeekingCase()
    case .volume: VolumeCase()
    case .abLoop: ABLoopCase()
    case .relativeSeek: RelativeSeekCase()
    case .frameStep: FrameStepCase()
    case .rate: RateCase()
    case .thumbnails: ThumbnailsCase()
    case .audioTracks: AudioTracksCase()
    case .snapshot: SnapshotCase()
    case .pip: PiPCase()
    case .audioOutputs: AudioOutputsCase()
    case .lifecycle: LifecycleCase()
    case .aspectRatio: AspectRatioCase()
    case .deinterlacing: DeinterlacingCase()
    case .equalizer: EqualizerCase()
    case .audioChannels: AudioChannelsCase()
    case .audioDelay: AudioDelayCase()
    case .recording: RecordingCase()
    case .marquee: MarqueeCase()
    case .adjustments: VideoAdjustmentsCase()
    case .viewpoint: ViewpointCase()
    case .subtitlesSelection: SubtitlesSelectionCase()
    case .subtitlesExternal: SubtitlesExternalCase()
    case .chapters: ChaptersCase()
    case .subtitlesDelay: SubtitlesDelayCase()
    case .subtitlesScale: SubtitlesScaleCase()
    case .streamingHLS: StreamingHLSCase()
    case .playlistQueue: PlaylistQueueCase()
    case .discoveryLAN: DiscoveryLANCase()
    case .discoveryRenderers: DiscoveryRenderersCase()
    case .metadata: MetadataCase()
    case .events: EventsCase()
    case .statistics: StatisticsCase()
    case .logs: LogsCase()
    case .thumbnailScrub: ThumbnailScrubCase()
    case .roleAndCork: RoleAndCorkCase()
    case .multiTrackSelection: MultiTrackSelectionCase()
    case .multiConsumer: MultiConsumerEventsCase()
    case .harnessHome: HarnessHome()
    case .pipLiveValidation: PiPLiveValidationCase()
    case .pipCapabilityValidation: PiPCapabilityValidationCase()
    case .pipDeferredPauseValidation: PiPDeferredPauseValidationCase()
    case .pipDelayedStartFailureValidation: PiPDelayedStartFailureValidationCase()
    case .pipVODControlsValidation: PiPVODControlsValidationCase()
    case .pipLongStallValidation: PiPLongStallValidationCase()
    case .pipDismissalValidation: PiPDismissalValidationCase()
    case .pipInterruptionValidation: PiPInterruptionValidationCase()
    case .mediaServicesResetValidation: MediaServicesResetValidationCase()
    case .audioSessionOwnershipValidation: AudioSessionOwnershipValidationCase()
    case .pipNativeLifecycleValidation: PiPNativeLifecycleValidationCase()
    case .nativeRendererRecoveryValidation: NativeRendererRecoveryValidationCase()
    case .terminalOutcomesValidation: TerminalOutcomesValidationCase()
    case .adaptiveHLSSoakValidation: AdaptiveHLSSoakValidationCase()
    case .pipRenderPerformanceValidation: PiPRenderPerformanceValidationCase()
    case .pipCadenceValidation: PiPCadenceValidationCase()
    case .pipCadenceSemanticsProbe: PiPCadenceSemanticsProbeValidationCase()
    case .nativeSubtitleMatrixValidation: NativeSubtitleMatrixValidationCase()
    case .timebaseSoakValidation: TimebaseSoakValidationCase()
    case .seekFrameOracleValidation: SeekFrameOracleValidationCase()
    case .localFileMatrixValidation: LocalFileMatrixValidationCase()
    case .audioOnlyPlaybackValidation: AudioOnlyPlaybackValidationCase()
    case .progressiveHTTPRangeSeekValidation: ProgressiveHTTPRangeSeekValidationCase()
    }
  }
}
