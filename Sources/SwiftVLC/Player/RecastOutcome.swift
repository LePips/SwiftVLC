/// The result of ``Player/recastAndWaitForOutcome(to:)``, describing whether
/// the replacement session actually settled.
///
/// Recasting an active session tears it down and starts a replacement on a
/// different renderer, then restores the previous position, track selection,
/// and paused state. An unused or dormant handle only stages configuration and
/// does not autoplay. Every active-session step can fail to complete: the new
/// session may never reach playback, it may fail asynchronously, the caller's
/// task may be cancelled mid-restore, or another recast or media load may take
/// over. Returning `Void` made all of those indistinguishable from a clean
/// hand-off.
///
/// Only ``settled`` means the recast ran to completion. It does not promise
/// that every piece of carried-over state was reapplied — restoration is
/// best-effort by design, and the cases where it is skipped are documented on
/// ``settled`` and on ``Player/recastAndWaitForOutcome(to:)``.
public enum RecastOutcome: Sendable, Equatable {
  /// The requested recast work completed. For an active session, the renderer
  /// change is in effect, replacement playback was reached, and its paused
  /// state was honoured. For an inactive used handle or media awaiting a fresh
  /// handle, the configuration is durably staged for the next explicit
  /// `play()`; no transport is started and remote output is not yet claimed.
  ///
  /// Position and track restoration are **best-effort**, so this is also
  /// returned when they could not be applied:
  ///
  /// - A player that had never started playback is a plain renderer change
  ///   with no session to rebuild, so nothing needs restoring.
  /// - Media already committed for a deferred fresh handle only updates the
  ///   renderer configuration for that successor. A previously used idle,
  ///   stopped, or failed handle stages the renderer and waits for the next
  ///   explicit `play()` to create its fresh handle; neither path autoplays.
  /// - A session that never reports seekability — live streams never do —
  ///   keeps its restart position instead of resuming the prior one.
  /// - Tracks that never appear stay at the new session's defaults; ids are
  ///   session-scoped, and metadata fallback is applied only when it identifies
  ///   one unique language/name candidate. Ambiguous matches are not guessed.
  /// - A newer same-session seek, track selection, or pause/resume command
  ///   wins over captured state and that stale field is not restored.
  ///
  /// What ``settled`` does rule out is the session having failed, never
  /// arrived, been abandoned, or been taken over.
  case settled

  /// The replacement session reported a native error instead of settling.
  /// The renderer change has already taken effect; the old session is gone.
  case failed

  /// The replacement session never reached playback within the defensive
  /// ceiling. It may still be opening.
  case timedOut

  /// The awaiting task was cancelled. No further media, seek, track,
  /// renderer or transport request is started by recast after that point.
  /// A native seek already accepted before cancellation is not cancelled or
  /// reclassified; it keeps draining to its ordinary terminal outcome.
  case cancelled

  /// Another recast, media generation, native callback-lane generation, or
  /// terminal boundary took ownership, so this recast stopped touching the
  /// session. Native failure is reported as ``failed`` and cancellation as
  /// ``cancelled``; natural end, requested stop, replacement, and an otherwise
  /// unattributed native stop are superseding boundaries. This is also returned
  /// without starting replacement whenever a ``MediaListPlayer`` owns the
  /// shared native handle; libVLC cannot atomically replace one exact list item.
  case superseded

  /// Whether the recast ran to completion.
  ///
  /// `true` only for ``settled`` — see that case for what completion does and
  /// does not guarantee. Prefer this to comparing against individual failure
  /// cases so a future outcome cannot silently read as success.
  public var isSettled: Bool {
    self == .settled
  }
}
