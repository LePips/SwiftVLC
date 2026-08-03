#if os(iOS) || os(macOS)
/// Whether VLC subtitle, bitmap-subpicture, and on-screen-display regions are
/// included in the video delivered to Picture in Picture.
public enum PiPOverlaySupport: Hashable, Sendable {
  /// VLC composites overlays into the video buffer before AVKit receives it.
  case composited

  /// The backend delivers the decoded video plane without VLC's overlay.
  case unavailable
}

extension PiPController {
  /// Whether the selected backend includes VLC subtitles, bitmap
  /// subpictures, and OSD regions in the system PiP video.
  ///
  /// Direct ``PiPController`` rendering uses VLC's software-composited vmem
  /// frames and reports ``PiPOverlaySupport/composited``. The native drawable
  /// iOS native drawable backend currently sends AVKit the decoded video plane
  /// separately from VLC's inline overlay view and reports
  /// ``PiPOverlaySupport/unavailable``. The private macOS backend reparents the
  /// complete VLC drawable and remains ``PiPOverlaySupport/composited``.
  /// Check this value before offering overlay controls in a PiP-only UI.
  public var overlaySupport: PiPOverlaySupport {
    #if os(iOS)
    nativeBackend == nil ? .composited : .unavailable
    #else
    // The private macOS backend reparents VLC's complete drawable instead of
    // handing AVKit a video-only sample-buffer layer, so its sibling overlay
    // remains part of the presented view.
    .composited
    #endif
  }
}
#endif
