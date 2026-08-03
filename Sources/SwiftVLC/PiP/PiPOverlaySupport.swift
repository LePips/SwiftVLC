#if os(iOS) || os(macOS)
import CLibVLC

/// Whether VLC subtitle, bitmap-subpicture, and on-screen-display regions are
/// included in the video delivered to Picture in Picture.
public enum PiPOverlaySupport: Hashable, Sendable {
  /// VLC composites overlays into the video buffer before AVKit receives it.
  case composited

  /// The backend delivers the decoded video plane without VLC's overlay.
  /// SwiftVLC's bundled backends do not currently report this value, but the
  /// case remains available for custom or future backends.
  case unavailable
}

extension PiPController {
  /// Whether the selected backend includes VLC subtitles, bitmap
  /// subpictures, and OSD regions in the system PiP video.
  ///
  /// Direct ``PiPController`` rendering uses VLC's software-composited vmem
  /// frames. The native iOS drawable backend burns active VLC subpictures into
  /// same-format sample buffers while system PiP is presenting, and otherwise
  /// retains its zero-copy video path. The private macOS backend reparents the
  /// complete VLC drawable. All bundled backends therefore report
  /// ``PiPOverlaySupport/composited`` when the matching bundled engine is
  /// linked. A stale local engine remains detectable as ``unavailable``.
  /// Check this value before offering overlay controls in a PiP-only UI.
  public var overlaySupport: PiPOverlaySupport {
    #if os(iOS)
    return Self.resolveOverlaySupport(
      usesNativeBackend: nativeBackend != nil,
      nativeCompositionAvailable: swiftvlc_native_pip_overlay_composition_available()
    )
    #else
    .composited
    #endif
  }

  #if os(iOS)
  nonisolated static func resolveOverlaySupport(
    usesNativeBackend: Bool,
    nativeCompositionAvailable: Bool
  ) -> PiPOverlaySupport {
    usesNativeBackend && !nativeCompositionAvailable ? .unavailable : .composited
  }
  #endif
}
#endif
