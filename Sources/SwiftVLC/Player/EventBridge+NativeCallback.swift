import CLibVLC
import os

private func nativeTerminalCallbackFact(
  _ event: libvlc_event_t
) -> NativeTerminalCallbackFact? {
  switch event.type {
  case Int32(libvlc_MediaPlayerMediaStopping.rawValue):
    let stopping = event.u.media_player_media_stopping
    let cause: PlaybackTerminalCause = switch stopping.reason {
    case libvlc_stopping_reason_eos: .naturalEnd
    case libvlc_stopping_reason_user: .requestedStop
    case libvlc_stopping_reason_error: .failure(.unknown)
    default: .unknownNativeStop
    }
    return .mediaStopping(
      mediaIdentity: stopping.media.map { UInt(bitPattern: $0) },
      engineCause: cause
    )
  case Int32(libvlc_MediaPlayerEncounteredError.rawValue):
    return .encounteredError(mapPlaybackFailureKind(
      event.u.media_player_encountered_error.failure
    ))
  case Int32(libvlc_MediaPlayerStopped.rawValue):
    return .stopped
  default:
    return nil
  }
}

private func nativeLifecycleCallbackFact(
  _ event: libvlc_event_t
) -> NativeLifecycleCallbackFact {
  if let terminal = nativeTerminalCallbackFact(event) {
    return .terminal(terminal)
  }
  switch event.type {
  case Int32(libvlc_MediaPlayerMediaChanged.rawValue):
    return .mediaChanged(
      mediaIdentity: event.u.media_player_media_changed.new_media.map {
        UInt(bitPattern: $0)
      }
    )
  case Int32(libvlc_MediaPlayerOpening.rawValue),
       Int32(libvlc_MediaPlayerPlaying.rawValue):
    return .currentGenerationProgress
  default:
    return .other
  }
}

/// Free function invoked on libVLC's internal event thread.
/// `AsyncStream.Continuation.yield` is documented safe from any thread.
func playerEventCallback(
  event: UnsafePointer<libvlc_event_t>?,
  opaque: UnsafeMutableRawPointer?
) {
  guard let event, let opaque else { return }

  let interval = Signposts.signposter.beginInterval("EventBridge.callback")
  defer { Signposts.signposter.endInterval("EventBridge.callback", interval) }

  let attachment = Unmanaged<EventBridgeCallbackAttachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  // Candidate replacements preattach their complete listener set while the
  // token is inactive. No successor fact may enter the shared lifecycle until
  // the old attachment is detached and the Player transaction commits.
  guard attachment.isActive else { return }
  let context = attachment.context
  // Freeze list-player suppression at the authoritative MediaStopping
  // callback-entry boundary. Pinned VLC `lib/event.c::libvlc_event_send`
  // holds this media player's event-manager mutex across the complete
  // callback, so no
  // same-handle Stopped can interleave between this coordinator write and the
  // lifecycle reservation below. This entry segment makes no native call,
  // observer delivery, or test-hook invocation that could recursively send an
  // event through that recursive native mutex. `captureNativeTimelineCallbackEntry`
  // can still block behind a wrapper lifecycle transaction, while list
  // attachment is independently mutable on the main actor. Waiting until
  // after that work would let a later detach turn a list-item EOS into a
  // public natural end, or a later attach hide a direct EOS.
  let stoppingReason: PlaybackEndCoordinator.PendingStoppingReason? = if
    event.pointee.type
    == Int32(libvlc_MediaPlayerMediaStopping.rawValue) {
    context.endCoordinator.captureStoppingReason(
      event.pointee.u.media_player_media_stopping.reason
    )
  } else {
    nil
  }
  let lifecycleFact = nativeLifecycleCallbackFact(event.pointee)
  // Reserve native order, playback ownership, authoritative cause, and the
  // complete timeline before any competing generation finalizer can proceed.
  let callbackTimelineEntry = context.captureNativeTimelineCallbackEntry(
    lifecycleFact: lifecycleFact,
    nativeHandleGeneration: attachment.nativeHandleGeneration
  )
  let nativeTimelineEntry = callbackTimelineEntry.native
  let nativeSeekEmissionStamp = nativeTimelineEntry.seekStamp
  let emittedTimelineRevision = callbackTimelineEntry.timelineRevision
  // External MediaChanged can finish an outgoing generation at callback
  // entry. Publish its frozen outcome immediately after releasing every lock,
  // before any later generation finalizer can overtake it.
  context.publishLifecycleOutcome(callbackTimelineEntry.lifecycleOutcome)
  #if DEBUG
  context.invokeNativeEventCallbackBeforePlaybackClaimHookForTesting()
  #endif
  let callbackEntryPlaybackGeneration = callbackTimelineEntry.playbackGeneration
  if let stoppingReason {
    context.endCoordinator.noteStoppingReason(
      stoppingReason,
      playbackGeneration: callbackEntryPlaybackGeneration
    )
  }
  let terminalTimelineSnapshot = callbackTimelineEntry
    .terminalReservation?.timelineSnapshot
    ?? EventBridgeCallbackContext.TimelineSnapshot()
  #if DEBUG
  context.invokeNativeEventCallbackEntryHookForTesting()
  #endif

  // Rate resolutions have their own additive stream so extending the pinned
  // native ABI does not add a case to the source-exhaustive PlayerEvent enum.
  // Attribute the payload with the same immutable callback-entry ownership as
  // every sourced event; reading mutable generations here would let a delayed
  // predecessor callback masquerade as its successor.
  if let effectiveRate = mapEffectivePlaybackRateResolution(event.pointee) {
    context.broadcastEffectivePlaybackRateResolution(
      effectiveRate,
      nativeHandleGeneration: attachment.nativeHandleGeneration,
      playbackGeneration: callbackEntryPlaybackGeneration
    )
    return
  }

  guard let mapped = mapEvent(event.pointee) else { return }
  let coordinator = context.endCoordinator
  // Record every terminal fact before exposing its raw event. Public filters
  // run synchronously on this thread and may issue player commands, so doing
  // this after broadcast lets reentrant work classify the stop without the
  // engine's authoritative cause.
  let playbackGeneration: UInt64
  let shouldSynthesizeEnd: Bool
  switch mapped {
  case .mediaChanged:
    playbackGeneration = callbackEntryPlaybackGeneration
    shouldSynthesizeEnd = false

  case .mediaStopping:
    let stopping = event.pointee.u.media_player_media_stopping
    playbackGeneration = context.noteMediaStopping(
      playbackGeneration: callbackEntryPlaybackGeneration,
      reason: stopping.reason,
      nativeHandleGeneration: attachment.nativeHandleGeneration,
      terminalTimelineSnapshot: terminalTimelineSnapshot
    )
    shouldSynthesizeEnd = false

  case .encounteredError:
    playbackGeneration = context.noteEncounteredError(
      mapPlaybackFailureKind(
        event.pointee.u.media_player_encountered_error.failure
      ),
      playbackGeneration: callbackEntryPlaybackGeneration,
      nativeHandleGeneration: attachment.nativeHandleGeneration,
      terminalTimelineSnapshot: terminalTimelineSnapshot
    )
    shouldSynthesizeEnd = false

  case .stateChanged(.stopped):
    let stopped = context.noteStopped(
      playbackGeneration: callbackEntryPlaybackGeneration,
      nativeHandleGeneration: attachment.nativeHandleGeneration,
      terminalTimelineSnapshot: terminalTimelineSnapshot
    )
    playbackGeneration = stopped.playbackGeneration
    // The reason coordinator is intentionally generation-blind, so its EOS
    // bit alone cannot distinguish a late retiring-handle callback from the
    // already-committed replacement. Require the callback-entry generation's
    // immutable terminal outcome too. A natural-end reservation that entered
    // before replacement freezes `.naturalEnd`; an EOS arriving afterwards
    // sees the already-frozen `.replacement` and cannot fabricate endReached.
    let coordinatorConfirmedEnd = coordinator.consumeStoppedShouldSynthesizeEnd(
      playbackGeneration: playbackGeneration
    )
    shouldSynthesizeEnd = coordinatorConfirmedEnd
      && stopped.consumedNaturalEndEmission
      && context.terminalCause(for: playbackGeneration) == .naturalEnd

  default:
    playbackGeneration = callbackEntryPlaybackGeneration
    shouldSynthesizeEnd = false
  }

  // On the normal callback path, both emissions use the same immutable
  // attachment token. Every subscriber therefore observes `.stopped` then
  // `.endReached` with one generation, independent of consumer lag or native
  // pointer reuse. EventBridge's documented replacement-boundary path handles
  // the sole case where detachment makes this Stopped unobservable.
  context.broadcast(
    mapped,
    nativeHandleGeneration: attachment.nativeHandleGeneration,
    playbackGeneration: playbackGeneration,
    emittedTimelineRevision: emittedTimelineRevision,
    nativeSeekEmissionStamp: nativeSeekEmissionStamp,
    lifecycleControlEpoch: callbackTimelineEntry.lifecycleControlEpoch
  )
  if shouldSynthesizeEnd {
    context.broadcast(
      .endReached,
      nativeHandleGeneration: attachment.nativeHandleGeneration,
      playbackGeneration: playbackGeneration,
      emittedTimelineRevision: emittedTimelineRevision,
      nativeSeekEmissionStamp: nativeSeekEmissionStamp,
      lifecycleControlEpoch: callbackTimelineEntry.lifecycleControlEpoch
    )
  }
}
