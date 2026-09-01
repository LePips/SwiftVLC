/// Typed-value accessors that expose `Player`'s raw `Double`/`Float`
/// observations as `PlaybackPosition`, `Volume`, `PlaybackRate`, and
/// `SubtitleScale`. Mutations go through explicit methods so libVLC
/// rejection and invalid state are not silently discarded by property
/// writes.
///
/// ```swift
/// try player.seek(to: .end)
/// try player.setAudioVolume(.muted)
/// try player.setPlaybackRate(.double)
/// ```
extension Player {
  /// Fractional playback position, clamped to `0.0 ... 1.0`.
  ///
  /// Use ``seek(to:fast:)-(PlaybackPosition,_)`` to change the position with validation.
  public var playbackPosition: PlaybackPosition {
    PlaybackPosition(position)
  }

  /// Audio output volume, clamped to `0.0 ... 2.0`.
  ///
  /// Use ``setAudioVolume(_:)`` to change volume.
  public var audioVolume: Volume {
    Volume(volume)
  }

  /// Playback rate, clamped to `0.25 ... 4.0`.
  ///
  /// Use ``setPlaybackRate(_:)`` to request a new rate.
  public var playbackRate: PlaybackRate {
    PlaybackRate(rate)
  }

  /// Subtitle text scale, clamped to `0.1 ... 5.0`.
  ///
  /// Use ``setSubtitleScale(_:)`` to change scale.
  public var subtitleScale: SubtitleScale {
    SubtitleScale(subtitleTextScale)
  }

  /// Submits a typed playback-rate request.
  ///
  /// A successful return means libVLC accepted the command into its control
  /// path, not that the active input ultimately applied it. Unsupported media
  /// can asynchronously fall back to another ``Player/rate``. Observe
  /// ``PlayerEvent/rateChanged(_:)`` for effective resolutions when
  /// ``Player/supportsEffectivePlaybackRateEvents`` is true. The native event
  /// has no request identifier. An unchanged queued active-input resolution is
  /// omitted, while an idle or failed-queue notification can repeat the
  /// current value, so this method does not promise request correlation.
  public func setPlaybackRate(_ newRate: PlaybackRate) throws(VLCError) {
    try setRate(newRate)
  }
}
