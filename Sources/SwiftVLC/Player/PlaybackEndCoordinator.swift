import CLibVLC
import Synchronization

/// Decides, on libVLC's event thread, whether a `stopped` transition is a
/// natural end-of-media.
///
/// libVLC 4 collapses natural end and requested stop into the same `Stopped`
/// event. The patched engine reports an authoritative reason just before that
/// transition; the event callback synthesizes ``PlayerEvent/endReached`` only
/// for an explicit end-of-stream reason. A stop with no reason remains unknown.
///
/// The engine reason is recorded on its event thread; list-player suppression
/// is changed by `@MainActor` attachment code. Every access goes through one
/// `Mutex`.
final class PlaybackEndCoordinator: Sendable {
  struct PendingStoppingReason {
    let reason: libvlc_stopping_reason_t
    let wasSuppressedAtEntry: Bool
  }

  private static let maximumRetainedGenerations = 33

  private struct EndState {
    /// A `MediaListPlayer` drives this handle through list-player C
    /// calls that never pass through `Player.stop()` — every
    /// list-initiated advancement would synthesize a spurious end.
    var suppressSynthesis = false
    /// Engine reasons keyed by the playback generation attributed at callback
    /// entry. Same-handle replacement can begin B before A's delayed Stopped,
    /// so a single process-wide slot lets A poison B's natural end.
    var stoppingReasons: [UInt64: PendingStoppingReason] = [:]
  }

  private let state = Mutex(EndState())

  /// Clears every pending cause. Only for the native-handle replacement
  /// path, where the old handle's `Stopped` can never be observed (the
  /// bridge is reattached first): a flag left set there would suppress
  /// the *next* genuine natural end. On the plain `load()` path the
  /// pending `Stopped` still arrives and consumes its own flags — do
  /// not clear there, or an in-flight stop's `Stopped` lands after the
  /// clear and reads as a phantom natural end of media that never
  /// played.
  func clearForHandleReplacement() {
    state.withLock { $0.stoppingReasons.removeAll() }
  }

  /// Consumes the outgoing handle's reason when event detachment proves its
  /// matching `Stopped` callback can no longer arrive.
  ///
  /// This is the replacement-boundary counterpart to
  /// ``consumeStoppedShouldSynthesizeEnd()``. It preserves natural-first
  /// semantics when EOS was authoritative before replacement, while the same
  /// list-player suppression gate prevents an item advance from masquerading
  /// as the end of the whole playlist.
  func consumeHandleReplacementShouldSynthesizeEnd(
    playbackGeneration: UInt64
  ) -> Bool {
    state.withLock { state in
      guard
        let stopping = state.stoppingReasons.removeValue(
          forKey: playbackGeneration
        )
      else { return false }
      return stopping.reason == libvlc_stopping_reason_eos
        && !stopping.wasSuppressedAtEntry
    }
  }

  /// Flips list-player suppression. Set while a `MediaListPlayer` is
  /// attached; cleared on detach.
  func setSuppressed(_ suppressed: Bool) {
    state.withLock { $0.suppressSynthesis = suppressed }
  }

  /// Records the engine's own reason for the stop that is about to arrive.
  ///
  /// libVLC reports this on `MediaPlayerMediaStopping`, which precedes the
  /// `stopped` transition. It is authoritative: the player core knows whether
  /// the input reached end of stream, was stopped by request, or failed.
  func captureStoppingReason(
    _ reason: libvlc_stopping_reason_t
  ) -> PendingStoppingReason {
    state.withLock { state in
      PendingStoppingReason(
        reason: reason,
        wasSuppressedAtEntry: state.suppressSynthesis
      )
    }
  }

  /// Binds a suppression snapshot to the immutable playback generation
  /// reserved by EventBridge for the same native callback entry.
  func noteStoppingReason(
    _ stopping: PendingStoppingReason,
    playbackGeneration: UInt64
  ) {
    state.withLock { state in
      // Duplicate terminal facts for one generation preserve first-winner
      // semantics, matching EventBridge's terminal reservation.
      guard state.stoppingReasons[playbackGeneration] == nil else { return }
      state.stoppingReasons[playbackGeneration] = stopping
      guard
        state.stoppingReasons.count > Self.maximumRetainedGenerations,
        let oldest = state.stoppingReasons.keys.min()
      else { return }
      state.stoppingReasons.removeValue(forKey: oldest)
    }
  }

  /// Convenience for callers that already own a stable generation boundary.
  /// Native callbacks use the split capture/bind form above so list
  /// suppression is frozen before any lifecycle lock can block.
  func noteStoppingReason(
    _ reason: libvlc_stopping_reason_t,
    playbackGeneration: UInt64
  ) {
    noteStoppingReason(
      captureStoppingReason(reason),
      playbackGeneration: playbackGeneration
    )
  }

  /// Consumes a `stopped` transition on the event thread: returns `true`
  /// when it should synthesize ``PlayerEvent/endReached``, and clears the
  /// one-shot causes either way (each `stopped` accounts for whatever
  /// preceded it).
  ///
  /// When the engine supplied a reason, it decides: only `eos` is a natural
  /// end, and `user` and `error` are not.
  ///
  /// When it supplied none, the stop remains unattributed. Absence of a known
  /// cause is not evidence of EOF, so it must never be promoted to a confirmed
  /// natural end.
  func consumeStoppedShouldSynthesizeEnd(
    playbackGeneration: UInt64
  ) -> Bool {
    state.withLock { state in
      guard
        let stopping = state.stoppingReasons.removeValue(
          forKey: playbackGeneration
        )
      else { return false }
      // Suppression is bound to MediaStopping entry. A list detaching before
      // Stopped cannot turn an item advance into a public natural end, and a
      // later list attachment cannot hide an already-authoritative direct
      // natural end.
      return stopping.reason == libvlc_stopping_reason_eos
        && !stopping.wasSuppressedAtEntry
    }
  }
}
