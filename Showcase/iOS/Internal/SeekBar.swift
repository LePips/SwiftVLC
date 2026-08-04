import SwiftUI
import SwiftVLC

/// Scrub bar with current time and duration. Drop into any Form `Section`.
///
/// Uses plain `HStack + Text` rather than `LabeledContent` for the time
/// rows because `LabeledContent` joins its label and content into a single
/// accessibility element (e.g. "Current, 0:23"), which prevents XCUITest
/// from querying each value independently. The visual result is the same.
struct SeekBar: View {
  let player: Player
  @State private var scrubPosition: Double?

  var body: some View {
    CompatSlider(
      value: Binding(
        get: { scrubPosition ?? player.position },
        set: { position in
          scrubPosition = position
          try? player.seek(to: PlaybackPosition(position), fast: true)
        }
      ),
      range: 0...1,
      onEditingChanged: { isEditing in
        if isEditing {
          scrubPosition = player.position
        } else if let position = scrubPosition {
          scrubPosition = nil
          try? player.seek(to: PlaybackPosition(position))
        }
      }
    )
    .accessibilityIdentifier(AccessibilityID.SeekBar.slider)

    timeRow("Current", value: format(player.currentTime), identifier: AccessibilityID.SeekBar.currentTime)
    timeRow("Duration", value: format(player.duration ?? .zero), identifier: AccessibilityID.SeekBar.duration)
  }

  private func timeRow(_ title: String, value: String, identifier: String) -> some View {
    HStack {
      Text(title)
      Spacer()
      Text(value)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier(identifier)
    }
  }

  private func format(_ duration: Duration) -> String {
    let seconds = Int(duration.components.seconds)
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}
