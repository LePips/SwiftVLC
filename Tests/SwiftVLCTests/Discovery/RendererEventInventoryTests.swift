@testable import SwiftVLC
import CLibVLC
import Dispatch
import Testing

@_silgen_name("vlc_renderer_item_new")
private func makeNativeRendererInventoryItemForTesting(
  _ type: UnsafePointer<CChar>,
  _ name: UnsafePointer<CChar>?,
  _ uri: UnsafePointer<CChar>,
  _ extraSout: UnsafePointer<CChar>?,
  _ demuxFilter: UnsafePointer<CChar>?,
  _ iconURI: UnsafePointer<CChar>?,
  _ flags: Int32
) -> OpaquePointer?

@_silgen_name("vlc_renderer_item_release")
private func releaseNativeRendererInventoryItemForTesting(_ pointer: OpaquePointer)

extension Logic {
  @Suite("Renderer Event Inventory", .timeLimit(.minutes(1)))
  struct RendererEventInventoryTests {
    private enum Event: Sendable, Equatable {
      case added(Int)
      case removed(Int)
    }

    @Test
    func `A native item emitted synchronously inside start reaches a later subscriber`() async throws {
      let hub = CurrentInventoryEventHub<RendererItem, UInt, RendererEvent>(
        identity: { UInt(bitPattern: UnsafeRawPointer($0.pointer)) },
        addedEvent: RendererEvent.itemAdded,
        removedEvent: RendererEvent.itemDeleted
      )
      let box = Unmanaged.passRetained(hub).toOpaque()
      defer {
        hub.terminate()
        Unmanaged<CurrentInventoryEventHub<RendererItem, UInt, RendererEvent>>
          .fromOpaque(box).release()
      }
      let nativeItem = try #require(makeRendererItem())
      defer { releaseNativeRendererInventoryItemForTesting(nativeItem) }

      // `libvlc_renderer_discoverer_start` can invoke this callback before it
      // returns. Deliberately do not obtain `hub.subscribe()` until afterwards:
      // the old transition-only broadcaster permanently lost this renderer.
      var nativeEvent = libvlc_event_t()
      nativeEvent.type = Int32(libvlc_RendererDiscovererItemAdded.rawValue)
      nativeEvent.u.renderer_discoverer_item_added.item = nativeItem
      withUnsafePointer(to: &nativeEvent) {
        rendererCallback(event: $0, opaque: box)
      }

      var iterator = hub.subscribe().makeAsyncIterator()
      let replayed = try #require(await iterator.next())
      let renderer = try #require(replayed.itemAdded)

      #expect(renderer.name == "SwiftVLC start-race fixture")
      #expect(renderer.type == "chromecast")
      #expect(hub._revisionForTesting == 1)
    }

    @Test
    func `Late subscription is one coherent current inventory revision`() async {
      let hub = makeIntegerHub()
      let existingStream = hub.subscribe()

      hub.add(1)
      hub.add(2)
      hub.remove(1)

      var existing = existingStream.makeAsyncIterator()
      #expect(await existing.next() == .added(1))
      #expect(await existing.next() == .added(2))
      #expect(await existing.next() == .removed(1))

      var late = hub.subscribe().makeAsyncIterator()
      #expect(await late.next() == .added(2))
      #expect(hub._revisionForTesting == 3)
      hub.terminate()
    }

    @Test
    func `Stopping clears replay and restart publishes only its new generation`() async {
      let hub = makeIntegerHub()
      let existingStream = hub.subscribe()
      hub.add(1)
      hub.add(2)

      hub.removeAll()

      var existing = existingStream.makeAsyncIterator()
      #expect(await existing.next() == .added(1))
      #expect(await existing.next() == .added(2))
      #expect(await existing.next() == .removed(1))
      #expect(await existing.next() == .removed(2))

      let afterStop = hub.subscribe()
      hub.add(3)
      var afterStopIterator = afterStop.makeAsyncIterator()
      #expect(await afterStopIterator.next() == .added(3))

      var afterRestart = hub.subscribe().makeAsyncIterator()
      #expect(await afterRestart.next() == .added(3))
      #expect(hub._revisionForTesting == 5)
      hub.terminate()
    }

    @Test
    func `Duplicate native callbacks do not create false inventory transitions`() async {
      let hub = makeIntegerHub()
      let stream = hub.subscribe()

      hub.add(7)
      hub.add(7)
      hub.remove(7)
      hub.remove(7)
      hub.terminate()

      var iterator = stream.makeAsyncIterator()
      #expect(await iterator.next() == .added(7))
      #expect(await iterator.next() == .removed(7))
      #expect(await iterator.next() == nil)
      #expect(hub._revisionForTesting == 2)
    }

    @Test
    func `Terminate after dequeue cannot resurrect a finished delivery`() async {
      let hub = makeIntegerHub()
      let stream = hub.subscribe()
      let deliveryWasDequeued = DispatchSemaphore(value: 0)
      let allowYield = DispatchSemaphore(value: 0)
      hub._setWillYieldHookForTesting {
        deliveryWasDequeued.signal()
        allowYield.wait()
      }

      let producer = Task.detached {
        hub.add(9)
      }
      #expect(await wait(deliveryWasDequeued))

      hub.terminate()
      allowYield.signal()
      await producer.value

      var existing = stream.makeAsyncIterator()
      #expect(await existing.next() == nil)
      var late = hub.subscribe().makeAsyncIterator()
      #expect(await late.next() == nil)
    }

    private func wait(_ semaphore: DispatchSemaphore) async -> Bool {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
          continuation.resume(
            returning: semaphore.wait(timeout: .now() + 5) == .success
          )
        }
      }
    }

    private func makeIntegerHub() -> CurrentInventoryEventHub<Int, Int, Event> {
      CurrentInventoryEventHub(
        identity: { $0 },
        addedEvent: Event.added,
        removedEvent: Event.removed
      )
    }

    private func makeRendererItem() -> OpaquePointer? {
      "chromecast".withCString { type in
        "SwiftVLC start-race fixture".withCString { name in
          "chromecast://127.0.0.1:8010".withCString { uri in
            makeNativeRendererInventoryItemForTesting(
              type,
              name,
              uri,
              nil,
              nil,
              nil,
              0x0003
            )
          }
        }
      }
    }
  }
}
