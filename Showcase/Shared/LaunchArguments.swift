import Foundation

/// Contract between the UI test target (which sets these) and the showcase app
/// (which reads them via `UserDefaults`). Foundation copies any launch argument
/// of the form `-Key Value` into `NSUserDefaults` at process start, so the
/// dash-prefixed string here is the launch-arg name and the un-prefixed
/// version is the `UserDefaults` key.
enum LaunchArguments {
  static let fixtureURLEnvironment = "SWIFTVLC_APP_FIXTURE_URL"
  static let pipLiveURLEnvironment = "SWIFTVLC_APP_PIP_LIVE_URL"
  static let candidateRuntimeBindingInfoKey = "SwiftVLCCandidateRuntimeBinding"

  /// `YES` when running under XCUITest. Gates showcase behavior that should
  /// only run in UI tests.
  static let uiTestMode = "-UITestMode"

  /// Absolute path to a media file. When set, showcase media helpers resolve
  /// to this file instead of their bundled or remote sources.
  static let fixtureURL = "-UITestFixtureURL"
  static let fixtureURLBase64 = "-UITestFixtureURLBase64"

  /// Absolute path where the showcase mirrors `VLCInstance.shared.logStream`
  /// as JSONL records (one entry per line).
  static let logPath = "-UITestLogPath"

  /// Pipe-separated absolute paths or URLs used by Music Player UI tests to
  /// exercise distinct media swaps. Physical-device tests use HTTP because a
  /// runner-bundle path on the Mac is not reachable from the device app.
  static let musicFixtureURLs = "-UITestMusicFixtureURLs"

  /// Indefinite MPEG-TS stream used by the physical-device PiP validation
  /// lane. This remains operator-supplied so the repository never embeds a
  /// private or short-lived stream URL.
  static let pipLiveURL = "-UITestPiPLiveURL"
  static let pipLiveURLBase64 = "-UITestPiPLiveURLBase64"

  /// Per-attempt, discontinuity-aware four-hour HLS timeline used by the
  /// operator-assisted media-services reset lane. It must outlive the manual
  /// Settings interaction without relying on a byte-looped finite asset.
  static let audioMediaServicesResetURLBase64 =
    "-UITestAudioMediaServicesResetURLBase64"
  static let audioSessionOwnershipURLBase64 =
    "-UITestAudioSessionOwnershipURLBase64"

  /// Selects the PiP implementation exercised by the physical-device
  /// validation surface: `native` for `PiPVideoView`, `direct` for a hosted
  /// `PiPController.layer`.
  static let pipRenderingPath = "-UITestPiPRenderingPath"

  /// Selects one isolated action for the native-lifecycle qualification
  /// surface. Each action launches a fresh process so an earlier terminal
  /// transition cannot leak into the next case's evidence.
  static let pipNativeLifecycleAction = "-UITestPiPNativeLifecycleAction"
  static let pipNativeLifecycleToken = "-UITestPiPNativeLifecycleToken"

  /// Candidate-owned media and bounded post-foreground observation window
  /// for native AVSampleBufferVideoRenderer resource-revocation recovery.
  static let nativeRendererRecoveryURLBase64 = "-UITestNativeRendererRecoveryURLBase64"
  static let nativeRendererRecoveryObservationDuration =
    "-UITestNativeRendererRecoveryObservationDuration"

  /// Selects one isolated playback terminal transition. The physical-device
  /// test launches a fresh process for every action so one terminal generation
  /// cannot contaminate another case's evidence.
  static let terminalOutcomeAction = "-UITestTerminalOutcomeAction"
  static let terminalOutcomeToken = "-UITestTerminalOutcomeToken"

  /// Duration and server namespace for the candidate-bound adaptive HLS soak.
  /// The physical runner supplies 7,200 seconds; shorter values are useful
  /// only while developing the harness and cannot satisfy the matrix gate.
  static let adaptiveSoakDuration = "-UITestAdaptiveSoakDuration"
  static let adaptiveSoakToken = "-UITestAdaptiveSoakToken"

  /// Profile, fixture URL, and duration for the direct-PiP performance rows.
  static let pipPerformanceProfile = "-UITestPiPPerformanceProfile"
  static let pipPerformanceURLBase64 = "-UITestPiPPerformanceURLBase64"
  static let pipPerformanceDuration = "-UITestPiPPerformanceDuration"

  /// Deterministic local origin and duration for the physical cadence matrix.
  static let pipCadenceBaseURLBase64 = "-UITestPiPCadenceBaseURLBase64"
  static let pipCadenceDuration = "-UITestPiPCadenceDuration"

  /// Local origin, duration, and adaptive namespace for native subtitle/OSD
  /// physical qualification.
  static let nativeSubtitleBaseURLBase64 = "-UITestNativeSubtitleBaseURLBase64"
  static let nativeSubtitleDuration = "-UITestNativeSubtitleDuration"
  static let nativeSubtitleToken = "-UITestNativeSubtitleToken"

  /// Direct-PiP VOD/live clock soak configuration. The token binds fixture
  /// requests and host traces to one candidate attempt.
  static let timebaseSoakBaseURLBase64 = "-UITestTimebaseSoakBaseURLBase64"
  static let timebaseSoakDuration = "-UITestTimebaseSoakDuration"
  static let timebaseSoakMode = "-UITestTimebaseSoakMode"
  static let timebaseSoakToken = "-UITestTimebaseSoakToken"

  /// Deterministic local origin for sparse-GOP seek and all-intra exact-frame
  /// physical-device oracles.
  static let seekFrameOracleBaseURLBase64 = "-UITestSeekFrameOracleBaseURLBase64"

  /// Fixture origin and exact fixture identity for the local-file and
  /// audio-only physical qualification surfaces. The app downloads the
  /// candidate-bound bytes, persists them inside its own container, and then
  /// plays only the resulting file URL.
  static let localPlaybackBaseURLBase64 = "-UITestLocalPlaybackBaseURLBase64"
  static let localPlaybackFixtureID = "-UITestLocalPlaybackFixtureID"

  /// Per-attempt progressive HTTP seek origin. The token is shared with the
  /// host fixture server's immutable request/response transcript.
  static let progressiveHTTPRangeBaseURLBase64 =
    "-UITestProgressiveHTTPRangeBaseURLBase64"
  static let progressiveHTTPRangeAttemptToken =
    "-UITestProgressiveHTTPRangeAttemptToken"
  static let progressiveHTTPRangeMode = "-UITestProgressiveHTTPRangeMode"

  /// Name of a showcase to deep-link to on launch (e.g. `"SimplePlayback"`).
  /// When unset, the showcase opens its normal navigation tree.
  static let route = "-UITestRoute"

  static var isUITestMode: Bool {
    UserDefaults.standard.bool(forKey: key(uiTestMode))
  }

  /// Signed, per-build runtime identity exposed to the UI-test process only.
  /// The value lives in the candidate's sealed Info.plist; it is not supplied
  /// as a launch argument that any concurrently installed candidate could echo.
  static var qualificationCandidateRuntimeBindingValue: String? {
    guard
      isUITestMode,
      let value = Bundle.main.object(
        forInfoDictionaryKey: candidateRuntimeBindingInfoKey
      ) as? String,
      isLowercaseSHA256(value)
    else { return nil }
    return value
  }

  static func isLowercaseSHA256(_ value: String) -> Bool {
    value.utf8.count == 64 && value.utf8.allSatisfy { byte in
      (48...57).contains(byte) || (97...102).contains(byte)
    }
  }

  static var fixtureURLValue: URL? {
    if let url = encodedEnvironmentURL(named: fixtureURLEnvironment) {
      return url
    }
    if let url = encodedArgumentURL(named: fixtureURLBase64) {
      return url
    }
    guard let value = UserDefaults.standard.string(forKey: key(fixtureURL)) else { return nil }
    if let url = URL(string: value), url.scheme != nil {
      return url
    }
    return URL(fileURLWithPath: value)
  }

  static var logPathValue: String? {
    UserDefaults.standard.string(forKey: key(logPath))
  }

  static var musicFixtureURLValues: [URL] {
    UserDefaults.standard.string(forKey: key(musicFixtureURLs))?
      .split(separator: "|")
      .map { value in
        let rawValue = String(value)
        if let url = URL(string: rawValue), url.scheme != nil {
          return url
        }
        return URL(fileURLWithPath: rawValue)
      }
      ?? []
  }

  static var pipLiveURLValue: URL? {
    encodedEnvironmentURL(named: pipLiveURLEnvironment)
      ?? encodedArgumentURL(named: pipLiveURLBase64)
      ?? UserDefaults.standard.string(forKey: key(pipLiveURL)).flatMap(URL.init(string:))
  }

  static var audioMediaServicesResetURLValue: URL? {
    encodedArgumentURL(named: audioMediaServicesResetURLBase64)
  }

  static var audioSessionOwnershipURLValue: URL? {
    encodedArgumentURL(named: audioSessionOwnershipURLBase64)
  }

  static var pipRenderingPathValue: String? {
    UserDefaults.standard.string(forKey: key(pipRenderingPath))
  }

  static var pipNativeLifecycleActionValue: String? {
    UserDefaults.standard.string(forKey: key(pipNativeLifecycleAction))
  }

  static var pipNativeLifecycleTokenValue: String? {
    UserDefaults.standard.string(forKey: key(pipNativeLifecycleToken))
  }

  static var nativeRendererRecoveryURLValue: URL? {
    encodedArgumentURL(named: nativeRendererRecoveryURLBase64)
  }

  static var nativeRendererRecoveryObservationDurationValue: Int? {
    UserDefaults.standard.string(forKey: key(nativeRendererRecoveryObservationDuration))
      .flatMap(Int.init)
  }

  static var terminalOutcomeActionValue: String? {
    UserDefaults.standard.string(forKey: key(terminalOutcomeAction))
  }

  static var terminalOutcomeTokenValue: String? {
    UserDefaults.standard.string(forKey: key(terminalOutcomeToken))
  }

  static var adaptiveSoakDurationValue: Int? {
    UserDefaults.standard.string(forKey: key(adaptiveSoakDuration)).flatMap(Int.init)
  }

  static var adaptiveSoakTokenValue: String? {
    UserDefaults.standard.string(forKey: key(adaptiveSoakToken))
  }

  static var pipPerformanceProfileValue: String? {
    UserDefaults.standard.string(forKey: key(pipPerformanceProfile))
  }

  static var pipPerformanceURLValue: URL? {
    encodedArgumentURL(named: pipPerformanceURLBase64)
  }

  static var pipPerformanceDurationValue: Int? {
    UserDefaults.standard.string(forKey: key(pipPerformanceDuration)).flatMap(Int.init)
  }

  static var pipCadenceBaseURLValue: URL? {
    encodedArgumentURL(named: pipCadenceBaseURLBase64)
  }

  static var pipCadenceDurationValue: Int? {
    UserDefaults.standard.string(forKey: key(pipCadenceDuration)).flatMap(Int.init)
  }

  static var nativeSubtitleBaseURLValue: URL? {
    encodedArgumentURL(named: nativeSubtitleBaseURLBase64)
  }

  static var nativeSubtitleDurationValue: Int? {
    UserDefaults.standard.string(forKey: key(nativeSubtitleDuration)).flatMap(Int.init)
  }

  static var nativeSubtitleTokenValue: String? {
    UserDefaults.standard.string(forKey: key(nativeSubtitleToken))
  }

  static var timebaseSoakBaseURLValue: URL? {
    encodedArgumentURL(named: timebaseSoakBaseURLBase64)
  }

  static var timebaseSoakDurationValue: Int? {
    UserDefaults.standard.string(forKey: key(timebaseSoakDuration)).flatMap(Int.init)
  }

  static var timebaseSoakModeValue: String? {
    UserDefaults.standard.string(forKey: key(timebaseSoakMode))
  }

  static var timebaseSoakTokenValue: String? {
    UserDefaults.standard.string(forKey: key(timebaseSoakToken))
  }

  static var seekFrameOracleBaseURLValue: URL? {
    encodedArgumentURL(named: seekFrameOracleBaseURLBase64)
  }

  static var localPlaybackBaseURLValue: URL? {
    encodedArgumentURL(named: localPlaybackBaseURLBase64)
  }

  static var localPlaybackFixtureIDValue: String? {
    UserDefaults.standard.string(forKey: key(localPlaybackFixtureID))
  }

  static var progressiveHTTPRangeBaseURLValue: URL? {
    encodedArgumentURL(named: progressiveHTTPRangeBaseURLBase64)
  }

  static var progressiveHTTPRangeAttemptTokenValue: String? {
    UserDefaults.standard.string(forKey: key(progressiveHTTPRangeAttemptToken))
  }

  static var progressiveHTTPRangeModeValue: ProgressiveHTTPRangeSeekContract.Mode? {
    UserDefaults.standard.string(forKey: key(progressiveHTTPRangeMode))
      .flatMap(ProgressiveHTTPRangeSeekContract.Mode.init(rawValue:))
  }

  static var routeValue: String? {
    UserDefaults.standard.string(forKey: key(route))
  }

  private static func key(_ argument: String) -> String {
    String(argument.dropFirst())
  }

  private static func encodedEnvironmentURL(named name: String) -> URL? {
    ProcessInfo.processInfo.environment[name].flatMap(decodeURL)
  }

  private static func encodedArgumentURL(named name: String) -> URL? {
    UserDefaults.standard.string(forKey: key(name)).flatMap(decodeURL)
  }

  private static func decodeURL(_ encoded: String) -> URL? {
    guard
      let data = Data(base64Encoded: encoded),
      let value = String(data: data, encoding: .utf8)
    else { return nil }
    if let url = URL(string: value), url.scheme != nil {
      return url
    }
    return URL(fileURLWithPath: value)
  }
}

/// The showcase a test wants to deep-link into. The raw value is what the
/// test passes via `-UITestRoute <raw>` and what the showcase reads to
/// resolve the matching view.
enum UITestRoute: String, CaseIterable {
  case videoPlayer = "VideoPlayer"
  case musicPlayer = "MusicPlayer"
  case simplePlayback = "SimplePlayback"
  case playerState = "PlayerState"
  case seeking = "Seeking"
  case volume = "Volume"
  case abLoop = "ABLoop"
  case relativeSeek = "RelativeSeek"
  case frameStep = "FrameStep"
  case rate = "Rate"
  case thumbnails = "Thumbnails"
  case audioTracks = "AudioTracks"
  case snapshot = "Snapshot"
  case pip = "PiP"
  case audioOutputs = "AudioOutputs"
  case lifecycle = "Lifecycle"
  case aspectRatio = "AspectRatio"
  case deinterlacing = "Deinterlacing"
  case equalizer = "Equalizer"
  case audioChannels = "AudioChannels"
  case audioDelay = "AudioDelay"
  case recording = "Recording"
  case marquee = "Marquee"
  case adjustments = "Adjustments"
  case viewpoint = "Viewpoint"
  case subtitlesSelection = "SubtitlesSelection"
  case subtitlesExternal = "SubtitlesExternal"
  case chapters = "Chapters"
  case subtitlesDelay = "SubtitlesDelay"
  case subtitlesScale = "SubtitlesScale"
  case streamingHLS = "StreamingHLS"
  case playlistQueue = "PlaylistQueue"
  case discoveryLAN = "DiscoveryLAN"
  case discoveryRenderers = "DiscoveryRenderers"
  case metadata = "Metadata"
  case events = "Events"
  case statistics = "Statistics"
  case logs = "Logs"
  case thumbnailScrub = "ThumbnailScrub"
  case roleAndCork = "RoleAndCork"
  case multiTrackSelection = "MultiTrackSelection"
  case multiConsumer = "MultiConsumer"
  case harnessHome = "HarnessHome"
  case pipLiveValidation = "PiPLiveValidation"
  case pipCapabilityValidation = "PiPCapabilityValidation"
  case pipDeferredPauseValidation = "PiPDeferredPauseValidation"
  case pipDelayedStartFailureValidation = "PiPDelayedStartFailureValidation"
  case pipVODControlsValidation = "PiPVODControlsValidation"
  case pipLongStallValidation = "PiPLongStallValidation"
  case pipDismissalValidation = "PiPDismissalValidation"
  case pipInterruptionValidation = "PiPInterruptionValidation"
  case mediaServicesResetValidation = "MediaServicesResetValidation"
  case audioSessionOwnershipValidation = "AudioSessionOwnershipValidation"
  case pipNativeLifecycleValidation = "PiPNativeLifecycleValidation"
  case nativeRendererRecoveryValidation = "NativeRendererRecoveryValidation"
  case terminalOutcomesValidation = "TerminalOutcomesValidation"
  case adaptiveHLSSoakValidation = "AdaptiveHLSSoakValidation"
  case pipRenderPerformanceValidation = "PiPRenderPerformanceValidation"
  case pipCadenceValidation = "PiPCadenceValidation"
  case pipCadenceSemanticsProbe = "PiPCadenceSemanticsProbe"
  case nativeSubtitleMatrixValidation = "NativeSubtitleMatrixValidation"
  case timebaseSoakValidation = "TimebaseSoakValidation"
  case seekFrameOracleValidation = "SeekFrameOracleValidation"
  case localFileMatrixValidation = "LocalFileMatrixValidation"
  case audioOnlyPlaybackValidation = "AudioOnlyPlaybackValidation"
  case progressiveHTTPRangeSeekValidation = "ProgressiveHTTPRangeSeekValidation"

  static var current: UITestRoute? {
    LaunchArguments.routeValue.flatMap(UITestRoute.init(rawValue:))
  }
}
