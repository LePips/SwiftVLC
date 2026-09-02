import Foundation

/// Monotonic identities for user-facing control intent.
///
/// Observation invokes `onChange` before a `withMutation` body. Every native
/// control therefore advances its own identity before publishing. If that
/// callback invokes a newer command, the older body sees a different revision
/// and cannot run afterward. Recast also captures the revisions for values it
/// restores after suspension, so a newer app command remains authoritative.
struct PlayerIntentRevisions {
  var seek: UInt64 = 0
  var audioVolume: UInt64 = 0
  var mute: UInt64 = 0
  var playbackRate: UInt64 = 0
  var equalizer: UInt64 = 0
  var audioDelay: UInt64 = 0
  var subtitleDelay: UInt64 = 0
  var subtitleScale: UInt64 = 0
  var role: UInt64 = 0
  var audioTrackSelection: UInt64 = 0
  var subtitleTrackSelection: UInt64 = 0
  var aspectRatio: UInt64 = 0
  var stereoMode: UInt64 = 0
  var mixMode: UInt64 = 0
  var teletextPage: UInt64 = 0
  var chapterSelection: UInt64 = 0
  var titleSelection: UInt64 = 0
}

/// Exact authority captured before one observable native-control mutation.
///
/// A raw player address is not sufficient: malloc can reuse an address after
/// a synchronous observer replaces the native handle. The callback-lane
/// handle generation closes that ABA hole, while the playback generation
/// prevents an older media command from crossing a same-handle `load(_:)`.
struct PlayerNativeControlIdentity {
  let revision: UInt64
  let playbackGeneration: UInt64
  let nativeHandleGeneration: UInt64
  let pointer: OpaquePointer
  let requiresCurrentMediaHandle: Bool
}

#if DEBUG
extension Player {
  /// Semantic native dispatches exposed only to deterministic reentrancy
  /// tests. Recording after the identity guard proves an obsolete observable
  /// body never crossed into libVLC.
  enum ObservableControlNativeDispatch: Equatable {
    case audioVolume(Float)
    case mute(Bool)
    case playbackRate(Float)
    case equalizer(ObjectIdentifier?)
    case audioDelay(Duration)
    case subtitleDelay(Duration)
    case subtitleScale(Float)
    case role(PlayerRole)
    case audioTrack(String?)
    case subtitleTrack(String?)
    case aspectRatio(AspectRatio)
    case stereoMode(StereoMode)
    case mixMode(MixMode)
    case teletextPage(Int32)
    case teletextKey(TeletextKey)
    case chapter(Int32)
    case title(Int32)
  }

  func recordObservableControlNativeDispatch(
    _ dispatch: ObservableControlNativeDispatch,
    pointer: OpaquePointer
  ) {
    _observableControlNativeDispatchHookForTesting?(pointer, dispatch)
  }
}
#endif

extension Player {
  /// Starts one accepted control intent before Observation can call app code.
  func beginNativeControlMutation(
    revision revisionKeyPath: WritableKeyPath<PlayerIntentRevisions, UInt64>,
    requiresCurrentMediaHandle: Bool = false
  ) -> PlayerNativeControlIdentity? {
    guard !isShutdown else { return nil }
    if requiresCurrentMediaHandle {
      guard nativeHandleRepresentsCurrentMedia else { return nil }
    }
    let playbackGeneration = sessionGeneration
    let nativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    guard
      ownsPlaybackMutation(
        playbackGeneration,
        nativeHandleGeneration: nativeHandleGeneration
      ) else { return nil }

    let previousRevision = intentRevisions[keyPath: revisionKeyPath]
    precondition(previousRevision != .max, "Player control revision exhausted")
    let revision = previousRevision + 1
    intentRevisions[keyPath: revisionKeyPath] = revision
    return PlayerNativeControlIdentity(
      revision: revision,
      playbackGeneration: playbackGeneration,
      nativeHandleGeneration: nativeHandleGeneration,
      pointer: pointer,
      requiresCurrentMediaHandle: requiresCurrentMediaHandle
    )
  }

  /// Revalidates an intent after Observation's synchronous callback returns.
  func ownsNativeControlMutation(
    _ identity: PlayerNativeControlIdentity,
    revision revisionKeyPath: WritableKeyPath<PlayerIntentRevisions, UInt64>
  ) -> Bool {
    guard
      !isShutdown,
      intentRevisions[keyPath: revisionKeyPath] == identity.revision,
      pointer == identity.pointer,
      eventBridge.currentNativeHandleGeneration == identity.nativeHandleGeneration,
      ownsPlaybackMutation(
        identity.playbackGeneration,
        nativeHandleGeneration: identity.nativeHandleGeneration
      )
    else { return false }
    return !identity.requiresCurrentMediaHandle || nativeHandleRepresentsCurrentMedia
  }

  /// Opens exactly one public Observation mutation and runs its native body
  /// only while the pre-publication identity still owns the player.
  @discardableResult
  func performNativeControlMutation<Result>(
    keyPath: KeyPath<Player, some Any>,
    identity: PlayerNativeControlIdentity,
    revision revisionKeyPath: WritableKeyPath<PlayerIntentRevisions, UInt64>,
    mutation: (OpaquePointer) -> Result
  ) -> Result? {
    var result: Result?
    withMutation(keyPath: keyPath) {
      guard ownsNativeControlMutation(identity, revision: revisionKeyPath) else {
        return
      }
      result = mutation(identity.pointer)
    }
    return result
  }
}
