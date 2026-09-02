import UIKit
import XCTest

struct SystemPictureInPictureWindowRegion: Equatable {
  let normalizedX: Double
  let normalizedY: Double
  let normalizedWidth: Double
  let normalizedHeight: Double

  func normalizedPoint(x: Double, y: Double) -> CGVector {
    CGVector(
      dx: normalizedX + normalizedWidth * x,
      dy: normalizedY + normalizedHeight * y
    )
  }
}

struct SystemPictureInPicturePixelSummary: Codable, Equatable {
  let sampledPixels: Int
  let brightPixelRatio: Double
  let saturatedPixelRatio: Double
  let yellowPixelRatio: Double
  let greenPixelRatio: Double
  let nonGrayPixelRatio: Double
  let meanRed: Double
  let meanGreen: Double
  let meanBlue: Double
}

private struct SystemPictureInPictureInspectionFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

enum ShowcaseScrollDirection {
  case up
  case down

  var opposite: Self {
    switch self {
    case .up: .down
    case .down: .up
    }
  }

  @MainActor
  func perform(in app: XCUIApplication) {
    switch self {
    case .up: app.swipeUp()
    case .down: app.swipeDown()
    }
  }
}

/// Base class for every iOS showcase UI test.
///
/// Owns the `XCUIApplication` instance, configures the launch-arg contract
/// (fixture URL, log path, test mode), provides launch helpers, and parses
/// the library log file on teardown.
///
/// `@MainActor` matches the isolation of `XCUIApplication`, `XCUIElement`,
/// and `XCUIDevice` under Swift 6 strict concurrency. Subclasses inherit
/// the isolation, so test methods can call XCUI APIs directly.
@MainActor
class ShowcaseIOSTestCase: XCTestCase {
  private static let attachToRunningAppEnvironment = "SWIFTVLC_ATTACH_TO_RUNNING_APP"
  private static let deviceFixtureEnvironment = "SWIFTVLC_DEVICE_FIXTURE_URL_BASE64"
  private static let deviceLogPrefixEnvironment = "SWIFTVLC_DEVICE_LOG_PREFIX"

  private(set) var app: XCUIApplication!
  private(set) var logURL: URL!

  /// HTTP fixture staged by the physical-device runner. Simulator tests use
  /// bundle files, but those runner-bundle paths do not exist inside an app on
  /// a separate physical device.
  var physicalDeviceFixtureURL: URL? {
    ProcessInfo.processInfo.environment[Self.deviceFixtureEnvironment]
      .flatMap { Data(base64Encoded: $0) }
      .flatMap { String(data: $0, encoding: .utf8) }
      .flatMap(URL.init(string:))
  }

  override func setUp() async throws {
    try await super.setUp()
    continueAfterFailure = false

    app = XCUIApplication()

    // One log file per test, in the simulator's tmp dir. Both processes
    // (test runner and app) share the simulator filesystem, so an absolute
    // path here is reachable from both sides.
    let safeName = name
      .replacingOccurrences(of: " ", with: "_")
      .replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
      .replacingOccurrences(of: "-", with: "")
    let logName = "\(safeName)-\(UUID().uuidString).jsonl"
    let deviceLogPrefix = ProcessInfo.processInfo.environment[Self.deviceLogPrefixEnvironment]
    let logArgument: String
    if let deviceLogPrefix {
      logArgument = "\(deviceLogPrefix)-\(logName)"
      logURL = URL(fileURLWithPath: logArgument)
    } else {
      logURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("uitest-\(logName)")
      logArgument = logURL.path
    }

    let fixtureURL = Self.fixtureURL()
    let fixtureArgument = physicalDeviceFixtureURL?.absoluteString ?? fixtureURL.path
    let encodedFixtureArgument = Data(fixtureArgument.utf8).base64EncodedString()
    app.launchEnvironment[LaunchArguments.fixtureURLEnvironment] = encodedFixtureArgument

    app.launchArguments += [
      LaunchArguments.uiTestMode, "YES",
      LaunchArguments.fixtureURLBase64, encodedFixtureArgument,
      LaunchArguments.logPath, logArgument
    ]
  }

  override func tearDown() async throws {
    if let logURL, FileManager.default.fileExists(atPath: logURL.path) {
      let attachment = XCTAttachment(contentsOfFile: logURL)
      attachment.name = "library-log.jsonl"
      attachment.lifetime = .keepAlways
      add(attachment)
    }

    app?.terminate()
    try await super.tearDown()
  }

  // MARK: - Launch

  /// Launches the app deep-linked to a case study, skipping the root
  /// navigation tree.
  func launch(route: UITestRoute) {
    app.launchArguments += [LaunchArguments.route, route.rawValue]
    launchOrAttach()
  }

  /// Launches the app at the normal `RootView`. Use this for tests that
  /// exercise navigation itself.
  func launchAtRoot() {
    launchOrAttach()
  }

  /// Physical-device qualification can prelaunch the exact signed candidate
  /// with `devicectl`, then attach the separately built UI-test runner. This
  /// avoids replacing the candidate and preserves its deterministic fixture
  /// and evidence-log launch arguments.
  private func launchOrAttach() {
    if ProcessInfo.processInfo.environment[Self.attachToRunningAppEnvironment] == "YES" {
      app.activate()
    } else {
      app.launch()
    }
  }

  // MARK: - Log assertions

  /// Reads the current log file and returns the parsed entries.
  func readLogEntries() -> [UITestLogEntry] {
    // Physical-device logs live inside the application container and are
    // pulled by the host after XCTest finishes. The runner cannot read that
    // relative app-container path directly; host policy validates the same
    // health record before accepting the attempt.
    if ProcessInfo.processInfo.environment[Self.deviceLogPrefixEnvironment] != nil {
      return []
    }

    guard
      let logURL,
      let data = try? Data(contentsOf: logURL),
      let text = String(data: data, encoding: .utf8)
    else {
      XCTFail("The library log mirror is missing or unreadable")
      return []
    }

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let lines = text.split(whereSeparator: \.isNewline)
    guard !lines.isEmpty else {
      XCTFail("The library log mirror is empty")
      return []
    }

    var entries: [UITestLogEntry] = []
    for (offset, line) in lines.enumerated() {
      guard let lineData = line.data(using: .utf8) else {
        XCTFail("The library log mirror contains invalid UTF-8 at line \(offset + 1)")
        return []
      }
      do {
        try entries.append(decoder.decode(UITestLogEntry.self, from: lineData))
      } catch {
        XCTFail("The library log mirror is malformed at line \(offset + 1): \(error)")
        return []
      }
    }

    guard
      entries.contains(where: {
        $0.level == "debug"
          && $0.module == "swiftvlc.qualification.log-mirror"
          && $0.message == "mirror-start/v1"
      }) else {
      XCTFail("The library log mirror has no startup health record")
      return []
    }
    return entries
  }

  /// Fails the test if the library emitted any `error`-level entries during
  /// the scenario. Call once near the end of each test method.
  func assertNoLibraryErrors(file: StaticString = #filePath, line: UInt = #line) {
    let errors = readLogEntries().filter { $0.level == "error" }
    if !errors.isEmpty {
      let summary = errors
        .prefix(5)
        .map { "  [\($0.module ?? "?")] \($0.message)" }
        .joined(separator: "\n")
      XCTFail(
        "Library emitted \(errors.count) error(s):\n\(summary)",
        file: file,
        line: line
      )
    }
  }

  /// Adds a machine-readable payload that the physical-device runner turns
  /// into candidate-bound qualification evidence. Identity fields are added
  /// by the host after exporting the xcresult attachment; a test process must
  /// never guess which source tree or signed app bundle launched it.
  func attachQualificationEvidence(
    _ suppliedPayload: [String: Any],
    scenario: String,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    if
      let embeddedScenario = suppliedPayload["scenario"],
      embeddedScenario as? String != scenario {
      XCTFail(
        "Qualification evidence scenario does not match \(scenario)",
        file: file,
        line: line
      )
      return
    }
    var payload = suppliedPayload
    payload["formatVersion"] = payload["formatVersion"] ?? 1
    payload["scenario"] = scenario
    guard JSONSerialization.isValidJSONObject(payload) else {
      XCTFail("Qualification evidence is not valid JSON", file: file, line: line)
      return
    }
    do {
      let data = try JSONSerialization.data(
        withJSONObject: payload,
        options: [.prettyPrinted, .sortedKeys]
      )
      let attachment = XCTAttachment(
        data: data,
        uniformTypeIdentifier: "public.json"
      )
      attachment.name = "qualification-\(scenario).json"
      attachment.lifetime = .keepAlways
      add(attachment)
    } catch {
      XCTFail(
        "Could not encode qualification evidence: \(error)",
        file: file,
        line: line
      )
    }
  }

  // MARK: - Wait helpers

  /// Spins until `element.label == expected`, or fails after `timeout`.
  func waitForLabel(
    _ element: XCUIElement,
    equals expected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in element.label == expected }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected label '\(expected)' but found '\(element.label)' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  /// Spins until `element.label != unexpected`, or fails after `timeout`.
  func waitForLabel(
    _ element: XCUIElement,
    notEqual unexpected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in element.label != unexpected }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Label still '\(unexpected)' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  /// Spins until an accessibility label parses as an integer above the
  /// supplied lower bound, then returns the observed value.
  @discardableResult
  func waitForIntegerLabel(
    _ element: XCUIElement,
    greaterThan lowerBound: Int,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Int {
    let predicate = NSPredicate { _, _ in
      Int(element.label).map { $0 > lowerBound } == true
    }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected an integer label above \(lowerBound), but found '\(element.label)' after \(timeout)s",
        file: file,
        line: line
      )
    }
    return Int(element.label) ?? Int.min
  }

  /// Returns the exact machine value published by a validation element.
  /// Human-readable row titles intentionally remain in `label`.
  func accessibilityValue(of element: XCUIElement) -> String {
    element.value as? String ?? ""
  }

  /// Spins until an accessibility element publishes the expected machine
  /// value. Requiring `exists` prevents an unmounted lazy Form row from
  /// accidentally satisfying an empty or default comparison.
  func waitForAccessibilityValue(
    _ element: XCUIElement,
    equals expected: String,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let predicate = NSPredicate { _, _ in
      element.exists && self.accessibilityValue(of: element) == expected
    }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected accessibility value '\(expected)' for '\(element.label)', "
          + "but found '\(accessibilityValue(of: element))' after \(timeout)s",
        file: file,
        line: line
      )
    }
  }

  /// Spins until an accessibility value parses as an integer above the
  /// supplied lower bound, then returns the observed value.
  @discardableResult
  func waitForIntegerAccessibilityValue(
    _ element: XCUIElement,
    greaterThan lowerBound: Int,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) -> Int {
    let predicate = NSPredicate { _, _ in
      element.exists
        && Int(self.accessibilityValue(of: element)).map { $0 > lowerBound } == true
    }
    let exp = expectation(for: predicate, evaluatedWith: NSObject())
    if XCTWaiter.wait(for: [exp], timeout: timeout) != .completed {
      XCTFail(
        "Expected an integer accessibility value above \(lowerBound) for "
          + "'\(element.label)', but found '\(accessibilityValue(of: element))' "
          + "after \(timeout)s",
        file: file,
        line: line
      )
    }
    return Int(accessibilityValue(of: element)) ?? Int.min
  }

  /// Mounts a lazily created SwiftUI Form row before a test reads its exact
  /// accessibility value. The caller supplies the likely direction for a
  /// short path; if the layout or device size differs, a bounded reverse scan
  /// searches the full form instead of turning viewport placement into a
  /// product failure.
  func revealMeasurement(
    _ element: XCUIElement,
    swiping initialDirection: ShowcaseScrollDirection,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    for _ in 0..<10 where !element.exists {
      initialDirection.perform(in: app)
    }
    if !element.exists {
      for _ in 0..<20 where !element.exists {
        initialDirection.opposite.perform(in: app)
      }
    }
    XCTAssertTrue(
      element.exists,
      "Could not mount validation measurement \(element)",
      file: file,
      line: line
    )
  }

  /// Waits until the element's visible screen region contains real video
  /// pixels instead of the all-black drawable placeholder.
  func assertRendersNonBlackFrame(
    _ element: XCUIElement,
    timeout: TimeInterval,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    let deadline = Date().addingTimeInterval(timeout)
    var lastNonBlackRatio = 0.0
    var lastScreenScreenshot: XCUIScreenshot?
    var lastVideoRegion: UIImage?

    while Date() < deadline {
      guard element.exists else {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        continue
      }

      let screenScreenshot = XCUIScreen.main.screenshot()
      guard let videoRegion = croppedImage(screenScreenshot.image, to: element.frame) else {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        continue
      }

      lastScreenScreenshot = screenScreenshot
      lastVideoRegion = videoRegion
      lastNonBlackRatio = nonBlackSampleRatio(in: videoRegion)
      if lastNonBlackRatio >= 0.2 {
        return
      }

      RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    if let lastVideoRegion {
      let attachment = XCTAttachment(image: lastVideoRegion)
      attachment.name = "black-video-region"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    if let lastScreenScreenshot {
      let attachment = XCTAttachment(screenshot: lastScreenScreenshot)
      attachment.name = "black-video-full-screen"
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    XCTFail(
      "Expected video pixels, but sampled only \(Int(lastNonBlackRatio * 100))% non-black pixels after \(timeout)s",
      file: file,
      line: line
    )
  }

  /// Samples the display after backgrounding and finds one stable, contiguous
  /// PiP-sized motion component. The same bounded region must contain
  /// sustained motion and non-black pixels; whole-screen animation, clocks,
  /// widgets, spinners, scattered changes, and position drift are rejected.
  func assertSystemPictureInPictureRendersMotion(
    samples: Int = 6,
    interval: TimeInterval = 0.75,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    if let failure = captureSystemPictureInPictureMotion(samples: samples, interval: interval) {
      XCTFail(failure, file: file, line: line)
    }
  }

  /// Captures and analyzes system PiP without immediately failing the test.
  /// Device lanes use this form when they must foreground the app and attach
  /// renderer telemetry before reporting the visual failure.
  func captureSystemPictureInPictureMotion(
    samples: Int = 6,
    interval: TimeInterval = 0.75
  ) -> String? {
    inspectSystemPictureInPictureMotion(
      samples: samples,
      interval: interval,
      retainDiagnostics: true
    ).failure
  }

  /// Returns the stable system-PiP bounds proven by the same moving-pixel
  /// oracle used for visual qualification. Coordinates are normalized to the
  /// full screen so UI tests can exercise the real restore and close controls
  /// without depending on localized SpringBoard accessibility labels.
  func locateSystemPictureInPictureWindow(
    samples: Int = 6,
    interval: TimeInterval = 0.75,
    retainDiagnostics: Bool = true
  )
    throws -> SystemPictureInPictureWindowRegion {
    let inspection = inspectSystemPictureInPictureMotion(
      samples: samples,
      interval: interval,
      retainDiagnostics: retainDiagnostics
    )
    if let failure = inspection.failure {
      throw SystemPictureInPictureInspectionFailure(failure)
    }
    guard let region = inspection.region else {
      throw SystemPictureInPictureInspectionFailure("System PiP bounds were not detected")
    }
    return region
  }

  /// Captures the detected system PiP window and reduces its pixels to stable,
  /// numeric overlay/color evidence. Qualification tests compare these values
  /// against the grayscale no-overlay phase instead of relying on a person to
  /// inspect screenshots.
  func captureSystemPictureInPicturePixelSummary(
    in region: SystemPictureInPictureWindowRegion,
    attachmentName: String
  )
    throws -> SystemPictureInPicturePixelSummary {
    let screenshot = XCUIScreen.main.screenshot()
    guard let crop = croppedSystemPictureInPictureRegion(screenshot.image, region: region) else {
      throw SystemPictureInPictureInspectionFailure("Could not crop the system PiP window")
    }
    let attachment = XCTAttachment(image: crop)
    attachment.name = attachmentName
    attachment.lifetime = .keepAlways
    add(attachment)
    guard let summary = pictureInPicturePixelSummary(crop) else {
      throw SystemPictureInPictureInspectionFailure("Could not rasterize the system PiP window")
    }
    return summary
  }

  /// Captures one already-located system PiP surface repeatedly and emits the
  /// canonical hashes plus every adjacent changed-pixel ratio. The detected
  /// region is fixed for the whole window: moving UI outside PiP cannot count
  /// as video motion, and a freeze after one transition drives the minimum
  /// score to zero.
  func captureSystemPictureInPictureVisualEvidence(
    in region: SystemPictureInPictureWindowRegion,
    samples: Int = 3,
    interval: TimeInterval = 0.25,
    attachmentName: String? = nil
  )
    throws -> VideoSurfaceMotionEvidence {
    try captureVideoSurfaceVisualEvidence(
      samples: samples,
      interval: interval,
      attachmentName: attachmentName
    ) {
      croppedSystemPictureInPictureRegion(
        XCUIScreen.main.screenshot().image,
        region: region
      )
    }
  }

  /// Captures one canonical frame from an already-located PiP surface. Cadence
  /// qualification timestamps these frames against system uptime, then binds
  /// only frames that fall strictly inside the app's retained sample windows.
  func captureSystemPictureInPictureCanonicalFrame(
    in region: SystemPictureInPictureWindowRegion
  )
    throws -> VideoSurfaceCanonicalFrame {
    guard
      let image = croppedSystemPictureInPictureRegion(
        XCUIScreen.main.screenshot().image,
        region: region
      ),
      let frame = makeCanonicalVideoSurfaceFrame(from: image)
    else {
      throw SystemPictureInPictureInspectionFailure(
        "Could not crop or rasterize the cadence PiP frame"
      )
    }
    return frame
  }

  /// Captures an inline app-owned video element using the same canonical
  /// surface oracle as system PiP qualification.
  func captureInlineVideoSurfaceVisualEvidence(
    _ element: XCUIElement,
    samples: Int = 3,
    interval: TimeInterval = 0.25,
    attachmentName: String? = nil
  )
    throws -> VideoSurfaceMotionEvidence {
    guard element.exists else {
      throw SystemPictureInPictureInspectionFailure("Inline video element does not exist")
    }
    return try captureVideoSurfaceVisualEvidence(
      samples: samples,
      interval: interval,
      attachmentName: attachmentName
    ) {
      croppedImage(XCUIScreen.main.screenshot().image, to: element.frame)
    }
  }

  /// Captures one raw canonical inline frame. Qualification lanes that retain
  /// replayable RGB bytes use this instead of trusting precomputed hashes.
  func captureInlineVideoSurfaceCanonicalFrame(
    _ element: XCUIElement
  )
    throws -> VideoSurfaceCanonicalFrame {
    guard
      element.exists,
      let image = croppedImage(XCUIScreen.main.screenshot().image, to: element.frame),
      let frame = makeCanonicalVideoSurfaceFrame(from: image)
    else {
      throw SystemPictureInPictureInspectionFailure(
        "Could not crop or rasterize the inline video frame"
      )
    }
    return frame
  }

  private func captureVideoSurfaceVisualEvidence(
    samples: Int,
    interval: TimeInterval,
    attachmentName: String?,
    capture: () -> UIImage?
  )
    throws -> VideoSurfaceMotionEvidence {
    guard samples >= 3 else {
      throw SystemPictureInPictureInspectionFailure(
        "Visual evidence requires at least three adjacent captures"
      )
    }
    var frames: [VideoSurfaceCanonicalFrame] = []
    var boundaryImages: [UIImage] = []
    for index in 0..<samples {
      guard
        let image = capture(),
        let frame = makeCanonicalVideoSurfaceFrame(from: image)
      else {
        throw SystemPictureInPictureInspectionFailure(
          "Could not crop or rasterize visual-evidence frame \(index)"
        )
      }
      frames.append(frame)
      if index == 0 || index == samples - 1 {
        boundaryImages.append(image)
      }
      if index < samples - 1 {
        RunLoop.current.run(until: Date().addingTimeInterval(interval))
      }
    }
    if let attachmentName {
      for (suffix, image) in zip(["start", "end"], boundaryImages) {
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(attachmentName)-\(suffix)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }
    guard let evidence = VideoSurfaceMotionEvidenceAnalyzer.analyze(frames) else {
      throw SystemPictureInPictureInspectionFailure(
        "Could not analyze canonical visual-evidence frames"
      )
    }
    return evidence
  }

  private func inspectSystemPictureInPictureMotion(
    samples: Int,
    interval: TimeInterval,
    retainDiagnostics: Bool
  ) -> (region: SystemPictureInPictureWindowRegion?, failure: String?) {
    precondition(samples >= 5)

    let settledSurface = waitForStableSystemPictureInPictureSurface()
    let stabilityRatios = settledSurface.changedPixelRatios
      .map { String(format: "%.4f", $0) }
      .joined(separator: ",")
    if retainDiagnostics {
      let stabilityAttachment = XCTAttachment(
        string: "wholeScreenChangedRatios=[\(stabilityRatios)]\n"
          + "requiredConsecutiveStablePairs=2\nmaximumChangedRatio=0.1200"
      )
      stabilityAttachment.name = "system-pip-surface-stability"
      stabilityAttachment.lifetime = .keepAlways
      add(stabilityAttachment)
    }

    guard let settledScreenshot = settledSurface.screenshot else {
      return (
        nil,
        "SpringBoard did not settle before PiP sampling. "
          + "whole-screen changed ratios: [\(stabilityRatios)]"
      )
    }

    var screenshots = [settledScreenshot]

    for _ in 1..<samples {
      RunLoop.current.run(until: Date().addingTimeInterval(interval))
      screenshots.append(XCUIScreen.main.screenshot())
    }

    if retainDiagnostics {
      for (index, screenshot) in screenshots.enumerated()
        where index == 0 || index == screenshots.count - 1 {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = index == 0 ? "system-pip-motion-start" : "system-pip-motion-end"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }

    let frames = screenshots.compactMap { makePiPMotionFrame(from: $0.image) }
    guard frames.count == screenshots.count else {
      if retainDiagnostics {
        let attachment = XCTAttachment(
          string: "Could rasterize only \(frames.count) of \(screenshots.count) screenshots."
        )
        attachment.name = "system-pip-motion-diagnostics"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
      return (nil, "Could not rasterize system PiP screenshots")
    }

    let analysis = PiPMotionRegionAnalyzer().analyze(frames)
    let diagnostics = systemPiPMotionDiagnostics(analysis)
    if retainDiagnostics {
      let diagnosticAttachment = XCTAttachment(string: diagnostics)
      diagnosticAttachment.name = "system-pip-motion-diagnostics"
      diagnosticAttachment.lifetime = .keepAlways
      add(diagnosticAttachment)
    }

    if
      retainDiagnostics,
      let region = analysis.region,
      let first = screenshots.first,
      let last = screenshots.last {
      for (name, screenshot) in [("start", first), ("end", last)] {
        guard
          let crop = croppedPiPMotionRegion(
            screenshot.image,
            region: region,
            frameWidth: analysis.frameWidth,
            frameHeight: analysis.frameHeight
          )
        else { continue }
        let attachment = XCTAttachment(image: crop)
        attachment.name = "system-pip-detected-region-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
      }
    }

    let normalizedRegion = analysis.region.map {
      SystemPictureInPictureWindowRegion(
        normalizedX: Double($0.x) / Double(analysis.frameWidth),
        normalizedY: Double($0.y) / Double(analysis.frameHeight),
        normalizedWidth: Double($0.width) / Double(analysis.frameWidth),
        normalizedHeight: Double($0.height) / Double(analysis.frameHeight)
      )
    }
    guard let failure = analysis.failure else { return (normalizedRegion, nil) }
    return (
      normalizedRegion,
      "System PiP image oracle failed: \(failure.rawValue). \(diagnostics)"
    )
  }

  /// Waits for two consecutive low-delta screen transitions so sampling
  /// cannot mistake the app-switcher/home animation for PiP motion. A moving
  /// PiP occupies only a bounded part of the screen and remains below this
  /// whole-screen threshold; an unsettled system surface fails closed.
  private func waitForStableSystemPictureInPictureSurface(
    timeout: TimeInterval = 3,
    sampleInterval: TimeInterval = 0.2
  ) -> (screenshot: XCUIScreenshot?, changedPixelRatios: [Double]) {
    let detector = PiPSystemSurfaceStabilityDetector()
    let deadline = Date().addingTimeInterval(timeout)
    let initialScreenshot = XCUIScreen.main.screenshot()
    guard var previousFrame = makePiPMotionFrame(from: initialScreenshot.image) else {
      return (nil, [])
    }
    var changedPixelRatios: [Double] = []
    var consecutiveStablePairs = 0

    while Date() < deadline {
      RunLoop.current.run(until: Date().addingTimeInterval(sampleInterval))
      let currentScreenshot = XCUIScreen.main.screenshot()
      guard let currentFrame = makePiPMotionFrame(from: currentScreenshot.image) else {
        return (nil, changedPixelRatios)
      }
      guard
        let changedRatio = detector.changedPixelRatio(
          from: previousFrame,
          to: currentFrame
        ) else {
        return (nil, changedPixelRatios)
      }
      changedPixelRatios.append(changedRatio)
      if detector.isStableTransition(from: previousFrame, to: currentFrame) {
        consecutiveStablePairs += 1
        if consecutiveStablePairs >= 2 {
          return (currentScreenshot, changedPixelRatios)
        }
      } else {
        consecutiveStablePairs = 0
      }
      previousFrame = currentFrame
    }

    return (nil, changedPixelRatios)
  }

  // MARK: - Fixtures

  /// The happy-path fixture: a 10s h264 + aac mp4. Short enough to keep
  /// tests fast, long enough for pause-then-verify-stalled deep tests.
  /// Generated once via ffmpeg and committed under `Fixtures/`.
  private static func fixtureURL() -> URL {
    resource(named: "test", extension: "mp4")
  }

  /// Resolves a resource bundled in the UI test target.
  /// Synced folder groups preserve the `Fixtures/` subdirectory in the
  /// bundle, so look there first; fall back to the bundle root for safety.
  private static func resource(named name: String, extension ext: String) -> URL {
    let bundle = Bundle(for: ShowcaseIOSTestCase.self)
    if let url = bundle.url(forResource: name, withExtension: ext, subdirectory: "Fixtures") {
      return url
    }
    if let url = bundle.url(forResource: name, withExtension: ext) {
      return url
    }
    fatalError("\(name).\(ext) not found in UI test bundle")
  }
}

private func nonBlackSampleRatio(in image: UIImage) -> Double {
  guard let cgImage = image.cgImage else { return 0 }

  let width = cgImage.width
  let height = cgImage.height
  guard width > 0, height > 0 else { return 0 }

  let bytesPerPixel = 4
  let bytesPerRow = width * bytesPerPixel
  var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
  guard
    let context = CGContext(
      data: &pixels,
      width: width,
      height: height,
      bitsPerComponent: 8,
      bytesPerRow: bytesPerRow,
      space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
  else { return 0 }

  context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

  let xRange = stride(from: 0.2, through: 0.8, by: 0.1)
  let yRange = stride(from: 0.2, through: 0.8, by: 0.1)
  var sampled = 0
  var nonBlack = 0

  for yFraction in yRange {
    for xFraction in xRange {
      let x = min(width - 1, max(0, Int(Double(width) * xFraction)))
      let y = min(height - 1, max(0, Int(Double(height) * yFraction)))
      let offset = y * bytesPerRow + x * bytesPerPixel
      let red = pixels[offset]
      let green = pixels[offset + 1]
      let blue = pixels[offset + 2]
      sampled += 1
      if max(red, green, blue) > 40 {
        nonBlack += 1
      }
    }
  }

  return sampled == 0 ? 0 : Double(nonBlack) / Double(sampled)
}

private func croppedImage(_ image: UIImage, to frame: CGRect) -> UIImage? {
  guard let cgImage = image.cgImage else { return nil }

  let imageBounds = CGRect(origin: .zero, size: image.size)
  let pointRect = frame.intersection(imageBounds)
  guard pointRect.width > 0, pointRect.height > 0 else { return nil }

  let scaleX = CGFloat(cgImage.width) / image.size.width
  let scaleY = CGFloat(cgImage.height) / image.size.height
  let pixelRect = CGRect(
    x: pointRect.minX * scaleX,
    y: pointRect.minY * scaleY,
    width: pointRect.width * scaleX,
    height: pointRect.height * scaleY
  ).integral

  guard let cropped = cgImage.cropping(to: pixelRect) else { return nil }
  return UIImage(cgImage: cropped, scale: image.scale, orientation: image.imageOrientation)
}
