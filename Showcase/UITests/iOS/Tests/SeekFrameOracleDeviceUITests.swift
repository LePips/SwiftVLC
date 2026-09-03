import XCTest

/// Candidate-bound physical-device proof for the completion-reporting seek
/// and exact-frame APIs. Typed outcomes come from the app process; decoded
/// content comes independently from screenshots of deterministic fixtures.
final class SeekFrameOracleDeviceUITests: ShowcaseIOSTestCase {
  private let analyzer = VideoOracleAnalyzer()

  func test_seekAndFrameRequestsMatchDecodedContent() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Seek/frame release oracles qualify only a physical device")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_SEEK_FRAME_ORACLE_DEVICE"] == "YES"
    else {
      throw XCTSkip("Set SWIFTVLC_SEEK_FRAME_ORACLE_DEVICE=YES for candidate-bound runs")
    }
    let encodedBaseURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SWIFTVLC_SEEK_FRAME_ORACLE_BASE_URL_BASE64"]
    )
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.seekFrameOracleValidation.rawValue,
      LaunchArguments.seekFrameOracleBaseURLBase64, encodedBaseURL
    ]
    launchDirectlyHandlingQualificationPermissions()

    let video = element(AccessibilityID.SeekFrameOracleValidation.videoView)
    let result = element(AccessibilityID.SeekFrameOracleValidation.resultLabel)
    XCTAssertTrue(video.waitForExistence(timeout: 10))

    _ = try runAction(
      AccessibilityID.SeekFrameOracleValidation.prepareSparseButton,
      result: result,
      timeout: 30
    )
    let precise = try runAction(
      AccessibilityID.SeekFrameOracleValidation.preciseSeekButton,
      result: result,
      timeout: 30
    )
    let preciseOracle = try waitForSeekOracle(
      video,
      expectedTimelineSeconds: 23.5,
      name: "precise-seek",
      timeout: 5
    )
    let preciseClock = try integer(precise, key: "currentTimeMilliseconds")
    XCTAssertEqual(precise["terminalOutcome"] as? String, "settled")
    XCTAssertEqual(precise["targetMilliseconds"] as? Int, 23500)
    XCTAssertEqual(preciseOracle.timelineSeconds, 23.5, accuracy: 0.75)
    XCTAssertEqual(Double(preciseClock) / 1000, preciseOracle.timelineSeconds, accuracy: 0.75)

    let fast = try runAction(
      AccessibilityID.SeekFrameOracleValidation.fastSeekButton,
      result: result,
      timeout: 30
    )
    let fastOracle = try waitForSeekOracle(
      video,
      expectedTimelineSeconds: 40,
      name: "fast-seek",
      timeout: 5
    )
    let fastClock = try integer(fast, key: "currentTimeMilliseconds")
    XCTAssertEqual(fast["terminalOutcome"] as? String, "settled")
    XCTAssertEqual(fast["fast"] as? Bool, true)
    XCTAssertEqual(fastOracle.timelineSeconds, 40, accuracy: 0.75)
    XCTAssertEqual(Double(fastClock) / 1000, fastOracle.timelineSeconds, accuracy: 0.75)

    let overlap = try runAction(
      AccessibilityID.SeekFrameOracleValidation.overlapSeekButton,
      result: result,
      timeout: 45
    )
    let overlapOracle = try waitForSeekOracle(
      video,
      expectedTimelineSeconds: 52.5,
      name: "overlap-seek",
      timeout: 5
    )
    let overlapClock = try integer(overlap, key: "currentTimeMilliseconds")
    XCTAssertEqual(
      overlap["terminalOutcomes"] as? [String],
      ["superseded", "superseded", "superseded", "settled"]
    )
    XCTAssertEqual(overlapOracle.timelineSeconds, 52.5, accuracy: 0.75)
    XCTAssertEqual(Double(overlapClock) / 1000, overlapOracle.timelineSeconds, accuracy: 0.75)

    let framePreparation = try runAction(
      AccessibilityID.SeekFrameOracleValidation.prepareFramesButton,
      result: result,
      timeout: 30
    )
    let baselineFrame = try captureFrameIndex(video, name: "frame-baseline")
    let baselineClock = try integer(framePreparation, key: "currentTimeMilliseconds")
    XCTAssertEqual(Double(baselineClock), Double(baselineFrame * 100), accuracy: 100)

    let single = try runAction(
      AccessibilityID.SeekFrameOracleValidation.stepOneButton,
      result: result,
      timeout: 15
    )
    let singleFrame = try waitForFrameIndex(
      video,
      equalTo: baselineFrame + 1,
      name: "frame-single",
      timeout: 5
    )
    let singleSubmittedTime = try integer(single, key: "submittedTimeMilliseconds")
    XCTAssertEqual(single["terminalOutcome"] as? String, "submitted")
    XCTAssertEqual(singleFrame, baselineFrame + 1)
    XCTAssertEqual(singleSubmittedTime, singleFrame * 100)

    let burstBaseline = try captureFrameIndex(video, name: "frame-burst-baseline")
    let burst = try runAction(
      AccessibilityID.SeekFrameOracleValidation.burstButton,
      result: result,
      timeout: 45
    )
    let burstFrame = try waitForFrameIndex(
      video,
      equalTo: burstBaseline + 20,
      name: "frame-burst-final",
      timeout: 5
    )
    let burstSubmittedTimes = try integerArray(burst, key: "submittedTimesMilliseconds")
    XCTAssertEqual(burst["requestCount"] as? Int, 20)
    XCTAssertEqual(Set(burst["terminalOutcomes"] as? [String] ?? []), ["submitted"])
    XCTAssertEqual(burstFrame, burstBaseline + 20)
    XCTAssertEqual(
      burstSubmittedTimes,
      ((burstBaseline + 1)...burstFrame).map { $0 * 100 }
    )

    let resumeBaseline = try captureFrameIndex(video, name: "resume-baseline")
    let resume = try runAction(
      AccessibilityID.SeekFrameOracleValidation.resumeButton,
      result: result,
      timeout: 20
    )
    let resumedFrame = try waitForFrameIndex(
      video,
      greaterThan: resumeBaseline,
      name: "resume-final",
      timeout: 5
    )
    let resumedClock = try integer(resume, key: "timeAfterMilliseconds")
    XCTAssertGreaterThan(
      resume["timeAfterMilliseconds"] as? Int ?? 0,
      resume["timeBeforeMilliseconds"] as? Int ?? .max
    )
    XCTAssertGreaterThan(resumedFrame, resumeBaseline)
    XCTAssertEqual(Double(resumedClock), Double(resumedFrame * 100), accuracy: 300)

    let eof = try runAction(
      AccessibilityID.SeekFrameOracleValidation.eofButton,
      result: result,
      timeout: 30
    )
    let eofFrame = try waitForFrameIndex(
      video,
      equalTo: 119,
      name: "frame-eof",
      timeout: 5
    )
    let eofSubmittedTimes = try integerArray(eof, key: "submittedTimesMilliseconds")
    XCTAssertEqual(eof["noFrameCount"] as? Int, 1)
    XCTAssertEqual((eof["terminalOutcomes"] as? [String])?.last, "noFrame")
    XCTAssertEqual(eofFrame, 119)
    XCTAssertEqual(eofSubmittedTimes, [11600, 11700, 11800, 11900])

    let replacement = try runAction(
      AccessibilityID.SeekFrameOracleValidation.replacementButton,
      result: result,
      timeout: 30
    )
    XCTAssertEqual(replacement["requestCount"] as? Int, 12)
    XCTAssertEqual(replacement["supersededCount"] as? Int, 12)
    XCTAssertEqual(Set(replacement["terminalOutcomes"] as? [String] ?? []), ["superseded"])

    assertNoLibraryErrors()
    let evidence: [String: Any] = [
      "formatVersion": 1,
      "scenario": "seek-frame-oracles",
      "seekResults": [
        "precise": "pass",
        "fastKeyframe": "pass",
        "overlap": "pass"
      ],
      "seekOracle": [
        "preciseTimelineSeconds": preciseOracle.timelineSeconds,
        "fastTimelineSeconds": fastOracle.timelineSeconds,
        "overlapTimelineSeconds": overlapOracle.timelineSeconds,
        "contentSource": "xcui-video-surface-screenshot"
      ],
      "seekClock": [
        "preciseMilliseconds": preciseClock,
        "fastMilliseconds": fastClock,
        "overlapMilliseconds": overlapClock
      ],
      "seekOutcomes": [
        "precise": precise["terminalOutcome"] as? String ?? "missing",
        "fast": fast["terminalOutcome"] as? String ?? "missing",
        "overlap": overlap["terminalOutcomes"] as? [String] ?? []
      ],
      "frameResults": [
        "single": "pass",
        "burst": "pass",
        "resumeClock": "pass",
        "eof": "pass",
        "replacement": "pass"
      ],
      "frameOracle": [
        "baselineIndex": baselineFrame,
        "baselineClockMilliseconds": baselineClock,
        "singleIndex": singleFrame,
        "burstBaselineIndex": burstBaseline,
        "burstFinalIndex": burstFrame,
        "resumeBaselineIndex": resumeBaseline,
        "resumeFinalIndex": resumedFrame,
        "resumeClockMilliseconds": resumedClock,
        "eofIndex": eofFrame,
        "singleSubmittedTimeMilliseconds": singleSubmittedTime,
        "burstSubmittedTimesMilliseconds": burstSubmittedTimes,
        "eofSubmittedTimesMilliseconds": eofSubmittedTimes,
        "contentSource": "xcui-video-surface-screenshot"
      ],
      "frameTerminals": [
        "single": single["terminalOutcome"] as? String ?? "missing",
        "burst": burst["terminalOutcomes"] as? [String] ?? [],
        "eof": eof["terminalOutcomes"] as? [String] ?? [],
        "replacement": replacement["terminalOutcomes"] as? [String] ?? []
      ],
      "libraryErrorCount": 0
    ]
    attachQualificationEvidence(evidence, scenario: "seek-frame-oracles")
    #endif
  }

  private func runAction(
    _ buttonIdentifier: String,
    result: XCUIElement,
    timeout: TimeInterval
  )
    throws -> [String: Any] {
    let prior = result.exists ? result.label : ""
    let button = app.buttons[buttonIdentifier]
    reveal(button, swiping: .up)
    XCTAssertTrue(button.isHittable, "Action button is not hittable: \(buttonIdentifier)")
    button.tap()
    reveal(result, swiping: .down)
    let predicate = NSPredicate { _, _ in
      guard result.exists, result.label != prior else { return false }
      return result.label.hasPrefix("pass:") || result.label.hasPrefix("failed:")
    }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(
      XCTWaiter.wait(for: [expectation], timeout: timeout),
      .completed,
      "Action did not publish a terminal result: \(buttonIdentifier)"
    )
    let label = result.label
    guard label.hasPrefix("pass:") else {
      XCTFail("Action failed: \(decodePayload(label) ?? [:])")
      return [:]
    }
    return try XCTUnwrap(decodePayload(label))
  }

  private func waitForSeekOracle(
    _ video: XCUIElement,
    expectedTimelineSeconds: Double,
    name: String,
    timeout: TimeInterval
  )
    throws -> SeekVideoOracleObservation {
    reveal(video, swiping: .down)
    let deadline = Date().addingTimeInterval(timeout)
    var lastObservation: SeekVideoOracleObservation?
    var lastScreenshot: XCUIScreenshot?
    while Date() < deadline {
      let screenshot = video.screenshot()
      lastScreenshot = screenshot
      if
        let frame = makeVideoOracleFrame(from: screenshot.image),
        let observation = analyzer.seekObservation(in: frame) {
        lastObservation = observation
        if abs(observation.timelineSeconds - expectedTimelineSeconds) <= 0.75 {
          attach(screenshot, name: name)
          return observation
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if let lastScreenshot {
      attach(lastScreenshot, name: "\(name)-timeout")
    }
    XCTFail(
      "Expected seek content near \(expectedTimelineSeconds)s; last decoded timeline was "
        + "\(String(describing: lastObservation?.timelineSeconds))"
    )
    return try XCTUnwrap(lastObservation)
  }

  private func captureFrameIndex(_ video: XCUIElement, name: String) throws -> Int {
    reveal(video, swiping: .down)
    let screenshot = video.screenshot()
    attach(screenshot, name: name)
    let frame = try XCTUnwrap(makeVideoOracleFrame(from: screenshot.image))
    return try XCTUnwrap(analyzer.allIntraFrameIndex(in: frame))
  }

  private func waitForFrameIndex(
    _ video: XCUIElement,
    equalTo expectedIndex: Int,
    name: String,
    timeout: TimeInterval
  )
    throws -> Int {
    try waitForFrameIndex(
      video,
      satisfying: { $0 == expectedIndex },
      expectationDescription: "frame index \(expectedIndex)",
      name: name,
      timeout: timeout
    )
  }

  private func waitForFrameIndex(
    _ video: XCUIElement,
    greaterThan baseline: Int,
    name: String,
    timeout: TimeInterval
  )
    throws -> Int {
    try waitForFrameIndex(
      video,
      satisfying: { $0 > baseline },
      expectationDescription: "a frame after index \(baseline)",
      name: name,
      timeout: timeout
    )
  }

  private func waitForFrameIndex(
    _ video: XCUIElement,
    satisfying predicate: (Int) -> Bool,
    expectationDescription: String,
    name: String,
    timeout: TimeInterval
  )
    throws -> Int {
    reveal(video, swiping: .down)
    let deadline = Date().addingTimeInterval(timeout)
    var lastIndex: Int?
    var lastScreenshot: XCUIScreenshot?
    while Date() < deadline {
      let screenshot = video.screenshot()
      lastScreenshot = screenshot
      if
        let frame = makeVideoOracleFrame(from: screenshot.image),
        let index = analyzer.allIntraFrameIndex(in: frame) {
        lastIndex = index
        if predicate(index) {
          attach(screenshot, name: name)
          return index
        }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    if let lastScreenshot {
      attach(lastScreenshot, name: "\(name)-timeout")
    }
    XCTFail(
      "Expected \(expectationDescription); last decoded index was \(String(describing: lastIndex))"
    )
    return try XCTUnwrap(lastIndex)
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

  private func decodePayload(_ label: String) -> [String: Any]? {
    guard let separator = label.firstIndex(of: ":") else { return nil }
    let encoded = String(label[label.index(after: separator)...])
    guard let data = Data(base64Encoded: encoded) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
  }

  private func integer(_ payload: [String: Any], key: String) throws -> Int {
    try XCTUnwrap(payload[key] as? Int, "Missing integer evidence: \(key)")
  }

  private func integerArray(_ payload: [String: Any], key: String) throws -> [Int] {
    try XCTUnwrap(payload[key] as? [Int], "Missing integer-array evidence: \(key)")
  }

  private func attach(_ screenshot: XCUIScreenshot, name: String) {
    let attachment = XCTAttachment(screenshot: screenshot)
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}
