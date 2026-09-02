import CLibVLC

/// A-B loop control: set, query, reset.
extension Player {
  /// Sets an A-B loop using absolute times.
  /// - Throws: ``VLCError/invalidInput(_:)`` for negative, overflowing, or
  ///   non-increasing boundaries, ``VLCError/invalidState(_:)`` while the
  ///   current media awaits its native handle, and
  ///   ``VLCError/operationFailed(_:)`` if libVLC rejects the loop.
  public func setABLoop(a: Duration, b: Duration) throws(VLCError) {
    let (aMilliseconds, bMilliseconds) = try checkedABLoopMilliseconds(a: a, b: b)
    guard nativeHandleRepresentsCurrentMedia else {
      throw .invalidState("setABLoop requires a native handle for the current media")
    }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.setABLoopTime)
    #endif
    guard libvlc_media_player_set_abloop_time(pointer, aMilliseconds, bMilliseconds) == 0 else {
      throw .operationFailed("Set A-B loop by time")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Sets an A-B loop using fractional positions (0.0...1.0).
  /// - Throws: ``VLCError/invalidInput(_:)`` for non-increasing
  ///   boundaries, ``VLCError/invalidState(_:)`` while the current media
  ///   awaits its native handle, and ``VLCError/operationFailed(_:)`` if
  ///   libVLC rejects the loop.
  public func setABLoop(aPosition: PlaybackPosition, bPosition: PlaybackPosition) throws(VLCError) {
    guard aPosition < bPosition else {
      throw .invalidInput("A-B loop requires aPosition < bPosition")
    }
    guard nativeHandleRepresentsCurrentMedia else {
      throw .invalidState("setABLoop requires a native handle for the current media")
    }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.setABLoopPosition)
    #endif
    guard libvlc_media_player_set_abloop_position(pointer, aPosition.rawValue, bPosition.rawValue) == 0 else {
      throw .operationFailed("Set A-B loop by position")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Resets (disables) the A-B loop.
  /// - Throws: ``VLCError/invalidState(_:)`` while the current media awaits
  ///   its native handle, or ``VLCError/operationFailed(_:)`` if the loop
  ///   cannot be reset.
  public func resetABLoop() throws(VLCError) {
    guard nativeHandleRepresentsCurrentMedia else {
      throw .invalidState("resetABLoop requires a native handle for the current media")
    }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.resetABLoop)
    #endif
    guard libvlc_media_player_reset_abloop(pointer) == 0 else {
      throw .operationFailed("Reset A-B loop")
    }
    withMutation(keyPath: \.abLoopState) {}
  }

  /// Current A-B loop state.
  public var abLoopState: ABLoopState {
    access(keyPath: \.abLoopState)
    guard nativeHandleRepresentsCurrentMedia else { return .none }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readABLoop)
    #endif
    var aTime: Int64 = 0
    var aPos: Double = 0
    var bTime: Int64 = 0
    var bPos: Double = 0
    let state = libvlc_media_player_get_abloop(pointer, &aTime, &aPos, &bTime, &bPos)
    return ABLoopState(from: state)
  }

  /// Shared validation seam: every returned value can safely cross the pinned
  /// VLC build's public-millisecond to internal-tick conversion.
  func checkedABLoopMilliseconds(
    a: Duration,
    b: Duration
  )
    throws(VLCError) -> (a: Int64, b: Int64) {
    let aMilliseconds = try a.checkedNonnegativeLibVLCTimeMilliseconds(parameter: "a")
    let bMilliseconds = try b.checkedNonnegativeLibVLCTimeMilliseconds(parameter: "b")
    guard aMilliseconds < bMilliseconds else {
      throw .invalidInput("A-B loop requires a < b")
    }
    return (aMilliseconds, bMilliseconds)
  }
}
