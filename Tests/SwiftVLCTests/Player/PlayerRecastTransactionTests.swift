@testable import SwiftVLC
import CLibVLC
import Dispatch
import Observation
import Synchronization
import Testing

@_silgen_name("vlc_renderer_item_new")
private func makeNativeRecastRendererItemForTesting(
  _ type: UnsafePointer<CChar>,
  _ name: UnsafePointer<CChar>?,
  _ uri: UnsafePointer<CChar>,
  _ extraSout: UnsafePointer<CChar>?,
  _ demuxFilter: UnsafePointer<CChar>?,
  _ iconURI: UnsafePointer<CChar>?,
  _ flags: Int32
) -> OpaquePointer?

@_silgen_name("vlc_renderer_item_release")
private func releaseNativeRecastRendererItemForTesting(_ pointer: OpaquePointer)

extension Integration {
  /// Transaction-level recast coverage. These tests force the otherwise tiny
  /// callback/commit gaps directly; none depends on real decoding or a receiver.
  @Suite(.tags(.mainActor, .async), .serialized, .timeLimit(.minutes(1)))
  @MainActor struct PlayerRecastTransactionTests {
    @Test
    func `A used inactive handle stages recast without autoplay then explicit play replaces it`()
      async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(
        state: .stopped,
        nativeState: .stopped,
        isPlaybackRequestedActive: false
      )
      player.nativePlayerHasStartedPlayback = true
      let retiringPointer = player.pointer
      let stagedGeneration = player.sessionGeneration
      var rendererApplications = 0
      var playCalls = 0
      player._nativeSetRendererOverrideForTesting = { _ in
        rendererApplications += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        playCalls += 1
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .settled)
      #expect(player.pointer == retiringPointer)
      #expect(player.sessionGeneration == stagedGeneration)
      #expect(player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(rendererApplications == 0)
      #expect(playCalls == 0)

      try player.play()

      #expect(player.pointer != retiringPointer)
      #expect(player.sessionGeneration == stagedGeneration + 1)
      #expect(!player.nativePlayerNeedsReplacementBeforePlayback)
      #expect(rendererApplications == 1)
      #expect(playCalls == 1)
    }

    @Test
    func `A dormant committed successor recast is configuration only`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      player.setDrawable(NSObject())
      try player.load(Media(url: TestMedia.silenceURL))
      player.nativePlayerHasStartedPlayback = true
      player._setStateForTesting(state: .playing, nativeState: .playing)
      let retiringPointer = player.pointer
      try player.load(Media(url: TestMedia.twosecURL))
      let committedGeneration = player.sessionGeneration
      var rendererApplications = 0
      var playCalls = 0
      player._nativeSetRendererOverrideForTesting = { _ in
        rendererApplications += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        playCalls += 1
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .settled)
      #expect(player.pointer == retiringPointer)
      #expect(player.sessionGeneration == committedGeneration)
      #expect(player.nativePlayerReplacementHasCommittedMediaGeneration)
      #expect(rendererApplications == 0)
      #expect(playCalls == 0)
    }

    @Test
    func `Cancellation injected after commit prevents replacement play`() async throws {
      let player = try Self.makeActivePlayer()
      let outgoingPointer = player.pointer
      let outgoingGeneration = player.sessionGeneration
      var playCalls = 0
      player._nativePlayOverrideForTesting = {
        playCalls += 1
        return 0
      }
      player._nativePlayerReplacementWillActivateForTesting = {
        withUnsafeCurrentTask { task in
          task?.cancel()
        }
      }
      defer {
        player._nativePlayerReplacementWillActivateForTesting = nil
      }

      let operation = Task { @MainActor in
        try await player.recastAndWaitForOutcome(to: nil)
      }
      let outcome = try await operation.value

      #expect(outcome == .cancelled)
      #expect(player.pointer != outgoingPointer, "the replacement had already committed")
      #expect(player.sessionGeneration == outgoingGeneration + 1)
      #expect(playCalls == 0, "cancellation crossed no later transport boundary")
    }

    @Test
    func `A reentrant load at preactivation sees the coherent successor and supersedes recast`()
      async throws {
      let player = try Self.makeActivePlayer()
      let outgoingPointer = player.pointer
      let outgoingGeneration = player.sessionGeneration
      let takeoverMedia = try Media(url: TestMedia.silenceURL)
      var pointerAtBoundary: OpaquePointer?
      var generationAtBoundary: UInt64?
      var nativeGenerationAtBoundary: UInt64?
      var playCalls = 0
      player._nativePlayOverrideForTesting = {
        playCalls += 1
        return 0
      }
      player._nativePlayerReplacementWillActivateForTesting = {
        pointerAtBoundary = player.pointer
        generationAtBoundary = player.sessionGeneration
        nativeGenerationAtBoundary = player.eventBridge.currentNativeHandleGeneration
        player.load(takeoverMedia)
      }
      defer {
        player._nativePlayerReplacementWillActivateForTesting = nil
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .superseded)
      #expect(pointerAtBoundary != outgoingPointer)
      #expect(pointerAtBoundary == player.pointer)
      #expect(generationAtBoundary == outgoingGeneration + 1)
      #expect(nativeGenerationAtBoundary == player.eventBridge.currentNativeHandleGeneration)
      #expect(player.sessionGeneration == outgoingGeneration + 2)
      #expect(player.currentMedia === takeoverMedia)
      #expect(playCalls == 0)
    }

    @Test
    func `Active-output observation can replace successor without stale write or native reuse`()
      async throws {
      let player = try Self.makeActivePlayer()
      let predecessorRenderer = try Self.makeRendererItem(
        name: "predecessor",
        port: 8010
      )
      let requestedRenderer = try Self.makeRendererItem(
        name: "requested",
        port: 8011
      )
      player.selectedRenderer = predecessorRenderer
      player.setDrawable(NSObject())
      player.activeVideoOutputs = 1
      let outgoingPointerIdentity = UInt(bitPattern: player.pointer)
      let outgoingGeneration = player.sessionGeneration
      var observedSuccessorIdentity: UInt?
      var takeoverIdentity: UInt?
      var takeoverMRL: String?
      var observerRan = false
      var playCalls = 0
      var rendererApplications: [RendererItem?] = []
      player._nativeSetRendererOverrideForTesting = { renderer in
        rendererApplications.append(renderer)
        return 0
      }
      player._nativePlayOverrideForTesting = {
        playCalls += 1
        return 0
      }

      withObservationTracking {
        _ = player.activeVideoOutputs
      } onChange: {
        MainActor.assumeIsolated {
          guard !observerRan else { return }
          observerRan = true
          observedSuccessorIdentity = UInt(bitPattern: player.pointer)
          let takeover = try! Media(url: TestMedia.silenceURL)
          takeoverMRL = takeover.mrl
          player.load(takeover)
          try! player.play()
          takeoverIdentity = UInt(bitPattern: player.pointer)
          player.activeVideoOutputs = 7
        }
      }

      let outcome = try await player.recastAndWaitForOutcome(to: requestedRenderer)

      #expect(outcome == .superseded)
      #expect(observerRan)
      #expect(observedSuccessorIdentity != outgoingPointerIdentity)
      #expect(takeoverIdentity != observedSuccessorIdentity)
      #expect(UInt(bitPattern: player.pointer) == takeoverIdentity)
      #expect(player.sessionGeneration == outgoingGeneration + 2)
      #expect(player.currentMedia?.mrl == takeoverMRL)
      #expect(player.activeVideoOutputs == 7)
      #expect(playCalls == 1, "only the observer-owned successor may start")
      #expect(rendererApplications.count == 2)
      #expect(
        rendererApplications.allSatisfy { $0 === requestedRenderer },
        "the observer-owned successor must inherit the committed recast target"
      )
      #expect(player.selectedRenderer === requestedRenderer)
    }

    @Test
    func `A takeover inside throwing replacement play maps interruption instead of throwing`()
      async throws {
      let player = try Self.makeActivePlayer()
      let takeoverMedia = try Media(url: TestMedia.silenceURL)
      player._nativePlayOverrideForTesting = {
        _ = player.eventBridge._noteExternalMediaChangedForTesting(
          takeoverMedia.pointer
        )
        return -1
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .superseded)
      #expect(
        player.eventBridge.currentPlaybackGeneration == player.sessionGeneration + 1,
        "the callback-lane takeover, not the failed recast play, owns the generation"
      )
    }

    @Test
    func `Failure reserved during replacement play is failed and blocks restore`() async throws {
      let player = try Self.makeActivePlayer(currentTime: .seconds(5))
      var seekCalls = 0
      player._nativeSetTimeOverrideForTesting = { _, _ in
        seekCalls += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        var event = libvlc_event_t()
        event.type = Int32(libvlc_MediaPlayerEncounteredError.rawValue)
        event.u.media_player_encountered_error.failure = libvlc_playback_failure_decoder
        player.eventBridge._emitNativeEventForTesting(event)
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .failed)
      #expect(seekCalls == 0)
    }

    @Test
    func `Natural end reserved during replacement play supersedes and blocks restore`() async throws {
      let player = try Self.makeActivePlayer(currentTime: .seconds(5))
      var seekCalls = 0
      player._nativeSetTimeOverrideForTesting = { _, _ in
        seekCalls += 1
        return 0
      }
      player._nativePlayOverrideForTesting = {
        var event = libvlc_event_t()
        event.type = Int32(libvlc_MediaPlayerMediaStopping.rawValue)
        event.u.media_player_media_stopping.media = player.currentMedia?.pointer
        event.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
        player.eventBridge._emitNativeEventForTesting(event)
        return 0
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .superseded)
      #expect(seekCalls == 0)
    }

    @Test
    func `Media-list ownership epoch records attach detach ABA`() {
      let instance = TestInstance.makeAudioOnly()
      let player = Player(instance: instance)
      let first = MediaListPlayer(instance: instance)
      let second = MediaListPlayer(instance: instance)
      let initial = player.mediaListOwnershipEpoch

      first.mediaPlayer = player
      let firstAttach = player.mediaListOwnershipEpoch
      first.mediaPlayer = nil
      let firstDetach = player.mediaListOwnershipEpoch
      second.mediaPlayer = player
      let secondAttach = player.mediaListOwnershipEpoch
      second.mediaPlayer = nil
      let secondDetach = player.mediaListOwnershipEpoch

      #expect(firstAttach == initial + 1)
      #expect(firstDetach == firstAttach + 1)
      #expect(secondAttach == firstDetach + 1)
      #expect(secondDetach == secondAttach + 1)
      #expect(player.attachedMediaListPlayer == nil)
    }

    @Test
    func `Media-list attach detach ABA during candidate setup rejects recast commit`() async throws {
      let instance = TestInstance.makeAudioOnly()
      let player = try Self.makeActivePlayer(instance: instance)
      let listPlayer = MediaListPlayer(instance: instance)
      let outgoingPointer = player.pointer
      let outgoingGeneration = player.sessionGeneration
      let outgoingOwnershipEpoch = player.mediaListOwnershipEpoch
      var playCalls = 0
      player._nativePlayOverrideForTesting = {
        playCalls += 1
        return 0
      }
      player._nativeSetRendererTargetHookForTesting = { _, _ in
        listPlayer.mediaPlayer = player
        listPlayer.mediaPlayer = nil
      }
      defer {
        player._nativeSetRendererTargetHookForTesting = nil
      }

      let outcome = try await player.recastAndWaitForOutcome(to: nil)

      #expect(outcome == .superseded)
      #expect(player.pointer == outgoingPointer)
      #expect(player.sessionGeneration == outgoingGeneration)
      #expect(player.mediaListOwnershipEpoch == outgoingOwnershipEpoch + 2)
      #expect(player.attachedMediaListPlayer == nil)
      #expect(playCalls == 0)
    }

    private static func makeActivePlayer(
      instance: VLCInstance = TestInstance.makeAudioOnly(),
      currentTime: Duration = .zero
    )
      throws -> Player {
      let player = Player(instance: instance)
      try player.load(Media(url: TestMedia.twosecURL))
      player._setStateForTesting(
        state: .playing,
        nativeState: .playing,
        isPlaybackRequestedActive: true,
        currentTime: currentTime,
        duration: .seconds(20),
        position: 0.25,
        isSeekable: true,
        isPausable: true
      )
      player.nativePlayerHasStartedPlayback = true
      return player
    }

    private static func makeRendererItem(name: String, port: Int) throws -> RendererItem {
      let nativeItem = "chromecast".withCString { type in
        name.withCString { name in
          "chromecast://127.0.0.1:\(port)".withCString { uri in
            makeNativeRecastRendererItemForTesting(
              type,
              name,
              uri,
              nil,
              nil,
              nil,
              0x0003
            )
          }
        }
      }
      guard let nativeItem else {
        throw VLCError.operationFailed("Create recast renderer fixture")
      }
      let renderer = RendererItem(retaining: nativeItem)
      releaseNativeRecastRendererItemForTesting(nativeItem)
      return renderer
    }
  }

  /// Callback-lane proofs use raw candidate handles so the test can stop at
  /// each transaction boundary without invoking Player's higher-level body.
  @Suite(.serialized, .timeLimit(.minutes(1)))
  struct EventBridgeRecastTransactionTests {
    @Test
    func `Partial candidate listener attachment rolls back before commit`() async throws {
      let setup = try await makeSetup()
      let candidate = try makeCandidate(instance: setup.instance)
      defer {
        setup.bridge.invalidate()
        libvlc_media_player_release(candidate.player)
      }
      let originalNativeGeneration = setup.bridge.currentNativeHandleGeneration
      setup.bridge._forcePreparedAttachmentFailureForTesting(afterAttachedCount: 3)

      let rejected = setup.bridge.prepareReattachment(to: candidate.eventManager)

      #expect(rejected == nil)
      #expect(setup.bridge._preparedAttachmentRollbackCountForTesting == 3)
      #expect(setup.bridge.currentNativeHandleGeneration == originalNativeGeneration)

      setup.bridge._forcePreparedAttachmentFailureForTesting(afterAttachedCount: nil)
      let retry = try #require(
        setup.bridge.prepareReattachment(to: candidate.eventManager)
      )
      setup.bridge.cancelPreparedReattachment(retry)
      setup.bridge.cancelPreparedReattachment(retry)
      #expect(setup.bridge.currentNativeHandleGeneration == originalNativeGeneration)
    }

    @Test
    func `Entered media callback supersedes conditional commit before candidate mutation`()
      async throws {
      let setup = try await makeSetup()
      let candidate = try makeCandidate(instance: setup.instance)
      defer {
        setup.bridge.invalidate()
        libvlc_media_player_release(candidate.player)
      }
      let prepared = try #require(
        setup.bridge.prepareReattachment(to: candidate.eventManager)
      )
      let expectation = makeExpectation(setup)
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)
      }
      var mediaChanged = libvlc_event_t()
      mediaChanged.type = Int32(libvlc_MediaPlayerMediaChanged.rawValue)
      mediaChanged.u.media_player_media_changed.new_media = setup.takeoverMedia.pointer
      let callback = Task.detached {
        setup.bridge._emitNativeEventForTesting(mediaChanged)
      }
      try #require(await wait(entered))

      let commit = Task.detached {
        setup.bridge.commitRecastReplacementIfCurrent(
          expectation: expectation,
          successorPlaybackGeneration: expectation.playbackGeneration + 1,
          preparedReattachment: prepared
        )
      }
      let result = await commit.value
      release.signal()
      await callback.value
      setup.bridge._setNativeEventCallbackBeforePlaybackClaimHookForTesting(nil)

      guard case .interrupted(.superseded) = result else {
        Issue.record("callback-lane media takeover did not reject recast commit")
        setup.bridge.cancelPreparedReattachment(prepared)
        return
      }
      #expect(
        setup.bridge.currentNativeHandleGeneration == expectation.nativeHandleGeneration
      )
      setup.bridge.cancelPreparedReattachment(prepared)
    }

    @Test
    func `Terminal native-order reservation wins conditional commit without lock inversion`()
      async throws {
      let setup = try await makeSetup()
      let candidate = try makeCandidate(instance: setup.instance)
      defer {
        setup.bridge.invalidate()
        libvlc_media_player_release(candidate.player)
      }
      let prepared = try #require(
        setup.bridge.prepareReattachment(to: candidate.eventManager)
      )
      let expectation = makeExpectation(setup)
      let entered = DispatchSemaphore(value: 0)
      let release = DispatchSemaphore(value: 0)
      setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting {
        entered.signal()
        _ = release.wait(timeout: .now() + 5)
      }
      defer {
        release.signal()
        setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting(nil)
      }
      var error = libvlc_event_t()
      error.type = Int32(libvlc_MediaPlayerEncounteredError.rawValue)
      error.u.media_player_encountered_error.failure = libvlc_playback_failure_decoder
      let callback = Task.detached {
        setup.bridge._emitNativeEventForTesting(error)
      }
      try #require(await wait(entered))
      let commit = Task.detached {
        setup.bridge.commitRecastReplacementIfCurrent(
          expectation: expectation,
          successorPlaybackGeneration: expectation.playbackGeneration + 1,
          preparedReattachment: prepared
        )
      }

      release.signal()
      await callback.value
      let result = await commit.value
      setup.bridge._setNativeEventCallbackAfterNativeReservationHookForTesting(nil)

      guard case .interrupted(.terminal(.failure(.decoder))) = result else {
        Issue.record("reserved failure did not defeat recast commit")
        setup.bridge.cancelPreparedReattachment(prepared)
        return
      }
      #expect(
        setup.bridge.currentNativeHandleGeneration == expectation.nativeHandleGeneration
      )
      setup.bridge.cancelPreparedReattachment(prepared)
    }

    @Test
    func `Retiring callbacks stay quarantined and candidate stays inactive until activation`()
      async throws {
      let setup = try await makeSetup()
      let bridge = setup.bridge
      let candidate = try makeCandidate(instance: setup.instance)
      defer {
        bridge.invalidate()
        libvlc_media_player_release(candidate.player)
      }
      let prepared = try #require(
        bridge.prepareReattachment(to: candidate.eventManager)
      )
      let expectation = makeExpectation(setup)
      let stream = bridge.makeSourcedStream(policy: .unbounded)
      var iterator = stream.makeAsyncIterator()

      let result = bridge.commitRecastReplacementIfCurrent(
        expectation: expectation,
        successorPlaybackGeneration: expectation.playbackGeneration + 1,
        preparedReattachment: prepared
      )
      let lease: RecastReplacementLease
      switch result {
      case .committed(let value): lease = value
      case .interrupted:
        Issue.record("expected recast commit")
        bridge.cancelPreparedReattachment(prepared)
        return
      }

      var opening = libvlc_event_t()
      opening.type = Int32(libvlc_MediaPlayerOpening.rawValue)
      bridge._emitNativeEventForTesting(opening)
      let retiring = try #require(await iterator.next())
      #expect(retiring.playbackGeneration == expectation.playbackGeneration)
      #expect(!bridge.currentNativeHandleHasStartedPlayback)

      _ = bridge.installPreparedReattachment(prepared)
      bridge._emitNativeEventForTesting(opening)
      #expect(!bridge.currentNativeHandleHasStartedPlayback)

      bridge.activatePreparedReattachment(prepared)
      bridge.cancelPreparedReattachment(prepared)
      bridge.cancelPreparedReattachment(prepared)
      bridge._emitNativeEventForTesting(opening)
      #expect(bridge.currentNativeHandleHasStartedPlayback)
      #expect(bridge.currentPlaybackGenerationHasStartedPlayback)
      bridge.abandonRecast(lease)
    }

    @Test
    func `Conditional commit returns callback-authoritative timeline not lagging mirror`()
      async throws {
      let setup = try await makeSetup()
      let bridge = setup.bridge
      let candidate = try makeCandidate(instance: setup.instance)
      defer {
        bridge.invalidate()
        libvlc_media_player_release(candidate.player)
      }
      let prepared = try #require(
        bridge.prepareReattachment(to: candidate.eventManager)
      )
      setup.monitor._noteExternalSeekStartedForTesting()
      setup.monitor._noteSeekEndedForTesting()
      setup.monitor._noteTimeUpdatedForTesting(
        timeMilliseconds: 33000,
        position: 0.33
      )
      let expectation = makeExpectation(setup)

      let result = bridge.commitRecastReplacementIfCurrent(
        expectation: expectation,
        successorPlaybackGeneration: expectation.playbackGeneration + 1,
        preparedReattachment: prepared
      )
      let lease: RecastReplacementLease
      switch result {
      case .committed(let value): lease = value
      case .interrupted:
        Issue.record("expected recast commit")
        bridge.cancelPreparedReattachment(prepared)
        return
      }

      #expect(lease.outgoingTimeline.time == .seconds(33))
      #expect(lease.outgoingTimeline.position == 0.33)
      _ = bridge.installPreparedReattachment(prepared)
      bridge.activatePreparedReattachment(prepared)
      bridge.abandonRecast(lease)
    }

    @Test
    func `Mutation permit and final settlement are exact single use`() async throws {
      let setup = try await makeSetup()
      let bridge = setup.bridge
      let candidate = try makeCandidate(instance: setup.instance)
      defer {
        bridge.invalidate()
        libvlc_media_player_release(candidate.player)
      }
      let prepared = try #require(
        bridge.prepareReattachment(to: candidate.eventManager)
      )
      let expectation = makeExpectation(setup)
      let result = bridge.commitRecastReplacementIfCurrent(
        expectation: expectation,
        successorPlaybackGeneration: expectation.playbackGeneration + 1,
        preparedReattachment: prepared
      )
      let lease: RecastReplacementLease
      switch result {
      case .committed(let value): lease = value
      case .interrupted:
        Issue.record("expected recast commit")
        bridge.cancelPreparedReattachment(prepared)
        return
      }
      _ = bridge.installPreparedReattachment(prepared)
      bridge.activatePreparedReattachment(prepared)

      let firstPermit: RecastMutationPermit
      switch bridge.reserveRecastMutation(for: lease) {
      case .permitted(let value): firstPermit = value
      case .interrupted:
        Issue.record("expected first permit")
        bridge.abandonRecast(lease)
        return
      }
      #expect(bridge.finishRecastMutation(firstPermit) == nil)
      #expect(bridge.finishRecastMutation(firstPermit) == .superseded)

      let secondPermit: RecastMutationPermit
      switch bridge.reserveRecastMutation(for: lease) {
      case .permitted(let value): secondPermit = value
      case .interrupted:
        Issue.record("expected second permit")
        bridge.abandonRecast(lease)
        return
      }
      #expect(bridge.settleRecast(lease) == .superseded)
      #expect(bridge.finishRecastMutation(secondPermit) == nil)
      #expect(bridge.settleRecast(lease) == nil)
      #expect(bridge.settleRecast(lease) == .superseded)
    }

    private typealias Setup = (
      player: Player,
      bridge: EventBridge,
      monitor: NativeSeekMonitor,
      instance: VLCInstance,
      media: Media,
      takeoverMedia: Media,
      ownershipEpoch: UInt64
    )

    private func makeSetup() async throws -> Setup {
      try await MainActor.run {
        let instance = TestInstance.makeAudioOnly()
        let player = Player(instance: instance)
        let media = try Media(url: TestMedia.twosecURL)
        let takeoverMedia = try Media(url: TestMedia.silenceURL)
        player.load(media)
        player.eventTask?.cancel()
        return (
          player,
          player.eventBridge,
          player.nativeSeekMonitor,
          instance,
          media,
          takeoverMedia,
          player.mediaListOwnershipEpoch
        )
      }
    }

    private func makeExpectation(_ setup: Setup) -> RecastReplacementExpectation {
      RecastReplacementExpectation(
        playbackGeneration: setup.bridge.currentPlaybackGeneration,
        nativeHandleGeneration: setup.bridge.currentNativeHandleGeneration,
        lifecycleControlEpoch: setup.bridge.currentLifecycleControlEpoch,
        mediaIdentity: UInt(bitPattern: setup.media.pointer),
        ownershipEpoch: setup.ownershipEpoch
      )
    }

    private func makeCandidate(instance: VLCInstance) throws -> (
      player: OpaquePointer,
      eventManager: OpaquePointer
    ) {
      let player = try #require(libvlc_media_player_new(instance.pointer))
      let eventManager = try #require(libvlc_media_player_event_manager(player))
      return (player, eventManager)
    }

    private func wait(_ semaphore: DispatchSemaphore) async -> Bool {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(
            returning: semaphore.wait(timeout: .now() + 5) == .success
          )
        }
      }
    }
  }
}
