import Synchronization

/// A revision-ordered event source whose late subscribers first receive a
/// coherent snapshot of the items that currently exist.
///
/// Transition-only streams are insufficient for discovery APIs: an upstream
/// producer can synchronously announce an item before a caller obtains the
/// stream, leaving that caller permanently unaware of the item. This hub keeps
/// the current inventory and subscriber registration behind the same lock, so
/// there is no gap between taking the snapshot and observing later changes.
///
/// Native callbacks are allowed to arrive concurrently. State mutation assigns
/// their order, and a single drainer preserves that order while still yielding
/// outside the lock (cancellation can reenter through `onTermination`).
final class CurrentInventoryEventHub<
  Item: Sendable,
  Identity: Hashable & Sendable,
  Event: Sendable
>: Sendable {
  typealias Continuation = AsyncStream<Event>.Continuation

  private struct Subscriber: Sendable {
    let continuation: Continuation
  }

  private struct Delivery: Sendable {
    let event: Event
    let subscribers: [Subscriber]
  }

  private struct State: Sendable {
    var nextSubscriberID = 0
    var revision: UInt64 = 0
    var items: [Identity: Item] = [:]
    var itemOrder: [Identity] = []
    var subscribers: [Int: Subscriber] = [:]
    var pendingDeliveries: [Delivery] = []
    var nextDeliveryIndex = 0
    var isDraining = false
    var isTerminated = false
    #if DEBUG
    var willYieldForTesting: (@Sendable () -> Void)?
    #endif
  }

  private let state = Mutex(State())
  private let identity: @Sendable (Item) -> Identity
  private let addedEvent: @Sendable (Item) -> Event
  private let removedEvent: @Sendable (Item) -> Event

  init(
    identity: @escaping @Sendable (Item) -> Identity,
    addedEvent: @escaping @Sendable (Item) -> Event,
    removedEvent: @escaping @Sendable (Item) -> Event
  ) {
    self.identity = identity
    self.addedEvent = addedEvent
    self.removedEvent = removedEvent
  }

  /// Returns an independent unbounded stream.
  ///
  /// The initial `.added` events describe one exact inventory revision. Any
  /// transition committed after that revision is then delivered exactly once.
  func subscribe() -> AsyncStream<Event> {
    let (stream, continuation) = AsyncStream<Event>.makeStream(
      bufferingPolicy: .unbounded
    )

    let subscriberID = state.withLock { state -> Int? in
      guard !state.isTerminated else { return nil }

      // This continuation is private until `subscribe()` returns. Appending
      // the snapshot while holding the state lock therefore cannot execute
      // consumer code or reenter the hub, and it prevents a later transition
      // from overtaking its own prerequisite `.added` event.
      for itemID in state.itemOrder {
        guard let item = state.items[itemID] else { continue }
        continuation.yield(addedEvent(item))
      }

      let id = state.nextSubscriberID
      state.nextSubscriberID += 1
      state.subscribers[id] = Subscriber(continuation: continuation)
      return id
    }

    guard let subscriberID else {
      continuation.finish()
      return stream
    }

    continuation.onTermination = { [weak self] _ in
      self?.unsubscribe(id: subscriberID)
    }
    return stream
  }

  /// Records an item as present and publishes its addition transition.
  func add(_ item: Item) {
    publish(item, isAddition: true)
  }

  /// Records an item as absent and publishes its removal transition.
  func remove(_ item: Item) {
    publish(item, isAddition: false)
  }

  /// Clears the current inventory and publishes removals to existing streams.
  ///
  /// libVLC discovery modules do not consistently emit item-removed callbacks
  /// when they are stopped. Clearing explicitly prevents a stopped/restarted
  /// discoverer from replaying devices owned by its retired native module.
  func removeAll() {
    let shouldDrain = state.withLock { state -> Bool in
      guard !state.isTerminated, !state.itemOrder.isEmpty else { return false }

      let subscribers = Array(state.subscribers.values)
      for itemID in state.itemOrder {
        guard let item = state.items[itemID] else { continue }
        precondition(state.revision < UInt64.max, "Inventory revision exhausted")
        state.revision += 1
        state.pendingDeliveries.append(Delivery(
          event: removedEvent(item),
          subscribers: subscribers
        ))
      }
      state.items.removeAll(keepingCapacity: true)
      state.itemOrder.removeAll(keepingCapacity: true)
      return beginDrainingIfNeeded(state: &state)
    }
    if shouldDrain {
      drain()
    }
  }

  /// Permanently closes existing and future streams and releases the inventory.
  func terminate() {
    let subscribers = state.withLock { state -> [Subscriber] in
      guard !state.isTerminated else { return [] }
      state.isTerminated = true
      let subscribers = Array(state.subscribers.values)
      state.subscribers.removeAll()
      state.items.removeAll()
      state.itemOrder.removeAll()
      state.pendingDeliveries.removeAll()
      state.nextDeliveryIndex = 0
      return subscribers
    }
    for subscriber in subscribers {
      subscriber.continuation.finish()
    }
  }

  #if DEBUG
  /// Deterministic visibility for race regressions; not part of public API.
  var _revisionForTesting: UInt64 {
    state.withLock(\.revision)
  }

  func _setWillYieldHookForTesting(_ hook: (@Sendable () -> Void)?) {
    state.withLock { $0.willYieldForTesting = hook }
  }
  #endif

  private func publish(_ item: Item, isAddition: Bool) {
    let itemID = identity(item)
    let shouldDrain = state.withLock { state -> Bool in
      guard !state.isTerminated else { return false }
      if isAddition {
        guard state.items[itemID] == nil else { return false }
      } else {
        guard state.items[itemID] != nil else { return false }
      }
      precondition(state.revision < UInt64.max, "Inventory revision exhausted")
      state.revision += 1

      if isAddition {
        state.itemOrder.append(itemID)
        state.items[itemID] = item
      } else {
        state.items.removeValue(forKey: itemID)
        state.itemOrder.removeAll { $0 == itemID }
      }

      state.pendingDeliveries.append(Delivery(
        event: isAddition ? addedEvent(item) : removedEvent(item),
        subscribers: Array(state.subscribers.values)
      ))
      return beginDrainingIfNeeded(state: &state)
    }
    if shouldDrain {
      drain()
    }
  }

  private func beginDrainingIfNeeded(state: inout State) -> Bool {
    guard !state.isDraining, state.nextDeliveryIndex < state.pendingDeliveries.count else {
      return false
    }
    state.isDraining = true
    return true
  }

  private func drain() {
    while let delivery = nextDelivery() {
      #if DEBUG
      let willYield = state.withLock(\.willYieldForTesting)
      willYield?()
      #endif
      for subscriber in delivery.subscribers {
        subscriber.continuation.yield(delivery.event)
      }
    }
  }

  private func nextDelivery() -> Delivery? {
    state.withLock { state in
      guard state.nextDeliveryIndex < state.pendingDeliveries.count else {
        state.pendingDeliveries.removeAll(keepingCapacity: true)
        state.nextDeliveryIndex = 0
        state.isDraining = false
        return nil
      }
      let delivery = state.pendingDeliveries[state.nextDeliveryIndex]
      state.nextDeliveryIndex += 1
      return delivery
    }
  }

  private func unsubscribe(id: Int) {
    _ = state.withLock { state in
      state.subscribers.removeValue(forKey: id)
    }
  }
}
