@testable import SwiftVLC
import CLibVLC
import Testing

/// The xcframework ships headers from `Sources/CLibVLC/include`, **not** from
/// the patched VLC source tree — `build-libvlc.sh` passes that directory to
/// `xcodebuild -create-xcframework -headers`.
///
/// So an engine patch that changes a public libVLC header has to change the
/// vendored copy too, or the change reaches the compiled library and never
/// reaches consumers. Patch 0015 did exactly that: the built `libvlc.a`
/// populated `media_player_media_stopping.reason`, while every shipped header
/// still declared a struct without the field, leaving it invisible to Swift.
///
/// Nothing caught it. The patch applied, the engine compiled, and a runtime
/// probe passed — because the probe compiled against the VLC source headers
/// (`-I .build-libvlc/vlc/include`) rather than the ones actually shipped.
///
/// These tests reference the symbols through `CLibVLC`, so they fail to
/// compile if the vendored header loses them.
@Suite(.tags(.logic))
struct VendoredHeaderParityTests {
  /// Values must match `vlc_player_media_stopping_reason` in the engine, which
  /// `lib/media_player.c` static_asserts. Pinning them here means a divergence
  /// introduced on the vendored side alone still fails.
  @Test
  func `The stopping-reason enum is declared with upstream's values`() {
    #expect(libvlc_stopping_reason_error.rawValue == 0)
    #expect(libvlc_stopping_reason_eos.rawValue == 1)
    #expect(libvlc_stopping_reason_user.rawValue == 2)
  }

  /// The field the whole patch exists to deliver. Without it in the vendored
  /// header this does not compile, which is the point.
  @Test
  func `The media-stopping event carries a reason Swift can read`() {
    var event = libvlc_event_t()
    event.u.media_player_media_stopping.reason = libvlc_stopping_reason_eos
    #expect(event.u.media_player_media_stopping.reason == libvlc_stopping_reason_eos)

    event.u.media_player_media_stopping.reason = libvlc_stopping_reason_user
    #expect(event.u.media_player_media_stopping.reason == libvlc_stopping_reason_user)
  }

  /// Patch 0020 extends the existing encountered-error event rather than
  /// creating a wrapper-only guess. Referencing every value and the union
  /// field here keeps the shipped header aligned with that engine ABI.
  @Test
  func `The encountered-error event carries a playback failure kind`() {
    #expect(libvlc_playback_failure_unknown.rawValue == 0)
    #expect(libvlc_playback_failure_source.rawValue == 1)
    #expect(libvlc_playback_failure_demux.rawValue == 2)
    #expect(libvlc_playback_failure_decoder.rawValue == 3)
    #expect(libvlc_playback_failure_renderer.rawValue == 4)
    #expect(libvlc_playback_failure_output.rawValue == 5)

    var event = libvlc_event_t()
    event.u.media_player_encountered_error.failure = libvlc_playback_failure_renderer
    #expect(
      event.u.media_player_encountered_error.failure == libvlc_playback_failure_renderer
    )
  }

  /// Extension version 2 expands the retained-media snapshot that native PiP
  /// reads. Referencing the added fields keeps the engine and shipped headers
  /// from silently diverging at this ABI boundary.
  @Test
  func `The playback snapshot carries time and seekability`() {
    var snapshot = swiftvlc_media_player_media_length_snapshot_t()
    snapshot.length = 2000
    snapshot.time = 750
    snapshot.seekable = true

    #expect(snapshot.length == 2000)
    #expect(snapshot.time == 750)
    #expect(snapshot.seekable)
  }
}
