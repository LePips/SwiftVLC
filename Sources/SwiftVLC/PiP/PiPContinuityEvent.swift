#if os(iOS)
/// Progress of a native Picture-in-Picture session while libVLC rebuilds its
/// video output for a new media item on the same ``Player``.
public enum PiPContinuityOutcome: Hashable, Sendable {
  /// The active AVKit controller is being held while the successor video
  /// output prepares its first display layer.
  case rebuilding

  /// The active AVKit controller adopted the successor display layer within
  /// the documented rebuild bound.
  case restored

  /// No usable successor display layer arrived before the rebuild bound, so
  /// SwiftVLC allowed PiP to stop cleanly instead of retaining a frozen window.
  case timedOut
}

/// One attributed native PiP continuity transition.
public struct PiPContinuityEvent: Hashable, Sendable {
  /// Media identity served before the video-output rebuild.
  public let previousMediaGeneration: PlaybackGeneration

  /// Successor media identity the rebuild is attempting to serve.
  public let mediaGeneration: PlaybackGeneration

  /// Native AVKit controller identity that is being preserved.
  public let controllerGeneration: UInt64

  /// Current rebuild result.
  public let outcome: PiPContinuityOutcome

  /// Monotonic time since the rebuild began. This is zero for
  /// ``PiPContinuityOutcome/rebuilding``.
  public let elapsed: Duration
}

extension PiPController {
  /// Native same-player media-replacement progress.
  ///
  /// The stream is lossless for live subscribers and finishes when this
  /// controller deinits. Direct PiP does not rebuild a libVLC-owned AVKit
  /// controller and therefore emits no values here.
  public var pipContinuityEvents: AsyncStream<PiPContinuityEvent> {
    pipContinuityEventBroadcaster.subscribe(policy: .unbounded)
  }

  func publishPiPContinuityEvent(_ event: PiPContinuityEvent) {
    pipContinuityEventBroadcaster.broadcast(event)
  }
}
#endif
