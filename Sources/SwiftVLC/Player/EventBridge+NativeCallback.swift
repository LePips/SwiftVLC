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
  let context = attachment.context
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
  let terminalTimelineSnapshot = callbackTimelineEntry
    .terminalReservation?.timelineSnapshot
    ?? EventBridgeCallbackContext.TimelineSnapshot()
  #if DEBUG
  context.invokeNativeEventCallbackEntryHookForTesting()
  #endif

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
    coordinator.noteStoppingReason(stopping.reason)
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
    playbackGeneration = context.noteStopped(
      playbackGeneration: callbackEntryPlaybackGeneration,
      nativeHandleGeneration: attachment.nativeHandleGeneration,
      terminalTimelineSnapshot: terminalTimelineSnapshot
    )
    shouldSynthesizeEnd = coordinator.consumeStoppedShouldSynthesizeEnd()

  default:
    playbackGeneration = callbackEntryPlaybackGeneration
    shouldSynthesizeEnd = false
  }

  // Both emissions are made from the same immutable attachment token. Every
  // subscriber therefore observes `.stopped` then `.endReached` with one
  // generation, independent of consumer lag or native pointer reuse.
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
