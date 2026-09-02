@testable import SwiftVLC
import CLibVLC
import Testing

/// Decision table of ``PlaybackEndCoordinator``: only the engine's explicit
/// EOS reason synthesizes `.endReached`; an unattributed stop stays unknown.
extension Logic {
  struct PlaybackEndCoordinatorTests {
    @Test
    func `Stopped with no reason remains unattributed`() {
      let coordinator = PlaybackEndCoordinator()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))
    }

    @Test
    func `End-of-stream reason synthesizes exactly once`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos, playbackGeneration: 1)
      #expect(coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))
    }

    @Test
    func `List-player suppression outranks end of stream`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.setSuppressed(true)
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos, playbackGeneration: 1)
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))

      coordinator.setSuppressed(false)
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))
    }

    @Test
    func `Handle replacement clears the outgoing reason`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos, playbackGeneration: 1)
      coordinator.clearForHandleReplacement()
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))
    }

    @Test
    func `Handle replacement consumes a natural end exactly once`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos, playbackGeneration: 1)
      #expect(
        coordinator.consumeHandleReplacementShouldSynthesizeEnd(
          playbackGeneration: 1
        )
      )
      #expect(
        !coordinator.consumeHandleReplacementShouldSynthesizeEnd(
          playbackGeneration: 1
        )
      )
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))
    }

    @Test
    func `List suppression is frozen when the stopping reason enters`() {
      let stoppedCoordinator = PlaybackEndCoordinator()
      stoppedCoordinator.setSuppressed(true)
      stoppedCoordinator.noteStoppingReason(
        libvlc_stopping_reason_eos,
        playbackGeneration: 1
      )
      stoppedCoordinator.setSuppressed(false)
      #expect(
        !stoppedCoordinator.consumeStoppedShouldSynthesizeEnd(
          playbackGeneration: 1
        )
      )

      let replacementCoordinator = PlaybackEndCoordinator()
      replacementCoordinator.setSuppressed(true)
      replacementCoordinator.noteStoppingReason(
        libvlc_stopping_reason_eos,
        playbackGeneration: 1
      )
      replacementCoordinator.setSuppressed(false)
      #expect(
        !replacementCoordinator.consumeHandleReplacementShouldSynthesizeEnd(
          playbackGeneration: 1
        )
      )
    }

    @Test
    func `A later list attachment cannot hide a direct natural end`() {
      let stoppedCoordinator = PlaybackEndCoordinator()
      stoppedCoordinator.noteStoppingReason(
        libvlc_stopping_reason_eos,
        playbackGeneration: 1
      )
      stoppedCoordinator.setSuppressed(true)
      #expect(
        stoppedCoordinator.consumeStoppedShouldSynthesizeEnd(
          playbackGeneration: 1
        )
      )

      let replacementCoordinator = PlaybackEndCoordinator()
      replacementCoordinator.noteStoppingReason(
        libvlc_stopping_reason_eos,
        playbackGeneration: 1
      )
      replacementCoordinator.setSuppressed(true)
      #expect(
        replacementCoordinator.consumeHandleReplacementShouldSynthesizeEnd(
          playbackGeneration: 1
        )
      )
    }

    @Test
    func `An unconsumed predecessor reason cannot poison a successor stop`() {
      let coordinator = PlaybackEndCoordinator()
      coordinator.noteStoppingReason(libvlc_stopping_reason_user, playbackGeneration: 1)
      coordinator.noteStoppingReason(libvlc_stopping_reason_eos, playbackGeneration: 2)

      #expect(coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 2))
      #expect(!coordinator.consumeStoppedShouldSynthesizeEnd(playbackGeneration: 1))
    }
  }
}
