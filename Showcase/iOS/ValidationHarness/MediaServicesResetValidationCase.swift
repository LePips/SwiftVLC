import AVFoundation
import Combine
import SwiftUI
@_spi(Qualification) import SwiftVLC

/// Operator-assisted proof of a real Settings > Developer media-services
/// reset across both pinned Apple audio outputs while native PiP is active.
/// No test-only notification can satisfy the native epoch/acknowledgement
/// assertions recorded by this surface.
struct MediaServicesResetValidationCase: View {
  @State private var audioPlayer: Player?
  @State private var videoPlayer: Player?
  @State private var controller: PiPController?
  @State private var phase = "preparing"
  @State private var result = "not-run"
  @State private var errorMessage: String?
  @State private var mediaServicesNotificationSequence:
    [AppleAudioMediaServicesNotificationRecord] = []
  @State private var readinessStartAudio: AppleAudioRecoveryCheckpoint?
  @State private var readinessStartVideo: AppleAudioRecoveryCheckpoint?
  @State private var baselineAudio: AppleAudioRecoveryCheckpoint?
  @State private var baselineVideo: AppleAudioRecoveryCheckpoint?
  @State private var quarantineStartAudio: AppleAudioRecoveryCheckpoint?
  @State private var quarantineStartVideo: AppleAudioRecoveryCheckpoint?
  @State private var quarantineEndAudio: AppleAudioRecoveryCheckpoint?
  @State private var quarantineEndVideo: AppleAudioRecoveryCheckpoint?
  @State private var monitorTask: Task<Void, Never>?

  var body: some View {
    Form {
      if let videoPlayer {
        Section {
          PiPVideoView(
            videoPlayer,
            controller: $controller,
            startsAutomaticallyFromInline: false
          )
          .frame(height: 220)
          .background(.black)
          .listRowInsets(EdgeInsets())
          .accessibilityIdentifier(
            AccessibilityID.MediaServicesResetValidation.videoView
          )
        }
      }

      Section("Measured state") {
        valueRow(
          "Phase",
          value: phase,
          identifier: AccessibilityID.MediaServicesResetValidation.phaseLabel
        )
        valueRow(
          "Audio-only state",
          value: audioPlayer?.state.description ?? "missing",
          identifier: AccessibilityID.MediaServicesResetValidation.audioStateLabel
        )
        valueRow(
          "Native PiP state",
          value: videoPlayer?.state.description ?? "missing",
          identifier: AccessibilityID.MediaServicesResetValidation.videoStateLabel
        )
        valueRow(
          "PiP active",
          value: controller?.isActive == true ? "yes" : "no",
          identifier:
          AccessibilityID.MediaServicesResetValidation.pictureInPictureActiveLabel
        )
        valueRow(
          "Lost / reset notifications",
          value: "\(lostNotificationCount):\(resetNotificationCount)",
          identifier:
          AccessibilityID.MediaServicesResetValidation.notificationCountsLabel
        )
        valueRow(
          "Qualification",
          value: result,
          identifier: AccessibilityID.MediaServicesResetValidation.resultLabel
        )
      }

      Section {
        Button("Start native Picture in Picture") {
          Task { await startPictureInPicture() }
        }
        .accessibilityIdentifier(
          AccessibilityID.MediaServicesResetValidation.startPictureInPictureButton
        )
        .disabled(phase != "ready-for-pip")

        Button("Arm real media-services reset") {
          Task { await armResetObservation() }
        }
        .accessibilityIdentifier(AccessibilityID.MediaServicesResetValidation.armButton)
        .disabled(phase != "ready-to-arm")

        Button("Explicitly resume both players") {
          Task { await resumeAfterReset() }
        }
        .accessibilityIdentifier(
          AccessibilityID.MediaServicesResetValidation.resumeButton
        )
        .disabled(phase != "reset-quarantined")

        if let errorMessage {
          Text(errorMessage)
            .foregroundStyle(.red)
            .accessibilityIdentifier(
              AccessibilityID.MediaServicesResetValidation.errorLabel
            )
        }
      } header: {
        Text("Qualification controls")
      } footer: {
        Text(
          "After arming, leave this app, open Settings > Developer, reset "
            + "Media Services, and return here. The runner proceeds only after "
            + "the native broker reports a new reset epoch."
        )
      }
    }
    .showcaseFormStyle()
    .navigationTitle("Media-services reset")
    .task { await preparePlayback() }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVAudioSession.mediaServicesWereLostNotification,
        object: AVAudioSession.sharedInstance()
      )
    ) { _ in
      mediaServicesNotificationSequence.append(
        AppleAudioMediaServicesNotificationRecord(
          kind: "lost",
          systemUptime: ProcessInfo.processInfo.systemUptime
        )
      )
    }
    .onReceive(
      NotificationCenter.default.publisher(
        for: AVAudioSession.mediaServicesWereResetNotification,
        object: AVAudioSession.sharedInstance()
      )
    ) { _ in
      mediaServicesNotificationSequence.append(
        AppleAudioMediaServicesNotificationRecord(
          kind: "reset",
          systemUptime: ProcessInfo.processInfo.systemUptime
        )
      )
    }
    .onDisappear {
      monitorTask?.cancel()
      controller?.stop()
      audioPlayer?.stop()
      videoPlayer?.stop()
    }
  }

  private func preparePlayback() async {
    guard audioPlayer == nil, videoPlayer == nil else { return }
    do {
      guard LaunchArguments.isUITestMode else {
        throw AppleAudioQualificationFailure("This surface is UI-test only")
      }
      guard let resetURL = LaunchArguments.audioMediaServicesResetURLValue else {
        throw AppleAudioQualificationFailure(
          "Missing per-attempt media-services reset fixture"
        )
      }

      let audioInstance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + [
          "--aout=audiounit_ios",
          "--no-video"
        ]
      )
      let videoInstance = try VLCInstance(
        arguments: VLCInstance.defaultArguments + ["--aout=avsamplebuffer"]
      )
      UITestSupport.startAdditionalLogMirrorIfRequested(
        from: audioInstance,
        childName: "audiounit"
      )
      UITestSupport.startAdditionalLogMirrorIfRequested(
        from: videoInstance,
        childName: "avsamplebuffer"
      )

      let audio = Player(instance: audioInstance)
      let video = Player(instance: videoInstance)
      audioPlayer = audio
      videoPlayer = video
      try audio.play(url: resetURL)
      try video.play(url: resetURL)
      try await AppleAudioQualificationSupport.waitUntil(timeout: .seconds(40)) {
        audio.state == .playing
          && video.state == .playing
          && (audio.statistics?.playedAudioBuffers ?? 0) > 0
          && (video.statistics?.playedAudioBuffers ?? 0) > 0
          && (video.statistics?.displayedPictures ?? 0) > 0
          && controller?.isPossible == true
      }
      phase = "ready-for-pip"
    } catch is CancellationError {
      phase = "cancelled"
    } catch {
      fail(error)
    }
  }

  private func startPictureInPicture() async {
    do {
      guard let controller, controller.requestStart() == .accepted else {
        throw AppleAudioQualificationFailure("Native PiP start was not accepted")
      }
      try await AppleAudioQualificationSupport.waitUntil(timeout: .seconds(15)) {
        controller.isActive
      }
      phase = "ready-to-arm"
    } catch {
      fail(error)
    }
  }

  private func armResetObservation() async {
    do {
      guard let audioPlayer, let videoPlayer, controller?.isActive == true else {
        throw AppleAudioQualificationFailure("Players or native PiP are unavailable")
      }
      mediaServicesNotificationSequence.removeAll(keepingCapacity: true)
      let audioStart = try await AppleAudioQualificationSupport.checkpoint(audioPlayer)
      let videoStart = try await AppleAudioQualificationSupport.checkpoint(videoPlayer)
      try validateActiveBaseline(audioStart, role: "audio-only")
      try validateActiveBaseline(videoStart, role: "native-pip-video")
      try await Task.sleep(for: .seconds(1))
      let audio = try await AppleAudioQualificationSupport.checkpoint(audioPlayer)
      let video = try await AppleAudioQualificationSupport.checkpoint(videoPlayer)
      try validateReadiness(
        start: audioStart,
        end: audio,
        role: "audio-only",
        checksVideo: false
      )
      try validateReadiness(
        start: videoStart,
        end: video,
        role: "native-pip-video",
        checksVideo: true
      )
      guard
        mediaServicesNotificationSequence.isEmpty,
        audio.native.brokerActiveOwnerCount >= 3,
        audio.native.brokerLiveLeaseCount >= 1,
        audio.native.brokerActiveOwnerCount == video.native.brokerActiveOwnerCount,
        audio.native.brokerLiveLeaseCount == video.native.brokerLiveLeaseCount
      else {
        throw AppleAudioQualificationFailure(
          "Baseline does not contain two outputs plus the native PiP lease"
        )
      }
      readinessStartAudio = audioStart
      readinessStartVideo = videoStart
      baselineAudio = audio
      baselineVideo = video
      phase = "awaiting-system-reset"
      result = "waiting-for-real-reset"
      monitorTask?.cancel()
      monitorTask = Task { await observeResetQuarantine() }
    } catch {
      fail(error)
    }
  }

  private func observeResetQuarantine() async {
    do {
      guard
        let audioPlayer,
        let videoPlayer,
        var currentBaselineAudio = baselineAudio,
        var currentBaselineVideo = baselineVideo
      else {
        throw AppleAudioQualificationFailure("Reset baseline was not retained")
      }
      let deadline = ProcessInfo.processInfo.systemUptime + 600
      while true {
        try Task.checkCancellation()
        if
          resetNotificationCount > 0,
          let audio = audioPlayer.appleAudioRecoveryQualificationSnapshot,
          let video = videoPlayer.appleAudioRecoveryQualificationSnapshot,
          audio.brokerResetEpoch > currentBaselineAudio.native.brokerResetEpoch,
          video.brokerResetEpoch > currentBaselineVideo.native.brokerResetEpoch {
          break
        }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
          throw AppleAudioQualificationFailure(
            "Timed out waiting for a real media-services reset"
          )
        }
        guard mediaServicesNotificationSequence.isEmpty else {
          try await Task.sleep(for: .milliseconds(250))
          continue
        }

        try await Task.sleep(for: .seconds(1))
        guard mediaServicesNotificationSequence.isEmpty else { continue }
        let nextAudio = try await AppleAudioQualificationSupport.checkpoint(audioPlayer)
        let nextVideo = try await AppleAudioQualificationSupport.checkpoint(videoPlayer)
        guard mediaServicesNotificationSequence.isEmpty else { continue }
        try validateReadiness(
          start: currentBaselineAudio,
          end: nextAudio,
          role: "audio-only",
          checksVideo: false
        )
        try validateReadiness(
          start: currentBaselineVideo,
          end: nextVideo,
          role: "native-pip-video",
          checksVideo: true
        )
        readinessStartAudio = currentBaselineAudio
        readinessStartVideo = currentBaselineVideo
        baselineAudio = nextAudio
        baselineVideo = nextVideo
        currentBaselineAudio = nextAudio
        currentBaselineVideo = nextVideo
      }
      guard
        let firstNotification = mediaServicesNotificationSequence.first,
        firstNotification.systemUptime >= currentBaselineAudio.systemUptime,
        firstNotification.systemUptime >= currentBaselineVideo.systemUptime,
        currentBaselineAudio.systemUptime.distanceMilliseconds(
          to: firstNotification.systemUptime
        ) <= 2500,
        currentBaselineVideo.systemUptime.distanceMilliseconds(
          to: firstNotification.systemUptime
        ) <= 2500
      else {
        throw AppleAudioQualificationFailure(
          "The last active playback proof was not adjacent to the reset signal"
        )
      }
      try await AppleAudioQualificationSupport.waitUntil(timeout: .seconds(30)) {
        guard
          audioPlayer.state == .paused,
          videoPlayer.state == .paused,
          let audio = audioPlayer.appleAudioRecoveryQualificationSnapshot,
          let video = videoPlayer.appleAudioRecoveryQualificationSnapshot
        else { return false }
        return isQuarantined(audio) && isQuarantined(video)
      }

      let audioStart = try await AppleAudioQualificationSupport.checkpoint(audioPlayer)
      let videoStart = try await AppleAudioQualificationSupport.checkpoint(videoPlayer)
      quarantineStartAudio = audioStart
      quarantineStartVideo = videoStart
      let observationStart = ContinuousClock.now
      try await Task.sleep(for: .seconds(3))
      let audioEnd = try await AppleAudioQualificationSupport.checkpoint(audioPlayer)
      let videoEnd = try await AppleAudioQualificationSupport.checkpoint(videoPlayer)
      try validateFrozen(
        baseline: currentBaselineAudio,
        start: audioStart,
        end: audioEnd,
        checksVideo: false
      )
      try validateFrozen(
        baseline: currentBaselineVideo,
        start: videoStart,
        end: videoEnd,
        checksVideo: true
      )
      quarantineEndAudio = audioEnd
      quarantineEndVideo = videoEnd
      let elapsed = observationStart.duration(to: .now).milliseconds
      guard elapsed >= 3000 else {
        throw AppleAudioQualificationFailure("Quarantine window was truncated")
      }
      phase = "reset-quarantined"
      result = "real-reset-observed-awaiting-explicit-resume"
    } catch is CancellationError {
      phase = "cancelled"
    } catch {
      fail(error)
    }
  }

  private func resumeAfterReset() async {
    do {
      guard
        let audioPlayer,
        let videoPlayer,
        let readinessStartAudio,
        let readinessStartVideo,
        let baselineAudio,
        let baselineVideo,
        let quarantineStartAudio,
        let quarantineStartVideo,
        let quarantineEndAudio,
        let quarantineEndVideo
      else {
        throw AppleAudioQualificationFailure("Quarantine evidence is incomplete")
      }
      phase = "resuming"
      audioPlayer.resume()
      videoPlayer.resume()
      try await AppleAudioQualificationSupport.waitUntil(timeout: .seconds(40)) {
        guard
          audioPlayer.state == .playing,
          videoPlayer.state == .playing,
          let audio = audioPlayer.appleAudioRecoveryQualificationSnapshot,
          let video = videoPlayer.appleAudioRecoveryQualificationSnapshot
        else { return false }
        return isRecovered(audio) && isRecovered(video)
          && (audioPlayer.statistics?.playedAudioBuffers ?? 0)
          > quarantineEndAudio.playback.playedAudioBuffers
          && (videoPlayer.statistics?.playedAudioBuffers ?? 0)
          > quarantineEndVideo.playback.playedAudioBuffers
          && (videoPlayer.statistics?.displayedPictures ?? 0)
          > quarantineEndVideo.playback.displayedPictures
          && audioPlayer.currentTime.milliseconds
          > quarantineEndAudio.playback.mediaTimeMilliseconds
          && videoPlayer.currentTime.milliseconds
          > quarantineEndVideo.playback.mediaTimeMilliseconds
      }
      let recoveredAudio = try await AppleAudioQualificationSupport.checkpoint(audioPlayer)
      let recoveredVideo = try await AppleAudioQualificationSupport.checkpoint(videoPlayer)
      try validateRecovered(
        recoveredAudio,
        baseline: baselineAudio,
        quarantine: quarantineEndAudio,
        checksVideo: false
      )
      try validateRecovered(
        recoveredVideo,
        baseline: baselineVideo,
        quarantine: quarantineEndVideo,
        checksVideo: true
      )
      guard controller?.isActive == true else {
        throw AppleAudioQualificationFailure("Native PiP did not remain active")
      }

      let raw = MediaServicesResetQualificationRawResult(
        formatVersion: 1,
        trigger: "settings-developer-media-services-reset-v1",
        syntheticNotificationsPosted: false,
        mediaServicesLostNotificationCount: lostNotificationCount,
        mediaServicesResetNotificationCount: resetNotificationCount,
        mediaServicesNotificationSequence: mediaServicesNotificationSequence,
        quarantineObservationMilliseconds:
        quarantineStartAudio.systemUptime.distanceMilliseconds(
          to: quarantineEndAudio.systemUptime
        ),
        pictureInPictureActiveBeforeReset: true,
        pictureInPictureActiveAfterRecovery: true,
        players: [
          AppleAudioResetPlayerRecord(
            role: "audio-only",
            forcedAudioOutputModule: "audiounit_ios",
            readinessStart: readinessStartAudio,
            baseline: baselineAudio,
            quarantineStart: quarantineStartAudio,
            quarantineEnd: quarantineEndAudio,
            recovered: recoveredAudio
          ),
          AppleAudioResetPlayerRecord(
            role: "native-pip-video",
            forcedAudioOutputModule: "avsamplebuffer",
            readinessStart: readinessStartVideo,
            baseline: baselineVideo,
            quarantineStart: quarantineStartVideo,
            quarantineEnd: quarantineEndVideo,
            recovered: recoveredVideo
          )
        ]
      )
      result = try AppleAudioQualificationSupport.encodedLabel(raw)
      phase = "complete"
    } catch {
      fail(error)
    }
  }

  private func validateActiveBaseline(
    _ checkpoint: AppleAudioRecoveryCheckpoint,
    role: String
  )
    throws {
    guard
      checkpoint.playerState == "playing",
      checkpoint.playbackRequestedActive,
      checkpoint.playback.playedAudioBuffers > 0,
      checkpoint.native.brokerPhase == "ready",
      checkpoint.native.brokerEpoch > 0,
      checkpoint.native.liveOutputCount > 0
    else {
      throw AppleAudioQualificationFailure("\(role) baseline was not active")
    }
  }

  private func validateReadiness(
    start: AppleAudioRecoveryCheckpoint,
    end: AppleAudioRecoveryCheckpoint,
    role: String,
    checksVideo: Bool
  )
    throws {
    try validateActiveBaseline(end, role: role)
    guard
      start.systemUptime.distanceMilliseconds(to: end.systemUptime) >= 500,
      start.systemUptime.distanceMilliseconds(to: end.systemUptime) <= 2500,
      start.native.brokerPhase == "ready",
      end.native.brokerPhase == "ready",
      start.native.brokerEpoch == end.native.brokerEpoch,
      start.native.brokerResetEpoch == end.native.brokerResetEpoch,
      start.native.commandGeneration == end.native.commandGeneration,
      start.native.outputIncarnationCount == end.native.outputIncarnationCount,
      start.native.brokerActiveOwnerCount == end.native.brokerActiveOwnerCount,
      start.native.brokerLiveLeaseCount == end.native.brokerLiveLeaseCount,
      end.playback.mediaTimeMilliseconds > start.playback.mediaTimeMilliseconds,
      end.playback.playedAudioBuffers > start.playback.playedAudioBuffers,
      !checksVideo
      || end.playback.displayedPictures > start.playback.displayedPictures
    else {
      throw AppleAudioQualificationFailure(
        "\(role) did not prove stable playback before arming the reset"
      )
    }
  }

  private func isQuarantined(
    _ snapshot: AppleAudioRecoveryQualificationSnapshot
  ) -> Bool {
    snapshot.brokerPhase == .ready
      && snapshot.brokerResetEpoch > 0
      && snapshot.brokerResetEpoch == snapshot.brokerEpoch
      && snapshot.brokerActiveOwnerCount == 0
      && snapshot.brokerLiveLeaseCount == 0
      && snapshot.commandOrigin == .invalidating
      && !snapshot.commandWasDispatched
      && snapshot.acknowledgedResetEpoch != snapshot.brokerResetEpoch
  }

  private func validateFrozen(
    baseline: AppleAudioRecoveryCheckpoint,
    start: AppleAudioRecoveryCheckpoint,
    end: AppleAudioRecoveryCheckpoint,
    checksVideo: Bool
  )
    throws {
    guard
      start.playerState == "paused",
      end.playerState == "paused",
      !start.playbackRequestedActive,
      !end.playbackRequestedActive,
      start.native.brokerPhase == "ready",
      end.native.brokerPhase == "ready",
      start.native.brokerEpoch
      == baseline.native.brokerEpoch
      + UInt64(mediaServicesNotificationSequence.count),
      start.native.brokerResetEpoch == end.native.brokerResetEpoch,
      start.native.brokerResetEpoch > 0,
      start.native.brokerResetEpoch == start.native.brokerEpoch,
      end.native.brokerResetEpoch == end.native.brokerEpoch,
      start.native.brokerActiveOwnerCount == 0,
      end.native.brokerActiveOwnerCount == 0,
      start.native.brokerLiveLeaseCount == 0,
      end.native.brokerLiveLeaseCount == 0,
      start.native.commandOrigin == "invalidating",
      end.native.commandOrigin == "invalidating",
      !start.native.commandWasDispatched,
      !end.native.commandWasDispatched,
      start.native.commandGeneration == end.native.commandGeneration,
      start.native.commandResetEpoch == end.native.commandResetEpoch,
      start.native.acknowledgedResetEpoch == end.native.acknowledgedResetEpoch,
      start.native.acknowledgedResetEpoch != start.native.brokerResetEpoch,
      end.native.acknowledgedResetEpoch != end.native.brokerResetEpoch,
      start.native.outputIncarnationCount == baseline.native.outputIncarnationCount,
      end.native.outputIncarnationCount == baseline.native.outputIncarnationCount,
      start.native.successfulRebuildCount == baseline.native.successfulRebuildCount,
      end.native.successfulRebuildCount == baseline.native.successfulRebuildCount,
      start.native.explicitResumeAttemptCount
      == baseline.native.explicitResumeAttemptCount,
      end.native.explicitResumeAttemptCount
      == baseline.native.explicitResumeAttemptCount,
      start.native.explicitResumeFailureCount
      == baseline.native.explicitResumeFailureCount,
      end.native.explicitResumeFailureCount
      == baseline.native.explicitResumeFailureCount,
      start.playback.mediaTimeMilliseconds == end.playback.mediaTimeMilliseconds,
      start.playback.playedAudioBuffers == end.playback.playedAudioBuffers,
      !checksVideo
      || start.playback.displayedPictures == end.playback.displayedPictures
    else {
      throw AppleAudioQualificationFailure(
        "Playback advanced without fresh post-reset intent"
      )
    }
  }

  private func isRecovered(
    _ snapshot: AppleAudioRecoveryQualificationSnapshot
  ) -> Bool {
    snapshot.brokerPhase == .ready
      && snapshot.brokerResetEpoch > 0
      && snapshot.brokerResetEpoch == snapshot.brokerEpoch
      && snapshot.commandOrigin == .explicitResume
      && snapshot.commandWasDispatched
      && snapshot.commandResetEpoch == snapshot.brokerResetEpoch
      && snapshot.acknowledgedResetEpoch == snapshot.commandResetEpoch
      && snapshot.liveOutputCount > 0
      && snapshot.brokerActiveOwnerCount > 0
  }

  private func validateRecovered(
    _ recovered: AppleAudioRecoveryCheckpoint,
    baseline: AppleAudioRecoveryCheckpoint,
    quarantine: AppleAudioRecoveryCheckpoint,
    checksVideo: Bool
  )
    throws {
    guard
      recovered.playerState == "playing",
      recovered.playbackRequestedActive,
      recovered.native.brokerPhase == "ready",
      recovered.native.brokerEpoch == quarantine.native.brokerResetEpoch,
      recovered.native.brokerResetEpoch == quarantine.native.brokerResetEpoch,
      recovered.native.commandOrigin == "explicitResume",
      recovered.native.commandWasDispatched,
      recovered.native.commandResetEpoch == quarantine.native.brokerResetEpoch,
      recovered.native.acknowledgedResetEpoch == quarantine.native.brokerResetEpoch,
      recovered.native.commandGeneration > quarantine.native.commandGeneration,
      recovered.native.outputIncarnationCount > baseline.native.outputIncarnationCount,
      recovered.native.successfulRebuildCount > baseline.native.successfulRebuildCount,
      recovered.native.explicitResumeAttemptCount
      > baseline.native.explicitResumeAttemptCount,
      recovered.native.explicitResumeFailureCount
      == baseline.native.explicitResumeFailureCount,
      recovered.native.brokerActiveOwnerCount >= 3,
      recovered.native.brokerLiveLeaseCount >= 1,
      recovered.playback.mediaTimeMilliseconds
      > quarantine.playback.mediaTimeMilliseconds,
      recovered.playback.playedAudioBuffers
      > quarantine.playback.playedAudioBuffers,
      !checksVideo
      || recovered.playback.displayedPictures
      > quarantine.playback.displayedPictures
    else {
      throw AppleAudioQualificationFailure("Post-reset recovery was not causal")
    }
  }

  private func fail(_ error: any Error) {
    errorMessage = String(describing: error)
    result = "failed"
    phase = "failed"
  }

  private var lostNotificationCount: Int {
    mediaServicesNotificationSequence.count { $0.kind == "lost" }
  }

  private var resetNotificationCount: Int {
    mediaServicesNotificationSequence.count { $0.kind == "reset" }
  }

  private func valueRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .font(.caption.monospacedDigit())
        .accessibilityIdentifier(identifier)
    }
  }
}

extension TimeInterval {
  fileprivate func distanceMilliseconds(to end: TimeInterval) -> Int64 {
    Int64(((end - self) * 1000).rounded(.down))
  }
}
