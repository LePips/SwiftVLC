/// An effective playback-rate resolution reported by libVLC.
///
/// A successful ``Player/setPlaybackRate(_:)`` call means only that libVLC
/// accepted the command. The active input resolves that request
/// asynchronously and can substitute another rate. Values on
/// ``Player/effectivePlaybackRateResolutions`` report that effective control
/// state; they are not measurements of decoded or presented throughput and do
/// not identify the request that caused them.
///
/// The generations are captured when the native callback enters SwiftVLC.
/// Consumers that queue work should compare both values with
/// ``Player/nativeEventGeneration`` and ``Player/generation`` before applying
/// it. This rejects a callback from a retired native handle or superseded
/// media session even if delivery was delayed.
public struct EffectivePlaybackRateResolution: Hashable, Sendable {
  /// The unclamped effective control rate reported by libVLC.
  public let effectiveRate: Float

  /// The concrete native player handle that reported ``effectiveRate``.
  public let nativeGeneration: NativePlayerGeneration

  /// The media session that reported ``effectiveRate``.
  public let playbackGeneration: PlaybackGeneration
}

extension Player {
  /// Lossless stream of effective playback-rate resolutions from libVLC.
  ///
  /// Each subscription is independent and receives resolutions emitted after
  /// it is created. Delivery is unbounded because each value is a native
  /// control resolution and rapid values remain ordered; clock telemetry does
  /// not share this buffer.
  ///
  /// A value is not a completion for one specific
  /// ``setPlaybackRate(_:)`` call: libVLC supplies no request identifier. A
  /// queued active-input request is silent when its resolved value is
  /// unchanged, while an idle or failed-queue notification may repeat the
  /// current value. Check ``supportsEffectivePlaybackRateEvents`` before
  /// depending on native delivery.
  public nonisolated var effectivePlaybackRateResolutions:
    AsyncStream<EffectivePlaybackRateResolution> {
    eventBridge.makeEffectivePlaybackRateResolutionStream()
  }
}
