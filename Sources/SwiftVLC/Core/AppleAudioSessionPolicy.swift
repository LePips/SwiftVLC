/// Selects who owns Apple audio-session policy for one ``VLCInstance``.
///
/// The choice is immutable and inherited by every ``Player`` created from
/// the instance. Keeping ownership instance-scoped prevents a PiP view or
/// controller from silently choosing a different owner than libVLC's audio
/// output.
public enum AppleAudioSessionPolicy: Sendable, Equatable, Hashable {
  /// SwiftVLC and its bundled libVLC configure, activate, and recover the
  /// process audio session as playback requires.
  ///
  /// This is the default for source and behavior compatibility.
  case libraryManaged

  /// The host application configures and activates the process audio session.
  /// SwiftVLC and bundled libVLC outputs belonging to this instance do not
  /// mutate it.
  ///
  /// SwiftVLC still observes system transport-safety signals. In particular,
  /// it pauses after private-route loss and requires fresh user playback
  /// intent after a media-services reset. Those actions change the VLC
  /// transport, not the host-owned audio-session configuration; Apple requires
  /// media playback to remain stopped after a reset until the user restarts it.
  ///
  /// `AVAudioSession` is process-global even though this policy is
  /// instance-scoped. A simultaneously live `.libraryManaged` instance is
  /// still explicitly authorized to manage that shared session. Applications
  /// requiring exclusive ownership should make every live instance
  /// `.applicationManaged`.
  ///
  /// This mode requires a bundled libVLC exposing SwiftVLC's native extension
  /// version 8 or newer. ``VLCInstance`` rejects the mode on older archives
  /// instead of creating an instance whose declared ownership is not honored.
  case applicationManaged
}

extension AppleAudioSessionPolicy {
  static let libVLCOptionName = "apple-audio-session-management"
  static let requiredNativeExtensionVersion: UInt32 = 8

  var libVLCOptionValue: String {
    switch self {
    case .libraryManaged:
      "library"
    case .applicationManaged:
      "application"
    }
  }

  var managesAudioSession: Bool {
    self == .libraryManaged
  }

  func resolvingLegacyPiPOverride(
    _ requestedManagement: Bool?
  ) -> AppleAudioSessionPolicyResolution {
    let inheritedManagement = managesAudioSession
    guard
      let requestedManagement,
      requestedManagement != inheritedManagement
    else {
      return AppleAudioSessionPolicyResolution(
        managesAudioSession: inheritedManagement,
        diagnostic: nil
      )
    }

    return AppleAudioSessionPolicyResolution(
      managesAudioSession: inheritedManagement,
      diagnostic: .ignoredLegacyPiPOverride(
        requestedManagement: requestedManagement,
        inheritedPolicy: self
      )
    )
  }
}

struct AppleAudioSessionPolicyResolution: Sendable, Equatable {
  let managesAudioSession: Bool
  let diagnostic: AppleAudioSessionPolicyDiagnostic?
}

enum AppleAudioSessionPolicyDiagnostic: Sendable, Equatable {
  case ignoredLegacyPiPOverride(
    requestedManagement: Bool,
    inheritedPolicy: AppleAudioSessionPolicy
  )
}
