import XCTest

/// Operator-assisted, candidate-bound proof of an actual iOS media-services
/// reset. Native broker epochs make this impossible to satisfy with a posted
/// NotificationCenter notification or a relabelled interruption.
final class MediaServicesResetDeviceUITests: ShowcaseIOSTestCase {
  private static let resetURLEnvironment =
    "SWIFTVLC_AUDIO_MEDIA_SERVICES_RESET_URL_BASE64"

  func test_realMediaServicesResetQuarantinesAndRebuildsBothAppleOutputs() throws {
    #if targetEnvironment(simulator)
    throw XCTSkip("Media-services reset qualification requires a physical iPhone")
    #else
    guard
      ProcessInfo.processInfo.environment[
        "SWIFTVLC_AUDIO_MEDIA_SERVICES_RESET_DEVICE"
      ] == "YES",
      let encodedResetURL = ProcessInfo.processInfo.environment[
        Self.resetURLEnvironment
      ],
      let resetURLData = Data(base64Encoded: encodedResetURL),
      let resetURLString = String(data: resetURLData, encoding: .utf8),
      let resetURL = URL(string: resetURLString),
      let resetAttemptToken = adaptiveAttemptToken(from: resetURL)
    else {
      throw XCTSkip(
        "Enable the operator-assisted reset lane with its per-attempt HLS URL"
      )
    }

    addUIInterruptionMonitor(withDescription: "Local network permission") { alert in
      let allow = alert.buttons["Allow"]
      guard allow.exists else { return false }
      allow.tap()
      return true
    }
    replaceLaunchArgument(
      LaunchArguments.audioMediaServicesResetURLBase64,
      with: encodedResetURL
    )
    launch(route: .mediaServicesResetValidation)
    app.tap()
    let phase = element(AccessibilityID.MediaServicesResetValidation.phaseLabel)
    let startPictureInPicture = app.buttons[
      AccessibilityID.MediaServicesResetValidation.startPictureInPictureButton
    ]
    let arm = app.buttons[AccessibilityID.MediaServicesResetValidation.armButton]
    let resume = app.buttons[AccessibilityID.MediaServicesResetValidation.resumeButton]
    let result = element(AccessibilityID.MediaServicesResetValidation.resultLabel)
    let error = element(AccessibilityID.MediaServicesResetValidation.errorLabel)

    waitForLabel(phase, equals: "ready-for-pip", timeout: 60)
    reveal(startPictureInPicture)
    startPictureInPicture.tap()
    waitForLabel(phase, equals: "ready-to-arm", timeout: 20)
    reveal(arm)
    arm.tap()
    waitForLabel(phase, equals: "awaiting-system-reset", timeout: 10)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("Native PiP was not moving before media-services reset: \(failure)")
    }
    XCTAssertEqual(
      phase.label,
      "awaiting-system-reset",
      "Playback stopped before the operator reset was requested"
    )

    let readinessMarker =
      "SWIFTVLC_AUDIO_RESET_READY_FOR_OPERATOR:\(resetAttemptToken)"
    try FileHandle.standardError.write(
      contentsOf: Data("\n\(readinessMarker)\n".utf8)
    )
    let instruction =
      "ACTION REQUIRED: on the connected iPhone open Settings > Developer, "
        + "run Reset Media Services, then return to the SwiftVLC showcase app."
    print("\n\n*** \(instruction) ***\n\n")
    let instructionAttachment = XCTAttachment(string: instruction)
    instructionAttachment.name = "operator-media-services-reset-instructions.txt"
    instructionAttachment.lifetime = .keepAlways
    add(instructionAttachment)

    let resetOutcome = XCTNSPredicateExpectation(
      predicate: NSPredicate { _, _ in
        !self.app.exists
          || ["reset-quarantined", "failed", "cancelled"].contains(phase.label)
      },
      object: phase
    )
    XCTAssertEqual(
      XCTWaiter.wait(for: [resetOutcome], timeout: 600),
      .completed,
      "Timed out while waiting for the operator media-services reset"
    )
    guard phase.label == "reset-quarantined" else {
      XCTFail(
        "Reset observation terminated as \(phase.label): "
          + (error.exists ? error.label : "the candidate app terminated")
      )
      return
    }
    app.activate()
    reveal(resume)
    resume.tap()
    waitForLabel(phase, equals: "complete", timeout: 60)
    XCTAssertFalse(error.exists, "Reset surface failed: \(error.label)")
    let raw: MediaServicesResetQualificationRawResult = try decodeResult(result.label)
    try validate(raw)

    XCUIDevice.shared.press(.home)
    if let failure = captureSystemPictureInPictureMotion() {
      XCTFail("Native PiP did not move after media-services recovery: \(failure)")
    }
    app.activate()
    assertNoLibraryErrors()
    var payload = try jsonObject(raw)
    payload["resetEpochProof"] = "pass"
    payload["preIntentQuarantine"] = "pass"
    payload["explicitResumeRecovery"] = "pass"
    payload["forcedOutputModules"] = ["audiounit_ios", "avsamplebuffer"]
    payload["systemPiPMotionBeforeReset"] = "pass"
    payload["systemPiPMotionAfterRecovery"] = "pass"
    payload["libraryErrorCount"] = 0
    attachQualificationEvidence(payload, scenario: "audio-media-services-reset")
    #endif
  }

  private func validate(_ raw: MediaServicesResetQualificationRawResult) throws {
    XCTAssertEqual(raw.formatVersion, 1)
    XCTAssertEqual(raw.trigger, "settings-developer-media-services-reset-v1")
    XCTAssertFalse(raw.syntheticNotificationsPosted)
    XCTAssertGreaterThanOrEqual(raw.mediaServicesLostNotificationCount, 0)
    XCTAssertGreaterThanOrEqual(raw.mediaServicesResetNotificationCount, 1)
    XCTAssertEqual(
      raw.mediaServicesNotificationSequence.count { $0.kind == "lost" },
      raw.mediaServicesLostNotificationCount
    )
    XCTAssertEqual(
      raw.mediaServicesNotificationSequence.count { $0.kind == "reset" },
      raw.mediaServicesResetNotificationCount
    )
    XCTAssertFalse(raw.mediaServicesNotificationSequence.isEmpty)
    XCTAssertTrue(
      zip(
        raw.mediaServicesNotificationSequence,
        raw.mediaServicesNotificationSequence.dropFirst()
      ).allSatisfy { $0.systemUptime <= $1.systemUptime }
    )
    if
      let firstReset = raw.mediaServicesNotificationSequence.firstIndex(
        where: { $0.kind == "reset" }
      ) {
      XCTAssertFalse(
        raw.mediaServicesNotificationSequence[firstReset...].contains {
          $0.kind == "lost"
        }
      )
    } else {
      XCTFail("Media-services reset notification was not retained")
    }
    XCTAssertGreaterThanOrEqual(raw.quarantineObservationMilliseconds, 3000)
    XCTAssertTrue(raw.pictureInPictureActiveBeforeReset)
    XCTAssertTrue(raw.pictureInPictureActiveAfterRecovery)
    XCTAssertEqual(Set(raw.players.map(\.role)), ["audio-only", "native-pip-video"])
    XCTAssertEqual(
      Set(raw.players.map(\.forcedAudioOutputModule)),
      ["audiounit_ios", "avsamplebuffer"]
    )
    let firstNotification = try XCTUnwrap(
      raw.mediaServicesNotificationSequence.first
    )

    for player in raw.players {
      let readinessStart = player.readinessStart
      let baseline = player.baseline
      let quarantineStart = player.quarantineStart
      let quarantineEnd = player.quarantineEnd
      let recovered = player.recovered
      XCTAssertEqual(readinessStart.playerState, "playing")
      XCTAssertTrue(readinessStart.playbackRequestedActive)
      XCTAssertEqual(readinessStart.native.brokerPhase, "ready")
      XCTAssertEqual(baseline.playerState, "playing")
      XCTAssertTrue(baseline.playbackRequestedActive)
      XCTAssertEqual(baseline.native.brokerPhase, "ready")
      XCTAssertGreaterThan(baseline.native.brokerEpoch, 0)
      XCTAssertGreaterThan(baseline.native.liveOutputCount, 0)
      XCTAssertGreaterThan(baseline.playback.playedAudioBuffers, 0)
      let readinessMilliseconds = Int64(
        ((baseline.systemUptime - readinessStart.systemUptime) * 1000)
          .rounded(.down)
      )
      XCTAssertGreaterThanOrEqual(readinessMilliseconds, 500)
      XCTAssertLessThanOrEqual(readinessMilliseconds, 2500)
      XCTAssertGreaterThanOrEqual(
        firstNotification.systemUptime,
        baseline.systemUptime
      )
      XCTAssertLessThanOrEqual(
        Int64(
          ((firstNotification.systemUptime - baseline.systemUptime) * 1000)
            .rounded(.up)
        ),
        2500
      )
      XCTAssertEqual(readinessStart.native.brokerEpoch, baseline.native.brokerEpoch)
      XCTAssertEqual(
        readinessStart.native.brokerResetEpoch,
        baseline.native.brokerResetEpoch
      )
      XCTAssertEqual(
        readinessStart.native.commandGeneration,
        baseline.native.commandGeneration
      )
      XCTAssertEqual(
        readinessStart.native.outputIncarnationCount,
        baseline.native.outputIncarnationCount
      )
      XCTAssertEqual(
        readinessStart.native.brokerActiveOwnerCount,
        baseline.native.brokerActiveOwnerCount
      )
      XCTAssertEqual(
        readinessStart.native.brokerLiveLeaseCount,
        baseline.native.brokerLiveLeaseCount
      )
      XCTAssertGreaterThan(
        baseline.playback.mediaTimeMilliseconds,
        readinessStart.playback.mediaTimeMilliseconds
      )
      XCTAssertGreaterThan(
        baseline.playback.playedAudioBuffers,
        readinessStart.playback.playedAudioBuffers
      )
      if player.role == "native-pip-video" {
        XCTAssertGreaterThan(
          baseline.playback.displayedPictures,
          readinessStart.playback.displayedPictures
        )
      }

      XCTAssertEqual(quarantineStart.playerState, "paused")
      XCTAssertEqual(quarantineEnd.playerState, "paused")
      XCTAssertFalse(quarantineStart.playbackRequestedActive)
      XCTAssertFalse(quarantineEnd.playbackRequestedActive)
      XCTAssertGreaterThanOrEqual(
        quarantineStart.systemUptime,
        firstNotification.systemUptime
      )
      XCTAssertEqual(quarantineStart.native.brokerPhase, "ready")
      XCTAssertEqual(quarantineEnd.native.brokerPhase, "ready")
      XCTAssertGreaterThan(
        quarantineStart.native.brokerResetEpoch,
        baseline.native.brokerResetEpoch
      )
      XCTAssertEqual(
        quarantineStart.native.brokerEpoch,
        baseline.native.brokerEpoch
          + UInt64(raw.mediaServicesNotificationSequence.count)
      )
      XCTAssertEqual(
        quarantineStart.native.brokerResetEpoch,
        quarantineStart.native.brokerEpoch
      )
      XCTAssertEqual(
        quarantineEnd.native.brokerResetEpoch,
        quarantineEnd.native.brokerEpoch
      )
      XCTAssertEqual(
        quarantineStart.native.brokerResetEpoch,
        quarantineEnd.native.brokerResetEpoch
      )
      XCTAssertEqual(quarantineStart.native.brokerActiveOwnerCount, 0)
      XCTAssertEqual(quarantineEnd.native.brokerActiveOwnerCount, 0)
      XCTAssertEqual(quarantineStart.native.brokerLiveLeaseCount, 0)
      XCTAssertEqual(quarantineEnd.native.brokerLiveLeaseCount, 0)
      XCTAssertEqual(quarantineStart.native.commandOrigin, "invalidating")
      XCTAssertEqual(quarantineEnd.native.commandOrigin, "invalidating")
      XCTAssertFalse(quarantineStart.native.commandWasDispatched)
      XCTAssertFalse(quarantineEnd.native.commandWasDispatched)
      XCTAssertEqual(
        quarantineStart.native.commandGeneration,
        quarantineEnd.native.commandGeneration
      )
      XCTAssertEqual(
        quarantineStart.native.commandResetEpoch,
        quarantineEnd.native.commandResetEpoch
      )
      XCTAssertEqual(
        quarantineStart.native.acknowledgedResetEpoch,
        quarantineEnd.native.acknowledgedResetEpoch
      )
      XCTAssertEqual(
        quarantineStart.native.outputIncarnationCount,
        baseline.native.outputIncarnationCount
      )
      XCTAssertEqual(
        quarantineEnd.native.outputIncarnationCount,
        baseline.native.outputIncarnationCount
      )
      XCTAssertEqual(
        quarantineStart.native.successfulRebuildCount,
        baseline.native.successfulRebuildCount
      )
      XCTAssertEqual(
        quarantineEnd.native.successfulRebuildCount,
        baseline.native.successfulRebuildCount
      )
      XCTAssertEqual(
        quarantineStart.native.explicitResumeAttemptCount,
        baseline.native.explicitResumeAttemptCount
      )
      XCTAssertEqual(
        quarantineEnd.native.explicitResumeAttemptCount,
        baseline.native.explicitResumeAttemptCount
      )
      XCTAssertEqual(
        quarantineStart.native.explicitResumeFailureCount,
        baseline.native.explicitResumeFailureCount
      )
      XCTAssertEqual(
        quarantineEnd.native.explicitResumeFailureCount,
        baseline.native.explicitResumeFailureCount
      )
      XCTAssertNotEqual(
        quarantineStart.native.acknowledgedResetEpoch,
        quarantineStart.native.brokerResetEpoch
      )
      XCTAssertNotEqual(
        quarantineEnd.native.acknowledgedResetEpoch,
        quarantineEnd.native.brokerResetEpoch
      )
      let measuredQuarantineMilliseconds = Int64(
        ((quarantineEnd.systemUptime - quarantineStart.systemUptime) * 1000)
          .rounded(.down)
      )
      XCTAssertGreaterThanOrEqual(measuredQuarantineMilliseconds, 3000)
      XCTAssertLessThanOrEqual(
        abs(measuredQuarantineMilliseconds - raw.quarantineObservationMilliseconds),
        500
      )
      XCTAssertEqual(
        quarantineStart.playback.mediaTimeMilliseconds,
        quarantineEnd.playback.mediaTimeMilliseconds
      )
      XCTAssertEqual(
        quarantineStart.playback.playedAudioBuffers,
        quarantineEnd.playback.playedAudioBuffers
      )
      if player.role == "native-pip-video" {
        XCTAssertEqual(
          quarantineStart.playback.displayedPictures,
          quarantineEnd.playback.displayedPictures
        )
      }

      XCTAssertEqual(recovered.playerState, "playing")
      XCTAssertTrue(recovered.playbackRequestedActive)
      XCTAssertEqual(recovered.native.brokerPhase, "ready")
      XCTAssertEqual(
        recovered.native.brokerEpoch,
        quarantineEnd.native.brokerResetEpoch
      )
      XCTAssertEqual(
        recovered.native.brokerResetEpoch,
        quarantineEnd.native.brokerResetEpoch
      )
      XCTAssertEqual(recovered.native.commandOrigin, "explicitResume")
      XCTAssertTrue(recovered.native.commandWasDispatched)
      XCTAssertEqual(
        recovered.native.commandResetEpoch,
        quarantineEnd.native.brokerResetEpoch
      )
      XCTAssertEqual(
        recovered.native.acknowledgedResetEpoch,
        recovered.native.commandResetEpoch
      )
      XCTAssertGreaterThan(
        recovered.native.outputIncarnationCount,
        baseline.native.outputIncarnationCount
      )
      XCTAssertGreaterThan(
        recovered.native.successfulRebuildCount,
        baseline.native.successfulRebuildCount
      )
      XCTAssertGreaterThan(
        recovered.native.explicitResumeAttemptCount,
        baseline.native.explicitResumeAttemptCount
      )
      XCTAssertEqual(
        recovered.native.explicitResumeFailureCount,
        baseline.native.explicitResumeFailureCount
      )
      XCTAssertGreaterThanOrEqual(recovered.native.brokerActiveOwnerCount, 3)
      XCTAssertGreaterThanOrEqual(recovered.native.brokerLiveLeaseCount, 1)
      XCTAssertGreaterThan(
        recovered.playback.mediaTimeMilliseconds,
        quarantineEnd.playback.mediaTimeMilliseconds
      )
      XCTAssertGreaterThan(
        recovered.playback.playedAudioBuffers,
        quarantineEnd.playback.playedAudioBuffers
      )
      if player.role == "native-pip-video" {
        XCTAssertGreaterThan(
          recovered.playback.displayedPictures,
          quarantineEnd.playback.displayedPictures
        )
      }
    }

    let baselineOwnership = raw.players.map {
      [
        UInt64($0.baseline.native.brokerActiveOwnerCount),
        UInt64($0.baseline.native.brokerLiveLeaseCount)
      ]
    }
    let recoveredOwnership = raw.players.map {
      [
        UInt64($0.recovered.native.brokerActiveOwnerCount),
        UInt64($0.recovered.native.brokerLiveLeaseCount)
      ]
    }
    XCTAssertTrue(baselineOwnership.dropFirst().allSatisfy { $0 == baselineOwnership[0] })
    XCTAssertTrue(recoveredOwnership.dropFirst().allSatisfy { $0 == recoveredOwnership[0] })
    XCTAssertGreaterThanOrEqual(baselineOwnership[0][0], 3)
    XCTAssertGreaterThanOrEqual(baselineOwnership[0][1], 1)
    XCTAssertGreaterThanOrEqual(recoveredOwnership[0][0], 3)
    XCTAssertGreaterThanOrEqual(recoveredOwnership[0][1], 1)
    let recoveredResetEpochs = raw.players.map(\.recovered.native.commandResetEpoch)
    XCTAssertTrue(
      recoveredResetEpochs.dropFirst().allSatisfy { $0 == recoveredResetEpochs[0] }
    )
  }

  private func decodeResult<T: Decodable>(_ label: String) throws -> T {
    let prefix = "pass:"
    XCTAssertTrue(label.hasPrefix(prefix), "Malformed result label: \(label)")
    let data = try XCTUnwrap(Data(base64Encoded: String(label.dropFirst(prefix.count))))
    return try JSONDecoder().decode(T.self, from: data)
  }

  private func jsonObject(_ value: some Encodable) throws -> [String: Any] {
    let data = try JSONEncoder().encode(value)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  private func adaptiveAttemptToken(from url: URL) -> String? {
    let components = url.pathComponents.filter { $0 != "/" }
    guard
      components.count >= 4,
      components[0] == "adaptive",
      components[2] == "timebase-vod-ts",
      components[3] == "master.m3u8",
      !components[1].isEmpty,
      components[1].allSatisfy({
        $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-"
      })
    else { return nil }
    return components[1]
  }

  private func element(_ identifier: String) -> XCUIElement {
    app.descendants(matching: .any)[identifier]
  }

  private func reveal(_ element: XCUIElement) {
    for _ in 0..<12 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
  }

  private func replaceLaunchArgument(_ name: String, with value: String) {
    if let index = app.launchArguments.firstIndex(of: name) {
      let valueIndex = app.launchArguments.index(after: index)
      if valueIndex < app.launchArguments.endIndex {
        app.launchArguments[valueIndex] = value
        return
      }
    }
    app.launchArguments += [name, value]
  }
}
