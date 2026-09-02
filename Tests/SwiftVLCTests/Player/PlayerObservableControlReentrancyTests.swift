@testable import SwiftVLC
import CustomDump
import Foundation
import Observation
import Testing

@MainActor
private final class SingleReentrantControlAction {
  private(set) var invocationCount = 0
  private let action: @MainActor () -> Void

  init(action: @escaping @MainActor () -> Void) {
    self.action = action
  }

  func run() {
    invocationCount += 1
    guard invocationCount == 1 else { return }
    action()
  }
}

@MainActor
private final class RearmingObservationProbe {
  private let read: @MainActor () -> Void
  private(set) var invocationCount = 0

  init(read: @escaping @MainActor () -> Void) {
    self.read = read
  }

  func arm() {
    withObservationTracking {
      read()
    } onChange: { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.invocationCount += 1
        if self.invocationCount == 1 {
          self.arm()
        }
      }
    }
  }
}

extension Integration {
  @Suite(.tags(.mainActor), .serialized, .timeLimit(.minutes(1)))
  @MainActor struct PlayerObservableControlReentrancyTests {
    @Test
    func `Volume and mute use one observable boundary and newest command wins`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var dispatches: [Player.ObservableControlNativeDispatch] = []
      player._observableControlNativeDispatchHookForTesting = { _, dispatch in
        dispatches.append(dispatch)
      }

      let volumeAction = observe({ player.volume }) {
        try! player.setAudioVolume(Volume(0.8))
      }
      try player.setAudioVolume(Volume(0.2))

      #expect(volumeAction.invocationCount == 2)
      #expect(player.volume == 0.8)
      #expect(player.intentRevisions.audioVolume == 2)
      expectNoDifference(dispatches, [.audioVolume(0.8)])

      dispatches.removeAll()
      let muteAction = observe({ player.isMuted }) {
        player.isMuted = false
      }
      player.isMuted = true

      #expect(muteAction.invocationCount == 2)
      #expect(!player.isMuted)
      #expect(player.intentRevisions.mute == 2)
      expectNoDifference(dispatches, [.mute(false)])
    }

    @Test
    func `Rate delay scale and role discard older reentrant native commands`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var dispatches: [Player.ObservableControlNativeDispatch] = []
      player._observableControlNativeDispatchHookForTesting = { _, dispatch in
        dispatches.append(dispatch)
      }

      let rateAction = observe({ player.rate }) {
        try? player.setPlaybackRate(PlaybackRate(2))
      }
      try? player.setPlaybackRate(PlaybackRate(0.5))
      #expect(rateAction.invocationCount == 2)
      expectNoDifference(dispatches, [.playbackRate(2)])

      dispatches.removeAll()
      let audioDelayAction = observe({ player.audioDelay }) {
        try? player.setAudioDelay(.milliseconds(200))
      }
      try? player.setAudioDelay(.milliseconds(100))
      #expect(audioDelayAction.invocationCount == 2)
      expectNoDifference(dispatches, [.audioDelay(.milliseconds(200))])

      dispatches.removeAll()
      let subtitleDelayAction = observe({ player.subtitleDelay }) {
        try? player.setSubtitleDelay(.milliseconds(400))
      }
      try? player.setSubtitleDelay(.milliseconds(300))
      #expect(subtitleDelayAction.invocationCount == 2)
      expectNoDifference(dispatches, [.subtitleDelay(.milliseconds(400))])

      dispatches.removeAll()
      let scaleAction = observe({ player.subtitleTextScale }) {
        player.setSubtitleScale(SubtitleScale(1.75))
      }
      player.setSubtitleScale(SubtitleScale(1.25))
      #expect(scaleAction.invocationCount == 2)
      expectNoDifference(dispatches, [.subtitleScale(1.75)])

      dispatches.removeAll()
      let roleAction = observe({ player.role }) {
        player.role = .music
      }
      player.role = .video
      #expect(roleAction.invocationCount == 2)
      expectNoDifference(dispatches, [.role(.music)])
    }

    @Test
    func `Equalizer aspect and channel modes preserve the newest command`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var dispatches: [Player.ObservableControlNativeDispatch] = []
      player._observableControlNativeDispatchHookForTesting = { _, dispatch in
        dispatches.append(dispatch)
      }

      let outerEqualizer = Equalizer()
      let newerEqualizer = Equalizer()
      let equalizerAction = observe({ player.equalizer }) {
        player.equalizer = newerEqualizer
      }
      player.equalizer = outerEqualizer
      #expect(equalizerAction.invocationCount == 2)
      #expect(player.equalizer === newerEqualizer)
      expectNoDifference(
        dispatches,
        [.equalizer(ObjectIdentifier(newerEqualizer))]
      )

      dispatches.removeAll()
      let aspectAction = observe({ player.aspectRatio }) {
        player.aspectRatio = .fill
      }
      player.aspectRatio = .ratio(4, 3)
      #expect(aspectAction.invocationCount == 2)
      #expect(player.aspectRatio == .fill)
      expectNoDifference(dispatches, [.aspectRatio(.fill)])

      dispatches.removeAll()
      let stereoAction = observe({ player.stereoMode }) {
        player.stereoMode = .reverseStereo
      }
      player.stereoMode = .mono
      #expect(stereoAction.invocationCount == 2)
      expectNoDifference(dispatches, [.stereoMode(.reverseStereo)])

      dispatches.removeAll()
      let mixAction = observe({ player.mixMode }) {
        player.mixMode = .binaural
      }
      player.mixMode = .stereo
      #expect(mixAction.invocationCount == 2)
      expectNoDifference(dispatches, [.mixMode(.binaural)])
    }

    @Test
    func `Teletext chapter title and track controls are last invoked wins`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      var dispatches: [Player.ObservableControlNativeDispatch] = []
      player._observableControlNativeDispatchHookForTesting = { _, dispatch in
        dispatches.append(dispatch)
      }

      let teletextAction = observe({ player.teletextPage }) {
        try! player.setTeletextPage(222)
      }
      try player.setTeletextPage(111)
      #expect(teletextAction.invocationCount == 2)
      #expect(player._teletextPage == 222)
      expectNoDifference(dispatches, [.teletextPage(222)])

      dispatches.removeAll()
      let chapterAction = observe({ player.currentChapter }) {
        player.currentChapter = 2
      }
      player.currentChapter = 1
      #expect(chapterAction.invocationCount == 2)
      expectNoDifference(dispatches, [.chapter(2)])

      dispatches.removeAll()
      let titleAction = observe({ player.currentTitle }) {
        player.currentTitle = 4
      }
      player.currentTitle = 3
      #expect(titleAction.invocationCount == 2)
      expectNoDifference(dispatches, [.title(4)])

      dispatches.removeAll()
      let audioTrackAction = observe({ player.selectedAudioTrack }) {
        player.selectedAudioTrack = nil
      }
      player.selectedAudioTrack = Self.track(id: "obsolete-audio", type: .audio)
      #expect(audioTrackAction.invocationCount == 2)
      expectNoDifference(dispatches, [.audioTrack(nil)])

      dispatches.removeAll()
      let subtitleTrackAction = observe({ player.selectedSubtitleTrack }) {
        player.selectedSubtitleTrack = nil
      }
      player.selectedSubtitleTrack = Self.track(id: "obsolete-subtitle", type: .subtitle)
      #expect(subtitleTrackAction.invocationCount == 2)
      expectNoDifference(dispatches, [.subtitleTrack(nil)])
    }

    @Test
    func `Load and play replacement in an observer quarantines the older handle command`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(state: .paused, nativeState: .paused)
      player._nativePlayOverrideForTesting = { 0 }
      let retiringPointer = player.pointer
      var dispatchedPointers: [OpaquePointer] = []
      var dispatches: [Player.ObservableControlNativeDispatch] = []
      player._observableControlNativeDispatchHookForTesting = { pointer, dispatch in
        dispatchedPointers.append(pointer)
        dispatches.append(dispatch)
      }

      let replacementAction = observe({ player.volume }) {
        player.load(try! Media(url: TestMedia.twosecURL))
        try! player.play()
        try! player.setAudioVolume(Volume(0.9))
      }
      try player.setAudioVolume(Volume(0.1))

      #expect(replacementAction.invocationCount == 2)
      #expect(player.pointer != retiringPointer)
      #expect(player.volume == 0.9)
      expectNoDifference(dispatches, [.audioVolume(0.9)])
      expectNoDifference(dispatchedPointers, [player.pointer])
    }

    @Test
    func `Sourced track refresh cannot publish a snapshot after reentrant selection`() {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let priorTrack = Self.track(
        id: "prior-audio",
        type: .audio,
        isSelected: true
      )
      player.audioTracks = [priorTrack]
      var dispatches: [Player.ObservableControlNativeDispatch] = []
      player._observableControlNativeDispatchHookForTesting = { _, dispatch in
        dispatches.append(dispatch)
      }

      let selectionAction = observe({ player.audioTracks }) {
        player.selectedAudioTrack = nil
      }
      player._handleEventForTesting(
        .tracksChanged,
        nativeHandleGeneration: player.eventBridge.currentNativeHandleGeneration
      )

      #expect(selectionAction.invocationCount == 1)
      expectNoDifference(player.audioTracks, [priorTrack])
      expectNoDifference(dispatches, [.audioTrack(nil)])
    }

    @Test
    func `Equalizer newer and no-op band intents supersede older observable bodies`() throws {
      let equalizer = Equalizer()
      let zeros = Array(repeating: Float.zero, count: Equalizer.bandCount)
      let ones = Array(repeating: Float(1), count: Equalizer.bandCount)
      let twos = Array(repeating: Float(2), count: Equalizer.bandCount)

      let newerBandsAction = observe({ equalizer.bands }) {
        try! equalizer.setBands(twos)
      }
      try equalizer.setBands(ones)
      #expect(newerBandsAction.invocationCount == 2)
      expectNoDifference(equalizer.bands, twos)

      try equalizer.setBands(zeros)
      let noOpAction = observe({ equalizer.bands }) {
        // This is already the native value. It is still a newer invocation
        // and must cancel the pending outer all-ones command.
        try! equalizer.setAmplification(.zero, forBand: 0)
      }
      try equalizer.setBands(ones)
      #expect(noOpAction.invocationCount == 1)
      expectNoDifference(equalizer.bands, zeros)

      let preampAction = observe({ equalizer.preamp }) {
        equalizer.preampGain = EqualizerGain(7)
      }
      equalizer.preampGain = EqualizerGain(5)
      #expect(preampAction.invocationCount == 2)
      #expect(equalizer.preamp == 7)
    }

    @Test
    func `Native audio refresh cannot overwrite a newer reentrant control intent`() {
      let volumePlayer = Player(instance: TestInstance.makeAudioOnly())
      volumePlayer._volume = 0.8
      volumePlayer._nativeVolumeOverrideForTesting = 30
      var volumeDispatches: [Player.ObservableControlNativeDispatch] = []
      volumePlayer._observableControlNativeDispatchHookForTesting = { _, dispatch in
        volumeDispatches.append(dispatch)
      }
      let volumeAction = observe({ volumePlayer.volume }) {
        // Restoring the value that was current before the refresh is still a
        // newer command and must retire the sampled 30% publication.
        try! volumePlayer.setAudioVolume(Volume(0.8))
      }

      let didRefreshVolume = volumePlayer.refreshNativeStateIfNeeded(
        ifPlaybackGeneration: volumePlayer.sessionGeneration,
        nativeHandleGeneration: volumePlayer.eventBridge.currentNativeHandleGeneration,
        timelineRevision: volumePlayer.acceptedTimelineRevision,
        lifecycleControlEpoch: volumePlayer.eventBridge.currentLifecycleControlEpoch
      )

      #expect(!didRefreshVolume)
      #expect(volumeAction.invocationCount == 2)
      #expect(volumePlayer.volume == 0.8)
      #expect(volumePlayer.intentRevisions.audioVolume == 1)
      expectNoDifference(volumeDispatches, [.audioVolume(0.8)])

      let mutePlayer = Player(instance: TestInstance.makeAudioOnly())
      mutePlayer._isMuted = true
      mutePlayer._nativeMuteOverrideForTesting = 0
      var muteDispatches: [Player.ObservableControlNativeDispatch] = []
      mutePlayer._observableControlNativeDispatchHookForTesting = { _, dispatch in
        muteDispatches.append(dispatch)
      }
      let muteAction = observe({ mutePlayer.isMuted }) {
        mutePlayer.isMuted = true
      }

      let didRefreshMute = mutePlayer.refreshNativeStateIfNeeded(
        ifPlaybackGeneration: mutePlayer.sessionGeneration,
        nativeHandleGeneration: mutePlayer.eventBridge.currentNativeHandleGeneration,
        timelineRevision: mutePlayer.acceptedTimelineRevision,
        lifecycleControlEpoch: mutePlayer.eventBridge.currentLifecycleControlEpoch
      )

      #expect(!didRefreshMute)
      #expect(muteAction.invocationCount == 2)
      #expect(mutePlayer.isMuted)
      #expect(mutePlayer.intentRevisions.mute == 1)
      expectNoDifference(muteDispatches, [.mute(true)])
    }

    @Test
    func `Player control shadow does not open a hidden second mutation`() throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let probe = RearmingObservationProbe {
        _ = player.volume
      }
      probe.arm()

      try player.setAudioVolume(Volume(0.4))

      #expect(probe.invocationCount == 1)
      #expect(player.volume == 0.4)
    }

    private func observe(
      _ read: () -> some Any,
      reenter action: @escaping @MainActor () -> Void
    ) -> SingleReentrantControlAction {
      let probe = SingleReentrantControlAction(action: action)
      withObservationTracking {
        _ = read()
      } onChange: { [weak probe] in
        MainActor.assumeIsolated {
          probe?.run()
        }
      }
      return probe
    }

    private static func track(
      id: String,
      type: TrackType,
      isSelected: Bool = false
    ) -> Track {
      Track(
        id: id,
        type: type,
        name: id,
        codec: 0,
        language: nil,
        trackDescription: nil,
        isSelected: isSelected,
        bitrate: 0,
        channels: nil,
        sampleRate: nil,
        width: nil,
        height: nil,
        frameRate: nil,
        frameRateRatio: nil,
        encoding: nil
      )
    }
  }
}
