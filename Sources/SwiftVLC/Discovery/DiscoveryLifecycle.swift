import Dispatch

/// Serializes libVLC discovery lifecycle calls with deferred native release.
///
/// Both media and renderer discovery can enter the same process-wide UPnP
/// implementation. Their native release functions may wait for worker threads,
/// so running a new lifecycle call while an earlier deferred release is still
/// draining can race libupnp's process-global state.
enum DiscoveryLifecycle {
  private static let queue = DispatchQueue(
    label: "swiftvlc.discovery.lifecycle",
    qos: .utility
  )

  static func sync<T>(_ operation: () throws -> T) rethrows -> T {
    try queue.sync(execute: operation)
  }

  static func async(_ operation: @escaping @Sendable () -> Void) {
    queue.async(execute: operation)
  }
}
