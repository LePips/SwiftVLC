import Foundation
import XCTest

/// Physical-device authority for progressive HTTP Range behavior. Candidate
/// state/counters, independently captured pixels, and the host-retained server
/// transcript are intentionally separate evidence sources.
final class ProgressiveHTTPRangeSeekDeviceUITests: ShowcaseIOSTestCase {
  private let analyzer = VideoOracleAnalyzer()

  func test_progressiveRangeSeekUsesFresh206AndNoRangeRejectsStrictly() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Progressive HTTP Range qualification requires a physical device")
    #else
    let environment = ProcessInfo.processInfo.environment
    guard
      environment["SWIFTVLC_PROGRESSIVE_HTTP_RANGE_DEVICE"] == "YES",
      let encodedBaseURL = environment[
        "SWIFTVLC_PROGRESSIVE_HTTP_RANGE_BASE_URL_BASE64"
      ],
      let baseURLData = Data(base64Encoded: encodedBaseURL),
      let baseURLString = String(data: baseURLData, encoding: .utf8),
      URL(string: baseURLString) != nil,
      let attemptToken = environment["SWIFTVLC_PROGRESSIVE_HTTP_RANGE_ATTEMPT_TOKEN"],
      let fixtureSHA256 = environment["SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_SHA256"],
      let fixtureBytesText = environment["SWIFTVLC_PROGRESSIVE_HTTP_RANGE_FIXTURE_BYTES"],
      let fixtureBytes = Int(fixtureBytesText),
      fixtureSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
      fixtureBytes >= ProgressiveHTTPRangeSeekContract.minimumFixtureBytes
    else {
      throw XCTSkip("Set the candidate-bound progressive HTTP Range environment")
    }

    let range = try exercise(
      mode: .range,
      encodedBaseURL: encodedBaseURL,
      attemptToken: attemptToken
    )
    let noRange = try exercise(
      mode: .noRange,
      encodedBaseURL: encodedBaseURL,
      attemptToken: attemptToken
    )

    assertNoLibraryErrors()
    attachQualificationEvidence(
      [
        "fixture": [
          "id": ProgressiveHTTPRangeSeekContract.fixtureID,
          "relativePath": ProgressiveHTTPRangeSeekContract.fixtureRelativePath,
          "sha256": fixtureSHA256,
          "bytes": fixtureBytes,
          "durationMilliseconds":
            ProgressiveHTTPRangeSeekContract.expectedDurationMilliseconds,
          "targetMilliseconds": ProgressiveHTTPRangeSeekContract.targetMilliseconds,
          "landingBoundaryMilliseconds":
            ProgressiveHTTPRangeSeekContract.landingBoundaryMilliseconds
        ],
        "attemptToken": attemptToken,
        "rangeCase": range,
        "noRangeCase": noRange,
        "libraryErrorCount": 0
      ],
      scenario: "progressive-http-range-seek"
    )
    #endif
  }

  private func exercise(
    mode: ProgressiveHTTPRangeSeekContract.Mode,
    encodedBaseURL: String,
    attemptToken: String
  )
    throws -> [String: Any] {
    configureLaunch(
      mode: mode,
      encodedBaseURL: encodedBaseURL,
      attemptToken: attemptToken
    )
    launchDirectlyHandlingQualificationPermissions()

    let result = element(AccessibilityID.ProgressiveHTTPRangeSeekValidation.resultLabel)
    let error = element(AccessibilityID.ProgressiveHTTPRangeSeekValidation.errorLabel)
    let video = element(AccessibilityID.ProgressiveHTTPRangeSeekValidation.videoView)
    waitForLabel(result, equals: "ready", timeout: 35)
    XCTAssertTrue(video.waitForExistence(timeout: 5))
    XCTAssertFalse(error.exists, "Progressive preparation failed: \(error.label)")

    let command = app.buttons[AccessibilityID.ProgressiveHTTPRangeSeekValidation.commandButton]
    reveal(command, swiping: .up)
    XCTAssertTrue(command.isHittable)
    command.tap()
    waitForPrefix(
      result,
      prefix: mode == .range ? "landed:" : "rejected:",
      timeout: mode == .range ? 30 : 10
    )

    reveal(video, swiping: .down)
    var frames: [VideoSurfaceCanonicalFrame] = []
    var captureIntervals: [[String: Double]] = []
    var decodedBands: [Int] = []
    var decodedTimelines: [Double] = []
    for index in 0..<3 {
      let captureStart = ProcessInfo.processInfo.systemUptime
      let screenshot = video.screenshot()
      let captureEnd = ProcessInfo.processInfo.systemUptime
      XCTAssertGreaterThan(captureEnd, captureStart)
      XCTAssertLessThanOrEqual(
        captureEnd - captureStart,
        ProgressiveHTTPRangeSeekContract.maximumScreenshotCaptureIntervalSeconds
      )
      try frames.append(XCTUnwrap(makeCanonicalVideoSurfaceFrame(from: screenshot.image)))
      captureIntervals.append(
        [
          "startSystemUptimeSeconds": captureStart,
          "endSystemUptimeSeconds": captureEnd
        ]
      )
      let oracleFrame = try XCTUnwrap(makeVideoOracleFrame(from: screenshot.image))
      let observation = try XCTUnwrap(analyzer.seekObservation(in: oracleFrame))
      if mode == .range {
        XCTAssertEqual(observation.bandIndex, 4)
        XCTAssertGreaterThanOrEqual(
          observation.timelineSeconds,
          Double(
            ProgressiveHTTPRangeSeekContract.targetMilliseconds
              - ProgressiveHTTPRangeSeekContract.seekToleranceMilliseconds
          ) / 1000
        )
      }
      decodedBands.append(observation.bandIndex)
      decodedTimelines.append(observation.timelineSeconds)
      if index < 2 {
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
      }
    }
    let motion = try XCTUnwrap(VideoSurfaceMotionEvidenceAnalyzer.analyze(frames))
    XCTAssertGreaterThanOrEqual(motion.changedPixelScore, 0.01)
    XCTAssertEqual(Set(motion.frameHashes).count, 3)
    for (before, after) in zip(decodedTimelines, decodedTimelines.dropFirst()) {
      XCTAssertGreaterThan(after, before)
    }

    let finalize = app.buttons[AccessibilityID.ProgressiveHTTPRangeSeekValidation.finalizeButton]
    reveal(finalize, swiping: .up)
    XCTAssertTrue(finalize.isHittable)
    finalize.tap()
    waitForPrefix(result, prefix: "pass:", timeout: 10)
    XCTAssertFalse(error.exists, "Progressive command failed: \(error.label)")
    var raw = try decodeResult(result.label)
    var visual: [String: Any] = [
      "formatVersion": 1,
      "method": VideoSurfaceMotionEvidence.method,
      "encoding": "base64-rgb8-row-major",
      "frameWidthPixels": VideoSurfaceCanonicalFrame.width,
      "frameHeightPixels": VideoSurfaceCanonicalFrame.height,
      "channelCount": 3,
      "bytesPerFrame": VideoSurfaceCanonicalFrame.byteCount,
      "frameCount": 3,
      "captureSystemUptimeIntervals": captureIntervals,
      "canonicalRGB8Base64": frames.map { Data($0.rgb).base64EncodedString() },
      "frameHashes": motion.frameHashes,
      "adjacentChangedPixelRatios": motion.adjacentChangedPixelRatios,
      "changedPixelScore": motion.changedPixelScore,
      "distinctFrameHashes": Set(motion.frameHashes).count
    ]
    visual["decodedBandIndices"] = decodedBands
    visual["decodedTimelineSeconds"] = decodedTimelines
    raw["visualCapture"] = visual
    app.terminate()
    return raw
  }

  private func configureLaunch(
    mode: ProgressiveHTTPRangeSeekContract.Mode,
    encodedBaseURL: String,
    attemptToken: String
  ) {
    replaceLaunchArgument(
      LaunchArguments.route,
      with: UITestRoute.progressiveHTTPRangeSeekValidation.rawValue
    )
    replaceLaunchArgument(
      LaunchArguments.progressiveHTTPRangeBaseURLBase64,
      with: encodedBaseURL
    )
    replaceLaunchArgument(
      LaunchArguments.progressiveHTTPRangeAttemptToken,
      with: attemptToken
    )
    replaceLaunchArgument(LaunchArguments.progressiveHTTPRangeMode, with: mode.rawValue)
  }

  private func decodeResult(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func waitForPrefix(
    _ element: XCUIElement,
    prefix: String,
    timeout: TimeInterval
  ) {
    let predicate = NSPredicate { _, _ in
      element.exists && element.label.hasPrefix(prefix)
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func replaceLaunchArgument(_ key: String, with value: String) {
    while let index = app.launchArguments.firstIndex(of: key) {
      app.launchArguments.remove(at: index)
      if index < app.launchArguments.count {
        app.launchArguments.remove(at: index)
      }
    }
    app.launchArguments += [key, value]
  }

  private func reveal(_ element: XCUIElement, swiping direction: ShowcaseScrollDirection) {
    for _ in 0..<12 where !element.exists || !element.isHittable {
      direction.perform(in: app)
    }
    if !element.exists || !element.isHittable {
      for _ in 0..<24 where !element.exists || !element.isHittable {
        direction.opposite.perform(in: app)
      }
    }
    XCTAssertTrue(element.exists)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
