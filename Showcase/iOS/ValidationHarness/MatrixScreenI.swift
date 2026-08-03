import SwiftUI
@_spi(Qualification) import SwiftVLC

private let timebaseReadMe = """
Captures the direct PiP media clock, control timebase, delivered sample PTS, \
renderer counters, and every timebase correction once per second. Run VOD and \
live for at least two hours each, exercising 0.5×, 1×, and 2× where supported, \
plus pause/resume, seek, interruption, replacement, resize, and thermal pressure.

The exported media clock is not an audio presentation timestamp. Pair this \
JSON with an audio/video capture or measurement and an AVPlayer baseline on the \
same device and fixture. Do not mark the matrix row passed from this log alone.
"""

struct MatrixScreenI: View {
  let streams: HarnessStreams

  @State private var player = Player()
  @State private var pip: PiPController?
  @State private var snapshots: [PiPTimebaseDiagnosticSnapshot] = []
  @State private var corrections: [PiPTimebaseCorrection] = []
  @State private var samplingTask: Task<Void, Never>?
  @State private var correctionTask: Task<Void, Never>?
  @State private var captureWriter: TimebaseCaptureWriter?
  @State private var captureURL: URL?
  @State private var isRecording = false
  @State private var transitionNote = ""
  @State private var error: String?

  var body: some View {
    Form {
      Section { AboutView(readMe: timebaseReadMe) }

      Section {
        DirectPiPValidationSurface(player: player, controller: $pip)
          .frame(height: 220)
          .listRowInsets(EdgeInsets())
      } footer: {
        PlayPauseFooter(player: player)
      }

      Section("Fixture") {
        if let vod = streams.vod {
          Button("Load VOD") { load(vod, label: "vod") }
        }
        if let live = streams.hlsLive ?? streams.liveTS {
          Button("Load live") { load(live, label: "live") }
        }
      }

      Section("Rate and transitions") {
        HStack {
          rateButton("0.5×", rate: .half)
          rateButton("1×", rate: .normal)
          rateButton("2×", rate: .double)
        }
        Button("Seek −10 seconds") { recordTransition("seek -10s", accepted: player.jump(by: .seconds(-10))) }
        Button("Seek +10 seconds") { recordTransition("seek +10s", accepted: player.jump(by: .seconds(10))) }
        TextField("Transition / audio observation", text: $transitionNote, axis: .vertical)
      }

      Section("Picture in Picture") {
        LabeledContent("Possible", value: pip?.isPossible == true ? "yes" : "no")
        LabeledContent("Active", value: pip?.isActive == true ? "yes" : "no")
        Button(pip?.isActive == true ? "Stop PiP" : "Start PiP", systemImage: "pip") {
          _ = pip?.toggle()
        }
        .disabled(pip?.isPossible != true)
      }

      Section("Clock capture") {
        LabeledContent("Samples", value: snapshots.count.formatted())
        LabeledContent("Corrections", value: corrections.count.formatted())
        LabeledContent("Duration", value: formattedDuration)
        LabeledContent("Thermal state", value: String(describing: ProcessInfo.processInfo.thermalState))
        Button(isRecording ? "Stop recording" : "Start recording") {
          isRecording ? stopRecording() : startRecording()
        }
        .tint(isRecording ? .red : .accentColor)
        Button("Clear capture", role: .destructive) {
          snapshots.removeAll(keepingCapacity: true)
          corrections.removeAll(keepingCapacity: true)
          transitionNote = ""
          error = nil
        }
        .disabled(isRecording)
        if let captureURL {
          ShareLink(item: captureURL) {
            Label("Share clock JSONL", systemImage: "square.and.arrow.up")
          }
        }
        if let error {
          Text(error).foregroundStyle(.red)
        }
      }

      ResultRecorderSection(screenID: "matrix-i")
    }
    .showcaseFormStyle()
    .navigationTitle("(i) Direct PiP clock soak")
    .onDisappear {
      stopRecording()
      player.stop()
    }
  }

  private var formattedDuration: String {
    guard let first = snapshots.first, let last = snapshots.last else { return "0s" }
    return Duration.seconds(last.systemUptime - first.systemUptime).formatted(.units(allowed: [.hours, .minutes, .seconds]))
  }

  private func load(_ url: URL, label: String) {
    do {
      try player.play(url: url)
      appendTransition("load \(label)")
    } catch {
      self.error = String(describing: error)
    }
  }

  private func rateButton(_ title: String, rate: PlaybackRate) -> some View {
    Button(title) {
      do {
        try player.setPlaybackRate(rate)
        appendTransition("rate \(title)")
      } catch {
        self.error = String(describing: error)
      }
    }
    .buttonStyle(.bordered)
  }

  private func recordTransition(_ label: String, accepted: Bool) {
    appendTransition("\(label) accepted=\(accepted)")
  }

  private func appendTransition(_ note: String) {
    let timestamped = "\(note) @ \(Date().formatted())"
    transitionNote += "\n\(timestamped)"
    guard let captureWriter else { return }
    Task {
      do {
        try await captureWriter.appendNote(timestamped)
      } catch {
        await MainActor.run { self.error = String(describing: error) }
      }
    }
  }

  private func startRecording() {
    guard let pip else {
      error = "Direct PiP controller is not ready"
      return
    }
    let writer: TimebaseCaptureWriter
    do {
      writer = try TimebaseCaptureWriter()
    } catch {
      self.error = String(describing: error)
      return
    }
    captureWriter = writer
    captureURL = writer.url
    isRecording = true
    error = nil
    samplingTask = Task { @MainActor in
      while !Task.isCancelled {
        let snapshot = pip.timebaseDiagnosticSnapshot()
        snapshots.append(snapshot)
        do {
          try await writer.appendSnapshot(snapshot)
        } catch {
          self.error = String(describing: error)
          stopRecording()
          return
        }
        try? await Task.sleep(for: .seconds(1))
      }
    }
    let stream = pip.timebaseCorrections
    correctionTask = Task { @MainActor in
      for await correction in stream {
        guard !Task.isCancelled else { return }
        corrections.append(correction)
        do {
          try await writer.appendCorrection(correction)
        } catch {
          self.error = String(describing: error)
          stopRecording()
          return
        }
      }
    }
  }

  private func stopRecording() {
    samplingTask?.cancel()
    correctionTask?.cancel()
    let writer = captureWriter
    samplingTask = nil
    correctionTask = nil
    captureWriter = nil
    isRecording = false
    Task {
      do {
        try await writer?.close()
      } catch {
        await MainActor.run { self.error = String(describing: error) }
      }
    }
  }
}

private actor TimebaseCaptureWriter {
  nonisolated let url: URL

  private let handle: FileHandle
  private let encoder: JSONEncoder
  private var isClosed = false

  init() throws {
    let directory = try FileManager.default.url(
      for: .documentDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    url = directory.appending(
      path: "swiftvlc-timebase-\(UUID().uuidString).jsonl",
      directoryHint: .notDirectory
    )
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
      throw CocoaError(.fileWriteUnknown)
    }
    handle = try FileHandle(forWritingTo: url)
    encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    try Self.write(
      CaptureLine(kind: .metadata, recordedAt: .now, schemaVersion: 1),
      encoder: encoder,
      handle: handle
    )
  }

  func appendSnapshot(_ snapshot: PiPTimebaseDiagnosticSnapshot) throws {
    try write(CaptureLine(kind: .snapshot, recordedAt: .now, snapshot: snapshot))
  }

  func appendCorrection(_ correction: PiPTimebaseCorrection) throws {
    try write(CaptureLine(kind: .correction, recordedAt: .now, correction: correction))
  }

  func appendNote(_ note: String) throws {
    try write(CaptureLine(kind: .note, recordedAt: .now, note: note))
  }

  func close() throws {
    guard !isClosed else { return }
    isClosed = true
    try handle.synchronize()
    try handle.close()
  }

  private func write(_ line: CaptureLine) throws {
    guard !isClosed else { throw CocoaError(.fileWriteUnknown) }
    try Self.write(line, encoder: encoder, handle: handle)
  }

  private static func write(
    _ line: CaptureLine,
    encoder: JSONEncoder,
    handle: FileHandle
  )
    throws {
    var data = try encoder.encode(line)
    data.append(0x0A)
    try handle.write(contentsOf: data)
  }
}

private struct CaptureLine: Codable {
  enum Kind: String, Codable {
    case metadata
    case snapshot
    case correction
    case note
  }

  let kind: Kind
  let recordedAt: Date
  var schemaVersion: Int?
  var snapshot: PiPTimebaseDiagnosticSnapshot?
  var correction: PiPTimebaseCorrection?
  var note: String?
}
