import CLibVLC

/// Maps a single libVLC `libvlc_event_t` to a typed `PlayerEvent`.
///
/// Internal rather than `private` so unit tests can synthesize each
/// event variant with hand-built `libvlc_event_t` values. Most of
/// these events don't fire in a headless test environment, so full
/// switch coverage is impossible without direct invocation.
func mapEvent(_ event: libvlc_event_t) -> PlayerEvent? {
  let type = libvlc_event_e(rawValue: UInt32(event.type))

  switch type {
  case libvlc_MediaPlayerNothingSpecial:
    return .stateChanged(.idle)

  case libvlc_MediaPlayerOpening:
    return .stateChanged(.opening)

  case libvlc_MediaPlayerBuffering:
    let pct = event.u.media_player_buffering.new_cache / 100.0
    return .bufferingProgress(pct)

  case libvlc_MediaPlayerPlaying:
    return .stateChanged(.playing)

  case libvlc_MediaPlayerPaused:
    return .stateChanged(.paused)

  case libvlc_MediaPlayerStopped:
    return .stateChanged(.stopped)

  case libvlc_MediaPlayerStopping:
    return .stateChanged(.stopping)

  case libvlc_MediaPlayerEncounteredError:
    return .encounteredError

  case libvlc_MediaPlayerTimeChanged:
    let ms = event.u.media_player_time_changed.new_time
    return .timeChanged(.milliseconds(ms))

  case libvlc_MediaPlayerPositionChanged:
    let pos = event.u.media_player_position_changed.new_position
    return .positionChanged(pos)

  case libvlc_MediaPlayerSeekableChanged:
    let seekable = event.u.media_player_seekable_changed.new_seekable != 0
    return .seekableChanged(seekable)

  case libvlc_MediaPlayerPausableChanged:
    let pausable = event.u.media_player_pausable_changed.new_pausable != 0
    return .pausableChanged(pausable)

  case libvlc_MediaPlayerLengthChanged:
    let ms = event.u.media_player_length_changed.new_length
    return .lengthChanged(.milliseconds(ms))

  case libvlc_MediaPlayerVout:
    let count = event.u.media_player_vout.new_count
    return .voutChanged(Int(count))

  case libvlc_MediaPlayerESAdded,
       libvlc_MediaPlayerESDeleted,
       libvlc_MediaPlayerESSelected,
       libvlc_MediaPlayerESUpdated:
    return .tracksChanged

  case libvlc_MediaPlayerMediaChanged:
    return .mediaChanged

  case libvlc_MediaPlayerMuted:
    return .muted

  case libvlc_MediaPlayerUnmuted:
    return .unmuted

  case libvlc_MediaPlayerCorked:
    return .corked

  case libvlc_MediaPlayerUncorked:
    return .uncorked

  case libvlc_MediaPlayerAudioVolume:
    let vol = event.u.media_player_audio_volume.volume
    return .volumeChanged(vol)

  case libvlc_MediaPlayerAudioDevice:
    let device = event.u.media_player_audio_device.device.map { String(cString: $0) }
    return .audioDeviceChanged(device)

  case libvlc_MediaPlayerMediaStopping:
    return .mediaStopping

  case libvlc_MediaPlayerChapterChanged:
    let chapter = event.u.media_player_chapter_changed.new_chapter
    return .chapterChanged(Int(chapter))

  case libvlc_MediaPlayerRecordChanged:
    let recording = event.u.media_player_record_changed.recording
    let path = event.u.media_player_record_changed.recorded_file_path
      .map { String(cString: $0) }
    return .recordingChanged(isRecording: recording, filePath: path)

  case libvlc_MediaPlayerTitleListChanged:
    return .titleListChanged

  case libvlc_MediaPlayerTitleSelectionChanged:
    let index = event.u.media_player_title_selection_changed.index
    return .titleSelectionChanged(Int(index))

  case libvlc_MediaPlayerSnapshotTaken:
    let path = String(cString: event.u.media_player_snapshot_taken.psz_filename)
    return .snapshotTaken(path)

  case libvlc_MediaPlayerProgramAdded:
    let id = event.u.media_player_program_changed.i_id
    return .programAdded(Int(id))

  case libvlc_MediaPlayerProgramDeleted:
    let id = event.u.media_player_program_changed.i_id
    return .programDeleted(Int(id))

  case libvlc_MediaPlayerProgramSelected:
    let unselected = event.u.media_player_program_selection_changed.i_unselected_id
    let selected = event.u.media_player_program_selection_changed.i_selected_id
    return .programSelected(unselectedId: Int(unselected), selectedId: Int(selected))

  case libvlc_MediaPlayerProgramUpdated:
    let id = event.u.media_player_program_changed.i_id
    return .programUpdated(Int(id))

  default:
    return nil
  }
}
