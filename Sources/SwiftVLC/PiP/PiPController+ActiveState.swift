#if os(iOS) || os(macOS)
import CoreMedia

extension PiPController {
  /// Whether the identified controller is the one currently installed.
  ///
  /// Every AVKit signal reaches the main actor through a hop, so a controller
  /// replaced in the meantime can still deliver. Its state describes a session
  /// that is over.
  ///
  /// Takes an `ObjectIdentifier` rather than the controller itself:
  /// `AVPictureInPictureController` is not `Sendable`, so it cannot cross the
  /// hop, while its identity can.
  ///
  /// `nil` never matches. With no controller installed there is nothing for a
  /// callback to be current with respect to.
  func isCurrentAVController(_ identity: ObjectIdentifier) -> Bool {
    pipController.map(ObjectIdentifier.init) == identity
  }

  /// Routes AVKit's PiP render size into the conversion target.
  ///
  /// iOS previously discarded this, so a PiP resize changed no work at all
  /// while macOS already honoured it — issue 93 criterion 2. There was no
  /// recorded reason for the asymmetry; it came in with a macOS-only change.
  ///
  /// `nativeBackend != nil` is still excluded: on that path libVLC owns the
  /// vout and the sample-buffer renderer is not what feeds the PiP window, so
  /// setting a render size would resize a surface nothing displays.
  func handleRenderSizeTransition(_ size: CMVideoDimensions) {
    #if os(iOS)
    guard nativeBackend == nil else { return }
    #endif
    _ = renderer.setRenderSize(size)
  }
}
#endif
