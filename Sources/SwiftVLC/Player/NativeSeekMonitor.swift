import CLibVLC
import Synchronization

struct NativeSeekLanding: Sendable {
  let token: UInt64
  let timeMilliseconds: Int64
  let position: Double
}

/// Correlates wrapper-issued seeks with libVLC's authoritative seek-end
/// callback. Time events alone are not causal: ordinary playback ticks can be
/// delivered on either side of the native dispatch call.
final class NativeSeekMonitor: Sendable {
  fileprivate final class Attachment: Sendable {
    let context: Context
    let timelineGeneration: UInt64

    init(context: Context, timelineGeneration: UInt64) {
      self.context = context
      self.timelineGeneration = timelineGeneration
    }
  }

  fileprivate final class Context: Sendable {
    private struct State: Sendable {
      var nextToken: UInt64 = 0
      var timelineGeneration: UInt64 = 1
      var stagedTokens: [UInt64] = []
      var activeToken: UInt64?
      var awaitingUpdateToken: UInt64?
      var handler: (@Sendable (NativeSeekLanding) -> Void)?
      var seekEndedHandler: (@Sendable (UInt64) -> Void)?
    }

    private let state = Mutex(State())

    func stageCommand() -> UInt64 {
      state.withLock { state in
        precondition(state.nextToken < UInt64.max, "Native seek token exhausted")
        state.nextToken += 1
        state.stagedTokens.append(state.nextToken)
        return state.nextToken
      }
    }

    func cancelStagedCommand(_ token: UInt64) {
      state.withLock { state in
        if let index = state.stagedTokens.firstIndex(of: token) {
          state.stagedTokens.remove(at: index)
        }
      }
    }

    func noteSeekStarted(timelineGeneration: UInt64) {
      state.withLock { state in
        guard timelineGeneration == state.timelineGeneration else { return }
        state.activeToken = state.stagedTokens.isEmpty
          ? nil
          : state.stagedTokens.removeFirst()
        state.awaitingUpdateToken = nil
      }
    }

    func noteSeekEnded(timelineGeneration: UInt64) {
      let delivery = state.withLock { state -> (UInt64, @Sendable (UInt64) -> Void)? in
        guard timelineGeneration == state.timelineGeneration else { return nil }
        guard let token = state.activeToken else {
          state.awaitingUpdateToken = nil
          return nil
        }
        state.awaitingUpdateToken = token
        state.activeToken = nil
        guard let handler = state.seekEndedHandler else { return nil }
        return (token, handler)
      }
      if let delivery {
        delivery.1(delivery.0)
      }
    }

    func noteTimeUpdated(
      timeMilliseconds: Int64,
      position: Double,
      timelineGeneration: UInt64
    ) {
      let delivery = state.withLock { state -> (NativeSeekLanding, @Sendable (NativeSeekLanding) -> Void)? in
        guard
          timelineGeneration == state.timelineGeneration,
          timeMilliseconds >= 0,
          let token = state.awaitingUpdateToken,
          let handler = state.handler
        else {
          return nil
        }
        state.awaitingUpdateToken = nil
        return (
          NativeSeekLanding(
            token: token,
            timeMilliseconds: timeMilliseconds,
            position: position
          ),
          handler
        )
      }
      if let delivery {
        delivery.1(delivery.0)
      }
    }

    func resetForTimelineReplacement() -> UInt64 {
      state.withLock { state in
        precondition(state.timelineGeneration < UInt64.max, "Native seek timeline exhausted")
        state.timelineGeneration += 1
        state.stagedTokens.removeAll(keepingCapacity: true)
        state.activeToken = nil
        state.awaitingUpdateToken = nil
        return state.timelineGeneration
      }
    }

    func currentTimelineGeneration() -> UInt64 {
      state.withLock { $0.timelineGeneration }
    }

    func setHandler(_ handler: (@Sendable (NativeSeekLanding) -> Void)?) {
      state.withLock { $0.handler = handler }
    }

    func setSeekEndedHandler(_ handler: (@Sendable (UInt64) -> Void)?) {
      state.withLock { $0.seekEndedHandler = handler }
    }
  }

  private nonisolated(unsafe) var player: OpaquePointer
  private nonisolated(unsafe) var contextOpaque: UnsafeMutableRawPointer?
  private nonisolated(unsafe) var isAttached: Bool
  private let context: Context
  private let invalidated = Mutex(false)

  init(player: OpaquePointer) {
    self.player = player
    let context = Context()
    self.context = context
    let attachment = Attachment(
      context: context,
      timelineGeneration: context.currentTimelineGeneration()
    )
    let opaque = Unmanaged.passRetained(attachment).toOpaque()
    contextOpaque = opaque
    isAttached = Self.attach(to: player, opaque: opaque) == 0
  }

  deinit {
    invalidate()
  }

  func setHandler(_ handler: @escaping @Sendable (NativeSeekLanding) -> Void) {
    context.setHandler(handler)
  }

  func setSeekEndedHandler(_ handler: @escaping @Sendable (UInt64) -> Void) {
    context.setSeekEndedHandler(handler)
  }

  func stageCommand() -> UInt64 {
    context.stageCommand()
  }

  func cancelStagedCommand(_ token: UInt64) {
    context.cancelStagedCommand(token)
  }

  func reattach(to newPlayer: OpaquePointer) {
    replaceAttachment(on: newPlayer)
  }

  func invalidate() {
    let shouldInvalidate = invalidated.withLock { invalidated in
      guard !invalidated else { return false }
      invalidated = true
      return true
    }
    guard shouldInvalidate, let contextOpaque else { return }
    context.setHandler(nil)
    context.setSeekEndedHandler(nil)
    if isAttached {
      libvlc_media_player_unwatch_time(player)
      isAttached = false
    }
    self.contextOpaque = nil
    Unmanaged<Attachment>.fromOpaque(contextOpaque).release()
  }

  func resetForTimelineReplacement() {
    replaceAttachment(on: player)
  }

  /// A watch attachment captures the media timeline it belongs to. Rotating
  /// the opaque attachment makes a callback that was already in flight before
  /// `unwatch_time` distinguishable from callbacks produced after a same-handle
  /// media replacement.
  private func replaceAttachment(on newPlayer: OpaquePointer) {
    guard !invalidated.withLock({ $0 }), let oldOpaque = contextOpaque else { return }
    if isAttached {
      libvlc_media_player_unwatch_time(player)
    }
    let timelineGeneration = context.resetForTimelineReplacement()
    Unmanaged<Attachment>.fromOpaque(oldOpaque).release()
    let attachment = Attachment(context: context, timelineGeneration: timelineGeneration)
    let newOpaque = Unmanaged.passRetained(attachment).toOpaque()
    player = newPlayer
    contextOpaque = newOpaque
    isAttached = Self.attach(to: newPlayer, opaque: newOpaque) == 0
  }

  private static func attach(to player: OpaquePointer, opaque: UnsafeMutableRawPointer) -> Int32 {
    libvlc_media_player_watch_time(
      player,
      250_000,
      nativeSeekTimeUpdate,
      nil,
      nativeSeekStateChanged,
      opaque
    )
  }

  #if DEBUG
  var _timelineGenerationForTesting: UInt64 {
    context.currentTimelineGeneration()
  }

  func _noteSeekStartedForTesting(timelineGeneration: UInt64? = nil) {
    context.noteSeekStarted(
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration()
    )
  }

  func _noteSeekEndedForTesting(timelineGeneration: UInt64? = nil) {
    context.noteSeekEnded(
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration()
    )
  }

  func _noteTimeUpdatedForTesting(
    timeMilliseconds: Int64,
    position: Double,
    timelineGeneration: UInt64? = nil
  ) {
    context.noteTimeUpdated(
      timeMilliseconds: timeMilliseconds,
      position: position,
      timelineGeneration: timelineGeneration ?? context.currentTimelineGeneration()
    )
  }
  #endif
}

private func nativeSeekTimeUpdate(
  _ point: UnsafePointer<libvlc_media_player_time_point_t>?,
  _ opaque: UnsafeMutableRawPointer?
) {
  guard let point, let opaque else { return }
  let attachment = Unmanaged<NativeSeekMonitor.Attachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  let timeMicroseconds = point.pointee.ts_us
  attachment.context.noteTimeUpdated(
    timeMilliseconds: timeMicroseconds >= 0 ? timeMicroseconds / 1000 : -1,
    position: point.pointee.position,
    timelineGeneration: attachment.timelineGeneration
  )
}

private func nativeSeekStateChanged(
  _ point: UnsafePointer<libvlc_media_player_time_point_t>?,
  _ opaque: UnsafeMutableRawPointer?
) {
  guard let opaque else { return }
  let attachment = Unmanaged<NativeSeekMonitor.Attachment>.fromOpaque(opaque)
    .takeUnretainedValue()
  if point == nil {
    attachment.context.noteSeekEnded(timelineGeneration: attachment.timelineGeneration)
  } else {
    attachment.context.noteSeekStarted(timelineGeneration: attachment.timelineGeneration)
  }
}
