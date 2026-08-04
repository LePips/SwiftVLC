#if os(iOS)

import AVKit

/// A snapshot of libVLC's private native PiP machinery on iOS.
///
/// This is intentionally SPI, not stable public API. It exists for the
/// in-repo Showcase device-validation harness, which records how the
/// pinned libVLC binary wires its PiP window controller and
/// `AVPictureInPictureController` delegate. The shape of the probed
/// surface may change with any libVLC pin, and this type may change or
/// disappear with it, outside SwiftVLC's public semantic-versioning
/// contract.
@_spi(ValidationHarness)
public struct NativePiPProbe: Sendable {
  /// Runtime class name of libVLC's PiP window controller, if one has
  /// been handed over via the PiP-ready callback.
  public let windowControllerClassName: String?

  /// Whether the window controller exposed an
  /// `AVPictureInPictureController` through its `avPipController` key.
  public let hasAVController: Bool

  /// Runtime class name of the `AVPictureInPictureController`'s
  /// original libVLC delegate, if any.
  public let avDelegateClassName: String?

  /// Whether SwiftVLC successfully installed its lifecycle-forwarding bridge
  /// in front of libVLC's delegate.
  public let hasLifecycleDelegateBridge: Bool

  /// `respondsToSelector` results for the
  /// `AVPictureInPictureControllerDelegate` callbacks, keyed by
  /// selector name. Empty when no delegate is installed.
  public let delegateResponds: [String: Bool]

  /// The native backend's current possible flag.
  public let isPossible: Bool

  /// The native backend's current active flag.
  public let isActive: Bool
}

/// The transport policy SwiftVLC most recently applied to AVKit.
///
/// This is qualification SPI rather than public API. It lets the in-repo
/// physical-device lane prove that an indefinite live input actually reached
/// AVKit as an unbounded, linear-playback timeline instead of inferring that
/// policy from a working video window.
@_spi(Qualification)
public struct PiPPlaybackQualificationSnapshot: Sendable, Equatable {
  /// Whether AVKit's skip and scrub controls are disabled for this input.
  public let requiresLinearPlayback: Bool
  /// The duration last published to AVKit, or `nil` for an unbounded range.
  public let durationMilliseconds: Int64?
  /// Whether the current input was published as seekable.
  public let isSeekable: Bool
}

extension PiPController {
  /// A snapshot of the iOS native PiP backend's private wiring, or
  /// `nil` when this controller doesn't drive the native backend (the
  /// direct sample-buffer path).
  ///
  /// This is intentionally SPI, not stable public API. It exists for
  /// the in-repo Showcase device-validation harness and may change or
  /// disappear per libVLC pin, outside SwiftVLC's public
  /// semantic-versioning contract.
  @_spi(ValidationHarness)
  public var nativeValidationProbe: NativePiPProbe? {
    nativeBackend?.makeValidationProbe()
  }

  /// A qualification-only snapshot of the playback policy sent to AVKit.
  @_spi(Qualification)
  public var playbackQualificationSnapshot: PiPPlaybackQualificationSnapshot {
    PiPPlaybackQualificationSnapshot(
      requiresLinearPlayback: nativeBackend?.requiresLinearPlayback
        ?? pipController?.requiresLinearPlayback
        ?? true,
      durationMilliseconds: playbackStateObservation.durationMilliseconds,
      isSeekable: playbackStateObservation.isSeekable
    )
  }
}

#endif
