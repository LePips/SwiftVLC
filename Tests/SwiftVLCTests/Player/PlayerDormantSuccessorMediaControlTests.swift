@testable import SwiftVLC
import Foundation
import Observation
import Synchronization
import Testing

extension Integration.PlayerDormantSuccessorControlTests {
  @Test
  func `Guarded event and fallback capability writes publish their side channels`() throws {
    let player = Player(instance: TestInstance.makeAudioOnly())
    try player.load(Media(url: TestMedia.silenceURL))
    let playbackGeneration = player.sessionGeneration
    let nativeHandleGeneration = player.eventBridge.currentNativeHandleGeneration
    player._nativeLengthOverrideForTesting = 33000
    player._nativeSeekableOverrideForTesting = true

    #expect(
      player.refreshNativeStateIfNeeded(
        ifPlaybackGeneration: playbackGeneration,
        nativeHandleGeneration: nativeHandleGeneration
      )
    )
    var snapshot = player.capabilitySnapshot.withLock { $0 }
    #expect(snapshot.playbackGeneration == PlaybackGeneration(playbackGeneration))
    #expect(snapshot.durationMilliseconds == 33000)
    #expect(snapshot.isSeekable)

    player.handleSourcedEvent(SourcedPlayerEvent(
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration,
      event: .lengthChanged(.seconds(44))
    ))
    player.handleSourcedEvent(SourcedPlayerEvent(
      nativeHandleGeneration: nativeHandleGeneration,
      playbackGeneration: playbackGeneration,
      event: .seekableChanged(false)
    ))

    snapshot = player.capabilitySnapshot.withLock { $0 }
    #expect(snapshot.playbackGeneration == PlaybackGeneration(playbackGeneration))
    #expect(snapshot.durationMilliseconds == 44000)
    #expect(!snapshot.isSeekable)
  }

  @Test
  func `Chapter and title mutation revalidate after synchronous observation callbacks`() throws {
    let chapterPlayer = try makeActiveDrawablePlayer(nativeState: .paused)
    var chapterDispatches: [Player.MediaSpecificNativeDispatch] = []
    var chapterObserverRan = false
    chapterPlayer._mediaSpecificNativeDispatchHookForTesting = {
      chapterDispatches.append($0)
    }
    withObservationTracking {
      _ = chapterPlayer.currentChapter
    } onChange: {
      MainActor.assumeIsolated {
        guard !chapterObserverRan else { return }
        chapterObserverRan = true
        chapterPlayer.load(try! Media(url: TestMedia.twosecURL))
      }
    }
    chapterDispatches.removeAll()
    chapterPlayer.currentChapter = 1

    let titlePlayer = try makeActiveDrawablePlayer(nativeState: .paused)
    var titleDispatches: [Player.MediaSpecificNativeDispatch] = []
    var titleObserverRan = false
    titlePlayer._mediaSpecificNativeDispatchHookForTesting = {
      titleDispatches.append($0)
    }
    withObservationTracking {
      _ = titlePlayer.currentTitle
    } onChange: {
      MainActor.assumeIsolated {
        guard !titleObserverRan else { return }
        titleObserverRan = true
        titlePlayer.load(try! Media(url: TestMedia.twosecURL))
      }
    }
    titleDispatches.removeAll()
    titlePlayer.currentTitle = 1

    #expect(!chapterPlayer.nativeHandleRepresentsCurrentMedia)
    #expect(!titlePlayer.nativeHandleRepresentsCurrentMedia)
    #expect(chapterObserverRan)
    #expect(titleObserverRan)
    #expect(chapterDispatches.isEmpty)
    #expect(titleDispatches.isEmpty)
  }

  @Test
  func `Sourced event stops after observation supersedes its exact identity`() throws {
    let player = try makeActiveDrawablePlayer(nativeState: .playing)
    let sourcedGeneration = player.sessionGeneration
    let sourcedNativeHandleGeneration = player.eventBridge.currentNativeHandleGeneration
    var observerRan = false
    var nativeDispatches: [Player.MediaSpecificNativeDispatch] = []
    player._mediaSpecificNativeDispatchHookForTesting = {
      nativeDispatches.append($0)
    }

    withObservationTracking {
      _ = player.activeVideoOutputs
    } onChange: {
      MainActor.assumeIsolated {
        guard !observerRan else { return }
        observerRan = true
        player.load(try! Media(url: TestMedia.twosecURL))
      }
    }

    player.handleSourcedEvent(SourcedPlayerEvent(
      nativeHandleGeneration: sourcedNativeHandleGeneration,
      playbackGeneration: sourcedGeneration,
      event: .voutChanged(3)
    ))

    #expect(observerRan)
    #expect(player.sessionGeneration == sourcedGeneration &+ 1)
    #expect(player.activeVideoOutputs == 0)
    #expect(!player.nativeHandleRepresentsCurrentMedia)
    #expect(nativeDispatches.isEmpty)
  }

  @Test
  func `Dormant successor exposes no retiring media facts or media mutations`() throws {
    let setup = try makeDormantSuccessor(nativeState: .paused)
    let player = setup.player
    let initialAudioTrackRevision = player.intentRevisions.audioTrackSelection
    let initialSubtitleTrackRevision = player.intentRevisions.subtitleTrackSelection
    var nativeDispatches: [Player.MediaSpecificNativeDispatch] = []
    player._mediaSpecificNativeDispatchHookForTesting = {
      nativeDispatches.append($0)
    }

    #expect(player.nativeHandlePlaybackState == .paused)
    #expect(player.nativePlaybackState == .idle)
    #expect(player.videoSize == nil)
    #expect(!player.hasVideoOutput)
    #expect(player.abLoopState == .none)
    #expect(player.chapterCount == 0)
    #expect(player.currentChapter == -1)
    #expect(player.titleCount == 0)
    #expect(player.currentTitle == -1)
    #expect(player.titles.isEmpty)
    #expect(player.chapters().isEmpty)
    #expect(player.programs.isEmpty)
    #expect(player.selectedProgram == nil)
    #expect(!player.isProgramScrambled)
    #expect(player.selectedAudioTrack == nil)
    #expect(player.selectedSubtitleTrack == nil)

    player.selectedAudioTrack = nil
    player.selectedSubtitleTrack = nil
    player.refreshTracks()
    player.navigate(.activate)
    player.nextChapter()
    player.previousChapter()
    player.currentChapter = 1
    player.currentTitle = 1
    player.selectProgram(id: 42)
    player.startRecording()
    player.stopRecording()

    #expect(player.intentRevisions.audioTrackSelection == initialAudioTrackRevision)
    #expect(player.intentRevisions.subtitleTrackSelection == initialSubtitleTrackRevision)
    #expect(player.audioTracks.isEmpty)
    #expect(player.videoTracks.isEmpty)
    #expect(player.subtitleTracks.isEmpty)

    #expect(
      throws: VLCError.invalidState(
        "addExternalTrack requires a native handle for the current media"
      )
    ) {
      try player.addExternalTrack(
        from: TestMedia.subtitleURL,
        type: .subtitle
      )
    }
    #expect(
      throws: VLCError.invalidState(
        "takeSnapshot requires a native handle for the current media"
      )
    ) {
      try player.takeSnapshot(
        to: URL(fileURLWithPath: NSTemporaryDirectory())
          .appendingPathComponent("swiftvlc-dormant.png")
          .path
      )
    }
    #expect(
      throws: VLCError.invalidState(
        "setABLoop requires a native handle for the current media"
      )
    ) {
      try player.setABLoop(a: .seconds(1), b: .seconds(2))
    }
    #expect(
      throws: VLCError.invalidState(
        "setABLoop requires a native handle for the current media"
      )
    ) {
      try player.setABLoop(
        aPosition: PlaybackPosition(0.1),
        bPosition: PlaybackPosition(0.2)
      )
    }
    #expect(
      throws: VLCError.invalidState(
        "resetABLoop requires a native handle for the current media"
      )
    ) {
      try player.resetABLoop()
    }
    #expect(nativeDispatches.isEmpty)
  }

  @Test
  func `Renderer and controls target the successor only after accepted play`() async throws {
    let setup = try makeDormantSuccessor(nativeState: .paused)
    let player = setup.player
    let retiringPointer = setup.retiringPointer
    let renderer = try makeRendererItem()
    let rendererIdentity = renderer.id
    var rendererApplications: [(pointer: OpaquePointer, renderer: RendererItem?)] = []
    player._nativeSetRendererTargetHookForTesting = { pointer, appliedRenderer in
      rendererApplications.append((pointer, appliedRenderer))
    }
    player._nativeSetRendererOverrideForTesting = { appliedRenderer in
      #expect(appliedRenderer === renderer)
      return 0
    }

    // Renderer is per-player configuration. It can be staged for B, but the
    // setter must not touch A even though A is still attached.
    try player.setRenderer(renderer)
    #expect(rendererApplications.isEmpty)
    #expect(player.selectedRenderer === renderer)
    #expect(player.selectedRenderer?.id == rendererIdentity)
    #expect(player.pointer == retiringPointer)

    player._nativePlayOverrideForTesting = { 0 }
    try player.play()
    #expect(rendererApplications.count == 1)
    #expect(player.pointer != retiringPointer)
    #expect(rendererApplications.first?.pointer == player.pointer)
    #expect(rendererApplications.first?.renderer === renderer)
    #expect(player.selectedRenderer === renderer)
    #expect(player.nativeHandleRepresentsCurrentMedia)

    var mediaSpecificDispatches: [Player.MediaSpecificNativeDispatch] = []
    player._mediaSpecificNativeDispatchHookForTesting = {
      mediaSpecificDispatches.append($0)
    }
    player.navigate(.activate)
    player.currentChapter = 0
    player.nextChapter()
    player.previousChapter()
    player.currentTitle = 0
    player.selectProgram(id: 42)
    player.startRecording()
    player.stopRecording()
    player.selectedAudioTrack = nil
    #expect(
      mediaSpecificDispatches == [
        .navigate,
        .setChapter,
        .nextChapter,
        .previousChapter,
        .setTitle,
        .selectProgram,
        .startRecording,
        .stopRecording,
        .unselectTrack
      ]
    )

    player._setStateForTesting(
      state: .paused,
      nativeState: .paused,
      isPlaybackRequestedActive: false,
      currentTime: .seconds(5),
      duration: .seconds(100),
      position: 0.05,
      isSeekable: true,
      isPausable: true
    )
    var seekDispatchCount = 0
    player._nativeSetPositionOverrideForTesting = { _, _ in
      seekDispatchCount += 1
      return 0
    }
    let seek = player.requestSeek(toPosition: PlaybackPosition(0.2))
    #expect(seek.initialOutcome == .pending)
    #expect(seekDispatchCount == 1)
    player._completePendingSeekForTesting(time: .seconds(20), position: 0.2)
    #expect(await seek.outcome == .settled)
    player.supersedeAllSeekWorkForCausalBoundary()
    player.resetNativeSeekMonitorForCausalBoundary()

    var frameDispatchCount = 0
    player._nativeNextFrameOverrideForTesting = { _ in
      frameDispatchCount += 1
      return .accepted
    }
    player._nativeCancelNextFrameOverrideForTesting = { _ in true }
    let frame = player.requestNextFrame()
    #expect(frame.initialOutcome == .pending)
    #expect(frameDispatchCount == 1)
    player.cancelPendingFrameSteps()
    #expect(await frame.outcome == .superseded)

    var resumeDispatchCount = 0
    player._nativeResumeCommandOverrideForTesting = {
      resumeDispatchCount += 1
    }
    #expect(player.issueResume())
    #expect(resumeDispatchCount == 1)
  }
}
