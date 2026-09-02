import Synchronization

/// Duration and seekability tagged with the media generation they describe.
///
/// ``Player`` repairs both by polling, because libVLC does not reliably emit
/// `MediaPlayerSeekableChanged` or `MediaPlayerLengthChanged`. Consumers that
/// react only to those raw events therefore miss capability the poll
/// discovered — but they cannot simply read `Player`'s observable mirror
/// either, because `Player` and its consumers process the same native event on
/// independent schedules, so the mirror can still describe the *previous*
/// media.
///
/// The generation resolves that: a reader can tell whether the values in front
/// of it belong to the media it currently believes is loaded, instead of
/// guessing from arrival order.
struct PlayerCapabilitySnapshot: Sendable, Equatable {
  /// Bumped whenever the loaded media changes.
  var generation: UInt64 = 0
  /// Exact playback session whose capability these values describe.
  ///
  /// `generation` above is useful to older state-machine tests and proves an
  /// atomic capability reset occurred, but it cannot identify a session when
  /// this observer and `Player` consume different event lanes. The playback
  /// generation can: a reader may trust a populated snapshot immediately when
  /// this identity matches the sourced event it just adopted.
  var playbackGeneration: PlaybackGeneration?
  var durationMilliseconds: Int64?
  var isSeekable = false

  /// Whether these are the conservative values a media starts at.
  ///
  /// Seeing this immediately after a media change is how a reader knows
  /// `Player` has already processed that change, rather than still holding the
  /// outgoing media's capability.
  var isReset: Bool {
    durationMilliseconds == nil && !isSeekable
  }
}

extension Player {
  /// Republishes ``duration`` and ``isSeekable`` under the current generation.
  ///
  /// A no-op while a multi-property change is in flight: publishing after each
  /// individual assignment would let a reader observe one media's duration
  /// beside another's seekability.
  func publishCapabilitySnapshot() {
    guard !isSuppressingCapabilityPublish else { return }
    let milliseconds = duration?.milliseconds
    let seekable = isSeekable
    let playbackGeneration = PlaybackGeneration(sessionGeneration)
    capabilitySnapshot.withLock { snapshot in
      snapshot.playbackGeneration = playbackGeneration
      snapshot.durationMilliseconds = milliseconds
      snapshot.isSeekable = seekable
    }
  }

  /// Carries unchanged same-media capability into a new playback episode.
  ///
  /// Cold replay advances the playback generation without replacing either the
  /// media or its native input, so its known duration and seekability remain
  /// valid. A persistent PiP observer still needs those values tagged with the
  /// new episode it adopts from event provenance. Native-handle replacements
  /// deliberately use ``advanceCapabilityGeneration()`` instead: even for the
  /// same media, the successor renderer has not proved its own capabilities.
  func retagCapabilitySnapshotForPlaybackGeneration() {
    let playbackGeneration = PlaybackGeneration(sessionGeneration)
    capabilitySnapshot.withLock { snapshot in
      snapshot.playbackGeneration = playbackGeneration
    }
  }

  /// Starts a new capability generation with the conservative values.
  ///
  /// Called from ``resetMediaDerivedState()``, so the bump and the reset are
  /// atomic from a reader's point of view: there is no window in which the new
  /// generation is visible alongside the previous media's values.
  func advanceCapabilityGeneration() {
    let playbackGeneration = PlaybackGeneration(sessionGeneration)
    capabilitySnapshot.withLock { snapshot in
      snapshot.generation &+= 1
      snapshot.playbackGeneration = playbackGeneration
      snapshot.durationMilliseconds = nil
      snapshot.isSeekable = false
    }
  }
}
