@testable import SwiftVLC
import CLibVLC
import Testing

extension Logic {
  @Suite("Renderer Event Attachment")
  struct RendererEventAttachmentTests {
    @Test
    func `partial registration rolls back only successful attachments`() {
      var attempted: [Int32] = []
      var detached: [Int32] = []

      let registered = RendererEventAttachment.attachAll(
        attach: { eventType in
          attempted.append(eventType)
          return attempted.count == 2 ? -1 : 0
        },
        detach: { detached.append($0) }
      )

      #expect(!registered)
      #expect(attempted == RendererEventAttachment.eventTypes)
      #expect(detached == [RendererEventAttachment.eventTypes[0]])
    }

    @Test
    func `first registration failure performs no detach`() {
      var detached: [Int32] = []

      let registered = RendererEventAttachment.attachAll(
        attach: { _ in -1 },
        detach: { detached.append($0) }
      )

      #expect(!registered)
      #expect(detached.isEmpty)
    }

    @Test
    func `complete registration requires no rollback`() {
      var attached: [Int32] = []
      var detached: [Int32] = []

      let registered = RendererEventAttachment.attachAll(
        attach: {
          attached.append($0)
          return 0
        },
        detach: { detached.append($0) }
      )

      #expect(registered)
      #expect(attached == RendererEventAttachment.eventTypes)
      #expect(detached.isEmpty)
    }
  }
}
