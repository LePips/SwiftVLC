import CLibVLC
import Foundation

extension Player {
  // MARK: - External Tracks

  /// Adds an external subtitle or audio file to the player.
  ///
  /// - Parameters:
  ///   - url: URL of the external track file (must use a valid scheme like `file://`).
  ///   - type: Whether this is a subtitle or audio track.
  ///   - select: If `true`, the track is selected immediately when loaded.
  /// - Throws: ``VLCError/invalidState(_:)`` if the current media is awaiting
  ///   its native handle, or ``VLCError/operationFailed(_:)`` if the track
  ///   cannot be added.
  public func addExternalTrack(from url: URL, type: MediaSlaveType, select: Bool = true) throws(VLCError) {
    guard nativeHandleRepresentsCurrentMedia else {
      throw .invalidState("addExternalTrack requires a native handle for the current media")
    }
    let uri = url.absoluteString
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.addExternalTrack)
    #endif
    guard libvlc_media_player_add_slave(pointer, type.cValue, uri, select) == 0 else {
      throw .operationFailed("Add external \(type) track")
    }
    guard select else { return }
    switch type {
    case .audio:
      intentRevisions.audioTrackSelection &+= 1
    case .subtitle:
      intentRevisions.subtitleTrackSelection &+= 1
    }
  }

  // MARK: - Track Selection

  func selectTrack(_ track: Track?, type: TrackType, on pointer: OpaquePointer) {
    guard nativeHandleRepresentsCurrentMedia else { return }
    if let track {
      guard let cTrack = libvlc_media_player_get_track_from_id(pointer, track.id) else {
        return
      }
      #if DEBUG
      recordObservableControlNativeDispatch(
        type == .audio ? .audioTrack(track.id) : .subtitleTrack(track.id),
        pointer: pointer
      )
      _mediaSpecificNativeDispatchHookForTesting?(.selectTrack)
      #endif
      libvlc_media_player_select_track(pointer, cTrack)
      libvlc_media_track_release(cTrack)
    } else {
      #if DEBUG
      recordObservableControlNativeDispatch(
        type == .audio ? .audioTrack(nil) : .subtitleTrack(nil),
        pointer: pointer
      )
      _mediaSpecificNativeDispatchHookForTesting?(.unselectTrack)
      #endif
      libvlc_media_player_unselect_track_type(pointer, type.cValue)
    }
    // No eager refresh here. libVLC emits `ESSelected` / `ESUpdated`
    // once the new selection settles (typically <10ms), and the event
    // handler's `refreshTracks()` is the single source of truth. An
    // eager refresh would race libVLC's internal state and briefly
    // show stale `isSelected` flags.
  }

  // MARK: - Video

  func applyAspectRatio() {
    applyAspectRatio(_aspectRatio, to: pointer)
  }

  func applyAspectRatio(_ aspectRatio: AspectRatio, to pointer: OpaquePointer) {
    if let ratioString = aspectRatio.vlcString {
      ratioString.withCString { cstr in
        libvlc_video_set_aspect_ratio(pointer, cstr)
      }
    } else {
      libvlc_video_set_aspect_ratio(pointer, nil)
    }

    switch aspectRatio {
    case .default:
      libvlc_video_set_scale(pointer, 0) // auto
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .ratio:
      // Explicitly reset the fit mode so a prior `.fill` (cover) can't
      // override the new aspect ratio visually.
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_smaller)
    case .fill:
      libvlc_video_set_display_fit(pointer, libvlc_video_fit_larger)
    }
  }

  // MARK: - Track Refresh

  /// Refreshes all observable track lists from the native player.
  ///
  /// The track arrays are asynchronously mirrored snapshots. Receiving the payload-free
  /// ``PlayerEvent/tracksChanged-enum.case`` or ``PlayerEvent/mediaChanged-enum.case`` event does not guarantee
  /// they are updated; consumers requiring an immediate native read should call this
  /// method after either event. This also invalidates selected-track observations.
  public func refreshTracks() {
    let playbackGeneration = sessionGeneration
    let nativeHandleGeneration = eventBridge.currentNativeHandleGeneration
    let audioSelectionRevision = intentRevisions.audioTrackSelection
    let subtitleSelectionRevision = intentRevisions.subtitleTrackSelection
    _ = refreshTracks(
      ifPlaybackGeneration: playbackGeneration,
      nativeHandleGeneration: nativeHandleGeneration,
      audioSelectionRevision: audioSelectionRevision,
      subtitleSelectionRevision: subtitleSelectionRevision
    )
  }

  @discardableResult
  func refreshTracks(
    ifPlaybackGeneration expectedPlaybackGeneration: UInt64?,
    nativeHandleGeneration expectedNativeHandleGeneration: UInt64?,
    timelineRevision expectedTimelineRevision: UInt64? = nil,
    lifecycleControlEpoch expectedLifecycleControlEpoch: UInt64? = nil,
    audioSelectionRevision expectedAudioSelectionRevision: UInt64? = nil,
    subtitleSelectionRevision expectedSubtitleSelectionRevision: UInt64? = nil
  ) -> Bool {
    let audioSelectionRevision = expectedAudioSelectionRevision
      ?? intentRevisions.audioTrackSelection
    let subtitleSelectionRevision = expectedSubtitleSelectionRevision
      ?? intentRevisions.subtitleTrackSelection

    func sourceIsCurrent() -> Bool {
      if let expectedTimelineRevision {
        guard expectedTimelineRevision == acceptedTimelineRevision else { return false }
      }
      if let expectedLifecycleControlEpoch {
        guard expectedLifecycleControlEpoch == eventBridge.currentLifecycleControlEpoch else {
          return false
        }
      }
      if let expectedNativeHandleGeneration {
        guard expectedNativeHandleGeneration == eventBridge.currentNativeHandleGeneration else {
          return false
        }
      }
      guard audioSelectionRevision == intentRevisions.audioTrackSelection else {
        return false
      }
      guard subtitleSelectionRevision == intentRevisions.subtitleTrackSelection else {
        return false
      }
      guard let expectedPlaybackGeneration else { return true }
      return ownsPlaybackMutation(expectedPlaybackGeneration)
    }

    func performRefreshMutation(
      keyPath: KeyPath<Player, some Any>,
      mutation: () -> Void
    ) -> Bool {
      var didPerform = false
      withMutation(keyPath: keyPath) {
        guard sourceIsCurrent() else { return }
        mutation()
        didPerform = true
      }
      return didPerform && sourceIsCurrent()
    }

    guard sourceIsCurrent() else { return false }
    guard nativeHandleRepresentsCurrentMedia else {
      guard
        performRefreshMutation(
          keyPath: \.audioTracks,
          mutation: {
            removeAllAudioTrackStorageWithoutNestedObservation()
          }
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.videoTracks,
          mutation: {
            removeAllVideoTrackStorageWithoutNestedObservation()
          }
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.subtitleTracks,
          mutation: {
            removeAllSubtitleTrackStorageWithoutNestedObservation()
          }
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.selectedAudioTrack,
          mutation: {}
        ) else { return false }
      guard
        performRefreshMutation(
          keyPath: \.selectedSubtitleTrack,
          mutation: {}
        ) else { return false }
      return sourceIsCurrent()
    }
    let refreshedAudioTracks = fetchTracks(type: .audio)
    guard
      performRefreshMutation(
        keyPath: \.audioTracks,
        mutation: {
          storeAudioTracksWithoutNestedObservation(refreshedAudioTracks)
        }
      ) else { return false }
    let refreshedVideoTracks = fetchTracks(type: .video)
    guard
      performRefreshMutation(
        keyPath: \.videoTracks,
        mutation: {
          storeVideoTracksWithoutNestedObservation(refreshedVideoTracks)
        }
      ) else { return false }
    let refreshedSubtitleTracks = fetchTracks(type: .subtitle)
    guard
      performRefreshMutation(
        keyPath: \.subtitleTracks,
        mutation: {
          storeSubtitleTracksWithoutNestedObservation(refreshedSubtitleTracks)
        }
      ) else { return false }
    guard
      performRefreshMutation(
        keyPath: \.selectedAudioTrack,
        mutation: {}
      ) else { return false }
    guard
      performRefreshMutation(
        keyPath: \.selectedSubtitleTrack,
        mutation: {}
      ) else { return false }
    return sourceIsCurrent()
  }

  private func fetchTracks(type: TrackType) -> [Track] {
    guard nativeHandleRepresentsCurrentMedia else { return [] }
    #if DEBUG
    _mediaSpecificNativeDispatchHookForTesting?(.readTracks(type))
    #endif
    guard let tracklist = libvlc_media_player_get_tracklist(pointer, type.cValue, false) else {
      return []
    }
    defer { libvlc_media_tracklist_delete(tracklist) }

    let count = libvlc_media_tracklist_count(tracklist)
    return (0..<count).compactMap { i in
      libvlc_media_tracklist_at(tracklist, i).map { Track(from: $0) }
    }
  }
}
