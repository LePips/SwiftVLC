import XCTest

/// Exercises every required CFR/VFR source while driving the real SpringBoard
/// PiP resize surface. The app records direct-renderer counters and transition
/// state; this test validates and attaches the candidate-bound evidence.
final class PiPCadenceDeviceUITests: ShowcaseIOSTestCase {
  func test_directPiPCadenceMatrix() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("The cadence matrix qualifies only a physical iPhone")
    #else
    guard ProcessInfo.processInfo.environment["SWIFTVLC_PIP_CADENCE_DEVICE"] == "YES"
    else {
      throw XCTSkip("Set SWIFTVLC_PIP_CADENCE_DEVICE=YES for candidate-bound hardware runs")
    }
    let duration = max(
      1,
      Int(ProcessInfo.processInfo.environment["SWIFTVLC_CADENCE_SECONDS"] ?? "600")
        ?? 600
    )
    let encodedBaseURL = try XCTUnwrap(
      ProcessInfo.processInfo.environment["SWIFTVLC_PIP_CADENCE_BASE_URL_BASE64"]
    )
    app.launchArguments += [
      LaunchArguments.route, UITestRoute.pipCadenceValidation.rawValue,
      LaunchArguments.pipCadenceBaseURLBase64, encodedBaseURL,
      LaunchArguments.pipCadenceDuration, String(duration)
    ]
    launchDirectlyHandlingQualificationPermissions()

    let possible = element(AccessibilityID.PiPCadenceValidation.possibleLabel)
    let active = element(AccessibilityID.PiPCadenceValidation.activeLabel)
    let result = element(AccessibilityID.PiPCadenceValidation.resultLabel)
    let run = app.buttons[AccessibilityID.PiPCadenceValidation.runButton]
    let video = element(AccessibilityID.PiPCadenceValidation.videoView)
    let error = element(AccessibilityID.PiPCadenceValidation.errorLabel)
    waitForLabel(possible, equals: "yes", timeout: 30)
    reveal(run)
    XCTAssertTrue(run.isEnabled)
    let runTappedSystemUptime = ProcessInfo.processInfo.systemUptime
    run.tap()
    waitForLabel(active, equals: "yes", timeout: 60)
    assertRendersNonBlackFrame(video, timeout: 15)

    XCUIDevice.shared.press(.home)
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    var region = try locateSystemPictureInPictureWindow()
    let samplingDeadline = max(1, min(400, duration - 200))
    let captureDeadlineSystemUptime =
      runTappedSystemUptime
        + TimeInterval(samplingDeadline + 10)
    var timedFrames: [CadenceTimedFrame] = []
    while ProcessInfo.processInfo.systemUptime < captureDeadlineSystemUptime {
      let captureStarted = ProcessInfo.processInfo.systemUptime
      let frame = try captureSystemPictureInPictureCanonicalFrame(in: region)
      let captureFinished = ProcessInfo.processInfo.systemUptime
      timedFrames.append(
        CadenceTimedFrame(
          systemUptime: (captureStarted + captureFinished) / 2,
          frame: frame
        )
      )
      RunLoop.current.run(until: Date().addingTimeInterval(0.75))
    }

    let deadlineSystemUptime = runTappedSystemUptime + TimeInterval(duration)
    var resizeGestures = 0
    while ProcessInfo.processInfo.systemUptime < deadlineSystemUptime - 8 {
      springboard.coordinate(
        withNormalizedOffset: region.normalizedPoint(x: 0.5, y: 0.5)
      ).doubleTap()
      resizeGestures += 1
      RunLoop.current.run(until: Date().addingTimeInterval(12))
      region = try locateSystemPictureInPictureWindow(
        samples: 5,
        interval: 0.25,
        retainDiagnostics: false
      )
    }
    XCTAssertGreaterThanOrEqual(resizeGestures, max(4, duration / 90))
    if let motionFailure = captureSystemPictureInPictureMotion() {
      XCTFail("PiP stopped rendering during cadence transitions: \(motionFailure)")
    }

    app.activate()
    waitForPrefix(result, prefix: "pass:", timeout: 180)
    XCTAssertFalse(error.exists, "Cadence row failed: \(error.label)")
    assertRendersNonBlackFrame(video, timeout: 15)

    var evidence = try decodeEvidence(result.label)
    evidence["springboardResizeGestures"] = resizeGestures
    let expectedRates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
    XCTAssertEqual(evidence["rates"] as? [Double], expectedRates)
    XCTAssertEqual(evidence["vfr"] as? Bool, true)
    XCTAssertGreaterThanOrEqual(evidence["durationSeconds"] as? Int ?? 0, 600)
    XCTAssertEqual(evidence["fabricatedDurationCount"] as? Int, 0)
    XCTAssertEqual(
      evidence["sourceTimestampProvenance"] as? String,
      "libvlc-picture_t.date-native-callback-v1"
    )
    XCTAssertEqual(
      evidence["vmemOutputTimestampProvenance"] as? String,
      "libvlc-vmem-post-filter-vout-selected-output-attempt-pts-v1"
    )
    let visualBundle = try cadenceVisualBundle(
      evidence: evidence,
      timedFrames: timedFrames
    )
    evidence["visualObservations"] = [
      "formatVersion": 1,
      "method": VideoSurfaceMotionEvidence.method,
      "records": visualBundle.rawRecords
    ]
    evidence["visualCaptureBindings"] = [
      "formatVersion": 1,
      "method": VideoSurfaceMotionEvidence.method,
      "records": visualBundle.captureBindings
    ]
    evidence["cadenceOracle"] = [
      "formatVersion": 1,
      "windowSeconds": 5,
      "rateToleranceFraction": 0.15,
      "minimumVisualMotionScore": 0.01,
      "vfrObservedRegimesFPS": [24.0, 60.0],
      "windows": visualBundle.oracleWindows
    ]
    let metrics = try XCTUnwrap(evidence["presentationMetrics"] as? [[String: Any]])
    XCTAssertEqual(metrics.count, 9)
    for metric in metrics {
      let profile = try XCTUnwrap(metric["profile"] as? String)
      let retained = try XCTUnwrap(visualBundle.rendererTotalsByProfile[profile])
      let delivered = try XCTUnwrap(metric["deliveredFrames"] as? NSNumber).uint64Value
      let dropped = try XCTUnwrap(metric["droppedFrames"] as? NSNumber).uint64Value
      let backpressure = try XCTUnwrap(
        metric["backpressureEvents"] as? NSNumber
      ).uint64Value
      let elapsed = try XCTUnwrap(metric["elapsedSeconds"] as? NSNumber).doubleValue
      let dropRate = try XCTUnwrap(metric["dropRate"] as? NSNumber).doubleValue
      let presentationRate = try XCTUnwrap(
        metric["presentationRate"] as? NSNumber
      ).doubleValue
      let total = delivered.addingReportingOverflow(dropped)
      XCTAssertFalse(total.overflow)
      let expectedDropRate =
        total.partialValue > 0 ? Double(dropped) / Double(total.partialValue) : 1
      XCTAssertGreaterThan(delivered, 0)
      XCTAssertGreaterThan(presentationRate, 0)
      XCTAssertEqual(dropRate, expectedDropRate, accuracy: 1e-9)
      XCTAssertEqual(presentationRate, Double(delivered) / elapsed, accuracy: 1e-6)
      XCTAssertGreaterThanOrEqual(delivered, retained.deliveredFrames)
      XCTAssertGreaterThanOrEqual(dropped, retained.droppedFrames)
      XCTAssertGreaterThanOrEqual(backpressure, retained.backpressureEvents)
      XCTAssertGreaterThanOrEqual(elapsed, retained.windowDurationSeconds)
      XCTAssertEqual(metric["presentationCopyFailures"] as? Int, 0)
      XCTAssertEqual(metric["displayConsumeFailures"] as? Int, 0)
    }
    let transitions = try XCTUnwrap(evidence["transitionResults"] as? [String: Any])
    XCTAssertGreaterThanOrEqual(transitions["pauseResumeCycles"] as? Int ?? 0, 9)
    XCTAssertGreaterThanOrEqual(transitions["rateChanges"] as? Int ?? 0, 27)
    XCTAssertGreaterThanOrEqual(transitions["replacements"] as? Int ?? 0, 8)
    XCTAssertGreaterThan(transitions["resizeCycles"] as? Int ?? 0, 0)
    XCTAssertEqual(transitions["monotonicityViolations"] as? Int, 0)
    attachQualificationEvidence(evidence, scenario: "cadence-matrix")
    #endif
  }

  private func decodeEvidence(_ label: String) throws -> [String: Any] {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix))
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func cadenceVisualBundle(
    evidence: [String: Any],
    timedFrames: [CadenceTimedFrame]
  )
    throws -> CadenceVisualBundle {
    let startedSystemUptime = try number(
      evidence["startedSystemUptime"],
      description: "cadence start uptime"
    )
    let samples = try XCTUnwrap(evidence["samples"] as? [[String: Any]])
    XCTAssertGreaterThanOrEqual(
      samples.count,
      54,
      "Expected one retained pair per profile/rate"
    )
    var windows: [CadenceRetainedWindow] = []
    for (beforeValue, afterValue) in zip(samples, samples.dropFirst()) {
      let before = try CadenceRawSample(beforeValue)
      let after = try CadenceRawSample(afterValue)
      guard
        before.profile == after.profile,
        before.playbackGeneration == after.playbackGeneration,
        before.requestedRate == after.requestedRate,
        before.effectivePlayerRate == after.effectivePlayerRate,
        before.vmemOutputPlaybackGeneration == after.vmemOutputPlaybackGeneration,
        before.vmemOutputVoutGeneration == after.vmemOutputVoutGeneration
      else { continue }
      let duration = after.elapsedSeconds - before.elapsedSeconds
      guard (5...6).contains(duration) else { continue }
      try windows.append(CadenceRetainedWindow(before: before, after: after))
    }

    XCTAssertEqual(windows.count, 27, "Cadence evidence omitted a stable rate window")
    let requiredProfiles = Set([
      "23.976", "24", "25", "29.97", "30", "50", "59.94", "60", "vfr-24-60"
    ])
    XCTAssertEqual(Set(windows.map(\.profile)), requiredProfiles)
    for profile in requiredProfiles {
      XCTAssertEqual(
        Set(windows.filter { $0.profile == profile }.map(\.requestedRate)),
        Set([0.5, 1.0, 2.0]),
        "Missing cadence rate coverage for \(profile)"
      )
    }

    var rawRecords: [[String: Any]] = []
    var oracleWindows: [[String: Any]] = []
    var captureBindings: [[String: Any]] = []
    var rendererTotalsByProfile: [String: CadenceRendererWindowTotals] = [:]
    for window in windows {
      var totals = rendererTotalsByProfile[window.profile] ?? .init()
      try totals.add(window)
      rendererTotalsByProfile[window.profile] = totals
      // Retain the legacy conservative elapsed-time binding while making the
      // exact Double snapshot boundaries authoritative.
      let lowerBound = max(
        window.windowStartSystemUptime,
        startedSystemUptime + TimeInterval(window.startElapsedSeconds) + 1.05
      )
      let upperBound = min(
        window.windowEndSystemUptime,
        startedSystemUptime
          + TimeInterval(window.startElapsedSeconds + window.durationSeconds)
          - 0.05
      )
      let candidates = timedFrames.filter {
        $0.systemUptime > lowerBound && $0.systemUptime < upperBound
      }
      guard candidates.count >= 3 else {
        throw CadenceVisualFailure(
          "Only \(candidates.count) PiP frames fell inside "
            + "\(window.profile)@\(window.requestedRate)x"
        )
      }
      let selected = selectThreeFrames(candidates)
      let visual = try XCTUnwrap(
        VideoSurfaceMotionEvidenceAnalyzer.analyze(selected.map(\.frame))
      )
      XCTAssertGreaterThanOrEqual(
        visual.changedPixelScore,
        0.01,
        "System PiP froze during \(window.profile)@\(window.requestedRate)x"
      )
      XCTAssertEqual(
        Set(visual.frameHashes).count,
        visual.frameHashes.count,
        "System PiP repeated a captured frame during \(window.profile)@\(window.requestedRate)x"
      )
      rawRecords.append(window.rawRecord(visual: visual))
      oracleWindows.append(window.oracleWindow(visual: visual))
      captureBindings.append(
        window.captureBinding(
          frames: selected,
          startedSystemUptime: startedSystemUptime
        )
      )
    }
    return CadenceVisualBundle(
      rawRecords: rawRecords,
      oracleWindows: oracleWindows,
      captureBindings: captureBindings,
      rendererTotalsByProfile: rendererTotalsByProfile
    )
  }

  private func selectThreeFrames(
    _ frames: [CadenceTimedFrame]
  ) -> [CadenceTimedFrame] {
    [frames[0], frames[frames.count / 2], frames[frames.count - 1]]
  }

  private func number(_ value: Any?, description: String) throws -> Double {
    guard let number = value as? NSNumber else {
      throw CadenceVisualFailure("Missing \(description)")
    }
    return number.doubleValue
  }

  private func waitForPrefix(_ element: XCUIElement, prefix: String, timeout: TimeInterval) {
    let predicate = NSPredicate { _, _ in element.exists && element.label.hasPrefix(prefix) }
    let expectation = expectation(for: predicate, evaluatedWith: NSObject())
    XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<10 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }
}

private struct CadenceTimedFrame {
  let systemUptime: TimeInterval
  let frame: VideoSurfaceCanonicalFrame
}

private struct CadenceVisualBundle {
  let rawRecords: [[String: Any]]
  let oracleWindows: [[String: Any]]
  let captureBindings: [[String: Any]]
  let rendererTotalsByProfile: [String: CadenceRendererWindowTotals]
}

private struct CadenceRendererWindowTotals {
  var deliveredFrames: UInt64 = 0
  var droppedFrames: UInt64 = 0
  var backpressureEvents: UInt64 = 0
  var windowDurationSeconds: Double = 0

  mutating func add(_ window: CadenceRetainedWindow) throws {
    deliveredFrames = try Self.sum(deliveredFrames, window.deliveredFrames)
    droppedFrames = try Self.sum(droppedFrames, window.droppedFrames)
    backpressureEvents = try Self.sum(backpressureEvents, window.backpressureEvents)
    windowDurationSeconds += window.windowDurationSeconds
  }

  private static func sum(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let result = lhs.addingReportingOverflow(rhs)
    guard !result.overflow else {
      throw CadenceVisualFailure("Renderer retained-window counter overflowed")
    }
    return result.partialValue
  }
}

private struct CadenceRawSample {
  let profile: String
  /// Parsed only to keep the legacy compatibility object structurally honest.
  let sourceIntervalCounts: [String: UInt64]
  let systemUptime: Double
  let elapsedSeconds: Int
  let playbackGeneration: UInt64
  let requestedRate: Double
  let effectivePlayerRate: Double
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let backpressureEvents: UInt64
  let vmemOutputPlaybackGeneration: UInt64
  let vmemOutputVoutGeneration: UInt64
  let vmemOutputCallbackCount: UInt64
  let vmemOutputValidPTSCount: UInt64
  let vmemOutputInvalidPTSCount: UInt64
  let vmemOutputDuplicatePTSCount: UInt64
  let vmemOutputBackwardPTSCount: UInt64
  let vmemOutputDeltaOverflowCount: UInt64
  let vmemOutputSubmittedCount: UInt64
  let vmemOutputSwiftRejectedCount: UInt64
  let vmemOutputInFlightCount: UInt64
  let vmemOutputFirstPTSUS: Int64
  let vmemOutputLastPTSUS: Int64
  let vmemOutputFirstValidPTSUS: Int64
  let vmemOutputLastValidPTSUS: Int64
  let vmemOutputDeltaHistogram: [PiPCadenceProbeDeltaCount]
  let libVLCDecodedVideoCount: UInt64
  let libVLCDisplayedPictureCount: UInt64
  let libVLCLostPictureCount: UInt64
  let libVLCLatePictureCount: UInt64

  init(_ value: [String: Any]) throws {
    guard
      let profile = value["profile"] as? String,
      let counts = value["sourceIntervalCounts"] as? [String: Any],
      value["vmemOutputTimestampProvenance"] as? String
      == "libvlc-vmem-post-filter-vout-selected-output-attempt-pts-v1"
    else {
      throw CadenceVisualFailure("Malformed cadence raw sample identity")
    }
    self.profile = profile
    sourceIntervalCounts = try Self.intervalCounts(counts)
    systemUptime = try Self.double(value, "systemUptime")
    elapsedSeconds = try Self.int(value, "elapsedSeconds")
    playbackGeneration = try Self.uint64(value, "playbackGeneration")
    requestedRate = try Self.double(value, "requestedRate")
    effectivePlayerRate = try Self.double(value, "effectivePlayerRate")
    deliveredFrames = try Self.uint64(value, "deliveredFrames")
    droppedFrames = try Self.uint64(value, "droppedFrames")
    backpressureEvents = try Self.uint64(value, "backpressureEvents")
    vmemOutputPlaybackGeneration = try Self.uint64(
      value, "vmemOutputPlaybackGeneration"
    )
    vmemOutputVoutGeneration = try Self.uint64(value, "vmemOutputVoutGeneration")
    vmemOutputCallbackCount = try Self.uint64(value, "vmemOutputCallbackCount")
    vmemOutputValidPTSCount = try Self.uint64(value, "vmemOutputValidPTSCount")
    vmemOutputInvalidPTSCount = try Self.uint64(value, "vmemOutputInvalidPTSCount")
    vmemOutputDuplicatePTSCount = try Self.uint64(
      value, "vmemOutputDuplicatePTSCount"
    )
    vmemOutputBackwardPTSCount = try Self.uint64(
      value, "vmemOutputBackwardPTSCount"
    )
    vmemOutputDeltaOverflowCount = try Self.uint64(
      value, "vmemOutputDeltaOverflowCount"
    )
    vmemOutputSubmittedCount = try Self.uint64(value, "vmemOutputSubmittedCount")
    vmemOutputSwiftRejectedCount = try Self.uint64(
      value, "vmemOutputSwiftRejectedCount"
    )
    vmemOutputInFlightCount = try Self.uint64(value, "vmemOutputInFlightCount")
    vmemOutputFirstPTSUS = try Self.int64(value, "vmemOutputFirstPTSUS")
    vmemOutputLastPTSUS = try Self.int64(value, "vmemOutputLastPTSUS")
    vmemOutputFirstValidPTSUS = try Self.int64(
      value, "vmemOutputFirstValidPTSUS"
    )
    vmemOutputLastValidPTSUS = try Self.int64(value, "vmemOutputLastValidPTSUS")
    vmemOutputDeltaHistogram = try Self.histogram(value)
    libVLCDecodedVideoCount = try Self.uint64(value, "libVLCDecodedVideoCount")
    libVLCDisplayedPictureCount = try Self.uint64(
      value, "libVLCDisplayedPictureCount"
    )
    libVLCLostPictureCount = try Self.uint64(value, "libVLCLostPictureCount")
    libVLCLatePictureCount = try Self.uint64(value, "libVLCLatePictureCount")
    guard
      vmemOutputPlaybackGeneration == playbackGeneration,
      vmemOutputVoutGeneration > 0
    else {
      throw CadenceVisualFailure("Cadence raw sample generation identity was invalid")
    }
  }

  private static let intervalKeys = [
    "fps23_976", "fps24", "fps25", "fps29_97", "fps30",
    "fps50", "fps59_94", "fps60", "other"
  ]

  private static func intervalCounts(
    _ value: [String: Any]
  )
    throws -> [String: UInt64] {
    guard Set(value.keys) == Set(intervalKeys) else {
      throw CadenceVisualFailure("Legacy vmem interval schema changed")
    }
    return try Dictionary(
      uniqueKeysWithValues: intervalKeys.map { key in
        guard let number = value[key] as? NSNumber else {
          throw CadenceVisualFailure("Legacy vmem interval \(key) was missing")
        }
        return (key, number.uint64Value)
      }
    )
  }

  private static func histogram(
    _ value: [String: Any]
  )
    throws -> [PiPCadenceProbeDeltaCount] {
    guard let entries = value["vmemOutputDeltaHistogram"] as? [[String: Any]] else {
      throw CadenceVisualFailure("Missing vmem output PTS histogram")
    }
    var result: [PiPCadenceProbeDeltaCount] = []
    for entry in entries {
      guard
        Set(entry.keys) == Set(["deltaMicroseconds", "count"]),
        let delta = entry["deltaMicroseconds"] as? NSNumber,
        let count = entry["count"] as? NSNumber,
        count.uint64Value > 0
      else { throw CadenceVisualFailure("Malformed vmem output PTS histogram") }
      result.append(
        .init(deltaMicroseconds: delta.int64Value, count: count.uint64Value)
      )
    }
    guard
      zip(result, result.dropFirst()).allSatisfy({
        $0.deltaMicroseconds < $1.deltaMicroseconds
      })
    else { throw CadenceVisualFailure("Vmem output PTS histogram was not sorted") }
    return result
  }

  private static func double(_ value: [String: Any], _ key: String) throws -> Double {
    guard let number = value[key] as? NSNumber, number.doubleValue.isFinite else {
      throw CadenceVisualFailure("Missing cadence raw sample \(key)")
    }
    return number.doubleValue
  }

  private static func int(_ value: [String: Any], _ key: String) throws -> Int {
    guard let number = value[key] as? NSNumber else {
      throw CadenceVisualFailure("Missing cadence raw sample \(key)")
    }
    return number.intValue
  }

  private static func uint64(_ value: [String: Any], _ key: String) throws -> UInt64 {
    guard let number = value[key] as? NSNumber else {
      throw CadenceVisualFailure("Missing cadence raw sample \(key)")
    }
    return number.uint64Value
  }

  private static func int64(_ value: [String: Any], _ key: String) throws -> Int64 {
    guard let number = value[key] as? NSNumber else {
      throw CadenceVisualFailure("Missing cadence raw sample \(key)")
    }
    return number.int64Value
  }
}

private struct CadenceRetainedWindow {
  let profile: String
  let requestedRate: Double
  let startElapsedSeconds: Int
  let durationSeconds: Int
  let windowStartSystemUptime: Double
  let windowEndSystemUptime: Double
  let windowDurationSeconds: Double
  let appliedRate: Double
  let nativePTSDeltaSeconds: Double
  let nativePTSClassification: PiPCadenceProbeMultipleClassification
  let nativePTSDeltaOverflowCount: UInt64
  let nativePTSDeltaHistogram: [PiPCadenceProbeDeltaCount]
  let outputCallbackCount: UInt64
  let submittedFrames: UInt64
  let swiftRejectedFrames: UInt64
  let observedSubmissionFPS: Double
  let minimumSubmissionFPS: Double
  let libVLCDecodedVideoDelta: UInt64
  let libVLCDisplayedPictureDelta: UInt64
  let libVLCLostPictureDelta: UInt64
  let libVLCLatePictureDelta: UInt64
  let deliveredFrames: UInt64
  let droppedFrames: UInt64
  let backpressureEvents: UInt64

  init(before: CadenceRawSample, after: CadenceRawSample) throws {
    let duration = after.elapsedSeconds - before.elapsedSeconds
    let exactDuration = after.systemUptime - before.systemUptime
    guard
      after.elapsedSeconds > before.elapsedSeconds,
      (5...6).contains(duration),
      (5...6).contains(exactDuration),
      after.vmemOutputFirstPTSUS == before.vmemOutputFirstPTSUS,
      after.vmemOutputFirstValidPTSUS == before.vmemOutputFirstValidPTSUS,
      after.vmemOutputInFlightCount == before.vmemOutputInFlightCount,
      after.vmemOutputInFlightCount == 0
    else {
      throw CadenceVisualFailure("Cadence retained boundary was not stable")
    }

    let histogram = try Self.histogramDelta(
      before.vmemOutputDeltaHistogram,
      after.vmemOutputDeltaHistogram
    )
    let callbackCount = try Self.delta(
      before.vmemOutputCallbackCount, after.vmemOutputCallbackCount,
      "output callback"
    )
    let submitted = try Self.delta(
      before.vmemOutputSubmittedCount, after.vmemOutputSubmittedCount,
      "submitted callback"
    )
    let rejected = try Self.delta(
      before.vmemOutputSwiftRejectedCount, after.vmemOutputSwiftRejectedCount,
      "Swift-rejected callback"
    )
    let overflow = try Self.delta(
      before.vmemOutputDeltaOverflowCount, after.vmemOutputDeltaOverflowCount,
      "PTS delta overflow"
    )
    let delivered = try Self.delta(
      before.deliveredFrames, after.deliveredFrames, "delivered frame"
    )
    let dropped = try Self.delta(
      before.droppedFrames, after.droppedFrames, "dropped frame"
    )
    let backpressure = try Self.delta(
      before.backpressureEvents, after.backpressureEvents, "backpressure event"
    )
    let decoded = try Self.delta(
      before.libVLCDecodedVideoCount, after.libVLCDecodedVideoCount,
      "libVLC decoded video"
    )
    let displayed = try Self.delta(
      before.libVLCDisplayedPictureCount, after.libVLCDisplayedPictureCount,
      "libVLC displayed picture"
    )
    let lost = try Self.delta(
      before.libVLCLostPictureCount, after.libVLCLostPictureCount,
      "libVLC lost picture"
    )
    let late = try Self.delta(
      before.libVLCLatePictureCount, after.libVLCLatePictureCount,
      "libVLC late picture"
    )
    let nativeDelta = after.vmemOutputLastValidPTSUS.subtractingReportingOverflow(
      before.vmemOutputLastValidPTSUS
    )
    guard !nativeDelta.overflow else {
      throw CadenceVisualFailure("Native PTS window delta overflowed")
    }
    let profileValue = try Self.profile(after.profile)
    let classification = PiPCadenceProbeDeltaAnalyzer.classify(
      profile: profileValue,
      histogram: histogram,
      deltaOverflowCount: overflow
    )
    let observedFPS = Double(submitted) / exactDuration
    let observedNativeRate =
      Double(nativeDelta.partialValue) / 1_000_000 / exactDuration
    let minimumFPS = try Self.minimumSubmissionFPS(
      profile: after.profile,
      appliedRate: after.effectivePlayerRate,
      windowDuration: exactDuration,
      firstPTSUS: before.vmemOutputLastValidPTSUS,
      lastPTSUS: after.vmemOutputLastValidPTSUS
    )
    guard
      callbackCount > 0,
      callbackCount == Self.histogramCount(histogram),
      Self.equalsSum(callbackCount, submitted, rejected),
      Self.weightedDelta(histogram) == nativeDelta.partialValue,
      nativeDelta.partialValue > 0,
      classification.backwardCount == 0,
      classification.unclassifiedIntervalCount == 0,
      overflow == 0,
      after.effectivePlayerRate > 0,
      abs(observedNativeRate - after.effectivePlayerRate)
      / after.effectivePlayerRate <= 0.15,
      submitted > 0,
      delivered > 0,
      observedFPS + 1e-9 >= minimumFPS,
      decoded > 0,
      displayed > 0
    else {
      throw CadenceVisualFailure("Retained vmem output-attempt window failed semantics")
    }

    profile = after.profile
    requestedRate = after.requestedRate
    startElapsedSeconds = before.elapsedSeconds
    durationSeconds = duration
    windowStartSystemUptime = before.systemUptime
    windowEndSystemUptime = after.systemUptime
    windowDurationSeconds = exactDuration
    appliedRate = after.effectivePlayerRate
    nativePTSDeltaSeconds = Double(nativeDelta.partialValue) / 1_000_000
    nativePTSClassification = classification
    nativePTSDeltaOverflowCount = overflow
    nativePTSDeltaHistogram = histogram
    outputCallbackCount = callbackCount
    submittedFrames = submitted
    swiftRejectedFrames = rejected
    observedSubmissionFPS = observedFPS
    minimumSubmissionFPS = minimumFPS
    libVLCDecodedVideoDelta = decoded
    libVLCDisplayedPictureDelta = displayed
    libVLCLostPictureDelta = lost
    libVLCLatePictureDelta = late
    deliveredFrames = delivered
    droppedFrames = dropped
    backpressureEvents = backpressure
  }

  func rawRecord(visual: VideoSurfaceMotionEvidence) -> [String: Any] {
    [
      "startElapsedSeconds": startElapsedSeconds,
      "durationSeconds": durationSeconds,
      "profile": profile,
      "requestedRate": requestedRate,
      "frameHashes": visual.frameHashes,
      "adjacentChangedPixelRatios": visual.adjacentChangedPixelRatios,
      "changedPixelScore": visual.changedPixelScore
    ]
  }

  func oracleWindow(visual: VideoSurfaceMotionEvidence) -> [String: Any] {
    [
      "profile": profile,
      "requestedRate": requestedRate,
      "startElapsedSeconds": startElapsedSeconds,
      "durationSeconds": durationSeconds,
      "windowStartSystemUptime": windowStartSystemUptime,
      "windowEndSystemUptime": windowEndSystemUptime,
      "windowDurationSeconds": windowDurationSeconds,
      "appliedRate": appliedRate,
      "nativePTSDeltaSeconds": nativePTSDeltaSeconds,
      "nativePTSExactIntervalCount": nativePTSClassification.exactIntervalCount,
      "nativePTSMultipleIntervalCount": nativePTSClassification.multipleIntervalCount,
      "nativePTSEstimatedSkippedPictureCount":
        nativePTSClassification.estimatedSkippedPictureCount,
      "nativePTSRedisplayCount": nativePTSClassification.redisplayCount,
      "nativePTSUnclassifiedIntervalCount":
        nativePTSClassification.unclassifiedIntervalCount,
      "nativePTSBackwardCount": nativePTSClassification.backwardCount,
      "nativePTSDeltaOverflowCount": nativePTSDeltaOverflowCount,
      "nativePTSDeltaHistogram": nativePTSDeltaHistogram.map {
        ["deltaMicroseconds": $0.deltaMicroseconds, "count": $0.count]
      },
      "outputCallbackCount": outputCallbackCount,
      "submittedFrames": submittedFrames,
      "swiftRejectedFrames": swiftRejectedFrames,
      "observedSubmissionFPS": observedSubmissionFPS,
      "minimumSubmissionFPS": minimumSubmissionFPS,
      "libVLCDecodedVideoDelta": libVLCDecodedVideoDelta,
      "libVLCDisplayedPictureDelta": libVLCDisplayedPictureDelta,
      "libVLCLostPictureDelta": libVLCLostPictureDelta,
      "libVLCLatePictureDelta": libVLCLatePictureDelta,
      "deliveredFrames": deliveredFrames,
      "visualMotionScore": visual.changedPixelScore,
      "distinctFrameHashes": Set(visual.frameHashes).count
    ]
  }

  func captureBinding(
    frames: [CadenceTimedFrame],
    startedSystemUptime: TimeInterval
  ) -> [String: Any] {
    [
      "profile": profile,
      "requestedRate": requestedRate,
      "startElapsedSeconds": startElapsedSeconds,
      "durationSeconds": durationSeconds,
      "windowStartSystemUptime": windowStartSystemUptime,
      "windowEndSystemUptime": windowEndSystemUptime,
      "captureSystemUptimes": frames.map(\.systemUptime),
      "captureElapsedSeconds": frames.map {
        $0.systemUptime - startedSystemUptime
      },
      "canonicalRGB8Base64": frames.map {
        Data($0.frame.rgb).base64EncodedString()
      }
    ]
  }

  private static func profile(_ value: String) throws -> PiPCadenceProbeProfile {
    guard let profile = PiPCadenceProbeProfile(rawValue: value) else {
      throw CadenceVisualFailure("Unknown cadence profile \(value)")
    }
    return profile
  }

  private static func histogramDelta(
    _ before: [PiPCadenceProbeDeltaCount],
    _ after: [PiPCadenceProbeDeltaCount]
  )
    throws -> [PiPCadenceProbeDeltaCount] {
    let first = Dictionary(
      uniqueKeysWithValues: before.map { ($0.deltaMicroseconds, $0.count) }
    )
    let last = Dictionary(
      uniqueKeysWithValues: after.map { ($0.deltaMicroseconds, $0.count) }
    )
    return try Set(first.keys).union(last.keys).sorted().compactMap { delta in
      let start = first[delta, default: 0]
      let end = last[delta, default: 0]
      guard end >= start else {
        throw CadenceVisualFailure("Vmem output PTS histogram moved backward")
      }
      return end == start
        ? nil
        : .init(deltaMicroseconds: delta, count: end - start)
    }
  }

  private static func minimumSubmissionFPS(
    profile: String,
    appliedRate: Double,
    windowDuration: Double,
    firstPTSUS: Int64,
    lastPTSUS: Int64
  )
    throws -> Double {
    let expected: Double
    if profile == PiPCadenceProbeProfile.vfr.rawValue {
      let first = Double(firstPTSUS) / 1_000_000
      let last = Double(lastPTSUS) / 1_000_000
      expected =
        (vfrFrameIntegral(last) - vfrFrameIntegral(first))
          / windowDuration
    } else {
      let rates: [String: Double] = [
        "23.976": 24000.0 / 1001.0,
        "24": 24, "25": 25, "29.97": 30000.0 / 1001.0,
        "30": 30, "50": 50, "59.94": 60000.0 / 1001.0, "60": 60
      ]
      guard let sourceRate = rates[profile] else {
        throw CadenceVisualFailure("Unknown CFR cadence profile \(profile)")
      }
      expected = sourceRate * appliedRate
    }
    return 0.90 * min(expected, 60)
  }

  private static func vfrFrameIntegral(_ mediaSeconds: Double) -> Double {
    let cycles = floor(mediaSeconds / 4)
    let remainder = mediaSeconds - cycles * 4
    let lowDuration = min(remainder, 2)
    let highDuration = max(0, remainder - 2)
    return cycles * 2 * (24 + 60) + lowDuration * 24 + highDuration * 60
  }

  private static func histogramCount(
    _ histogram: [PiPCadenceProbeDeltaCount]
  ) -> UInt64 {
    histogram.reduce(UInt64(0)) { partial, entry in
      let result = partial.addingReportingOverflow(entry.count)
      return result.overflow ? .max : result.partialValue
    }
  }

  private static func weightedDelta(
    _ histogram: [PiPCadenceProbeDeltaCount]
  ) -> Int64? {
    var result: Int64 = 0
    for entry in histogram {
      guard entry.count <= UInt64(Int64.max) else { return nil }
      let product = entry.deltaMicroseconds.multipliedReportingOverflow(
        by: Int64(entry.count)
      )
      guard !product.overflow else { return nil }
      let sum = result.addingReportingOverflow(product.partialValue)
      guard !sum.overflow else { return nil }
      result = sum.partialValue
    }
    return result
  }

  private static func delta(
    _ before: UInt64,
    _ after: UInt64,
    _ description: String
  )
    throws -> UInt64 {
    guard after >= before else {
      throw CadenceVisualFailure("\(description) counter moved backward")
    }
    return after - before
  }

  private static func equalsSum(
    _ expected: UInt64,
    _ values: UInt64...
  ) -> Bool {
    var result: UInt64 = 0
    for value in values {
      let sum = result.addingReportingOverflow(value)
      guard !sum.overflow else { return false }
      result = sum.partialValue
    }
    return result == expected
  }
}

private struct CadenceVisualFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
