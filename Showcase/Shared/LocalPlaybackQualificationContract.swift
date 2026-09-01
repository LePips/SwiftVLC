import Foundation

enum LocalPlaybackQualificationKind: String, Codable {
  case video
  case audio
}

struct LocalPlaybackFixtureContract: Codable, Equatable {
  let id: String
  let kind: LocalPlaybackQualificationKind
  let relativePath: String
  let container: String
  let videoCodec: String?
  let audioCodec: String
  let width: Int?
  let height: Int?
  let framesPerSecond: Int?
  let sampleRate: Int
  let channels: Int

  static let videoFixtures = [
    Self(
      id: "h264-aac-mp4",
      kind: .video,
      relativePath: "local-playback/video/h264-aac.mp4",
      container: "mp4",
      videoCodec: "h264",
      audioCodec: "aac",
      width: 640,
      height: 360,
      framesPerSecond: 30,
      sampleRate: 48000,
      channels: 1
    ),
    Self(
      id: "h264-aac-matroska",
      kind: .video,
      relativePath: "local-playback/video/h264-aac.mkv",
      container: "matroska",
      videoCodec: "h264",
      audioCodec: "aac",
      width: 640,
      height: 360,
      framesPerSecond: 30,
      sampleRate: 48000,
      channels: 1
    ),
    Self(
      id: "h264-aac-fragmented-mp4",
      kind: .video,
      relativePath: "local-playback/video/h264-aac-fragmented.mp4",
      container: "mp4",
      videoCodec: "h264",
      audioCodec: "aac",
      width: 640,
      height: 360,
      framesPerSecond: 30,
      sampleRate: 48000,
      channels: 1
    ),
    Self(
      id: "vp9-opus-webm",
      kind: .video,
      relativePath: "local-playback/video/vp9-opus.webm",
      container: "webm",
      videoCodec: "vp9",
      audioCodec: "opus",
      width: 640,
      height: 360,
      framesPerSecond: 30,
      sampleRate: 48000,
      channels: 1
    ),
    Self(
      id: "mpeg2-mp2-ts",
      kind: .video,
      relativePath: "local-playback/video/mpeg2-mp2.ts",
      container: "mpegts",
      videoCodec: "mpeg2video",
      audioCodec: "mp2",
      width: 640,
      height: 360,
      framesPerSecond: 30,
      sampleRate: 48000,
      channels: 1
    )
  ]

  static let audioFixtures = [
    audio(id: "aac-m4a", path: "local-playback/audio/aac.m4a", container: "mp4", codec: "aac"),
    audio(id: "alac-m4a", path: "local-playback/audio/alac.m4a", container: "mp4", codec: "alac"),
    audio(id: "mp3", path: "local-playback/audio/mp3.mp3", container: "mp3", codec: "mp3"),
    audio(id: "flac", path: "local-playback/audio/flac.flac", container: "flac", codec: "flac"),
    audio(id: "opus-ogg", path: "local-playback/audio/opus.ogg", container: "ogg", codec: "opus"),
    audio(id: "pcm-wav", path: "local-playback/audio/pcm-s16le.wav", container: "wav", codec: "pcm_s16le")
  ]

  static let all = videoFixtures + audioFixtures

  static func fixture(id: String?) -> Self? {
    all.first { $0.id == id }
  }

  private static func audio(id: String, path: String, container: String, codec: String) -> Self {
    Self(
      id: id,
      kind: .audio,
      relativePath: path,
      container: container,
      videoCodec: nil,
      audioCodec: codec,
      width: nil,
      height: nil,
      framesPerSecond: nil,
      sampleRate: 48000,
      channels: 1
    )
  }
}

struct LocalPlaybackCounterSnapshot: Codable, Equatable {
  let timeMilliseconds: Int64
  let readBytes: UInt64
  let demuxReadBytes: UInt64
  let decodedVideo: UInt64
  let decodedAudio: UInt64
  let displayedPictures: UInt64
  let lostPictures: UInt64
  let playedAudioBuffers: UInt64
  let lostAudioBuffers: UInt64
}

struct LocalPlaybackRawResult: Codable, Equatable {
  let fixture: LocalPlaybackFixtureContract
  let sourceScheme: String
  let localFileName: String
  let downloadedSHA256: String
  let downloadedBytes: Int
  let generationBefore: String
  let generationAfter: String
  let stateSequence: [String]
  let durationMilliseconds: Int64
  let measurementDurationMilliseconds: Int64
  let measurementStartSystemUptime: Double
  let measurementEndSystemUptime: Double
  let start: LocalPlaybackCounterSnapshot
  let end: LocalPlaybackCounterSnapshot
}
