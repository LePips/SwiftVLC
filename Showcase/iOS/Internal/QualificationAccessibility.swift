import SwiftUI

extension View {
  /// Exposes a validation measurement as one stable accessibility element.
  ///
  /// SwiftUI's `LabeledContent` and `HStack` bridge differently across OS
  /// releases: some versions merge the title into `label`, while others
  /// expose only the trailing text. Device qualification reads the exact
  /// machine value from `value` and keeps the human-facing title in `label`.
  func qualificationAccessibilityValue(
    label: String,
    value: String,
    identifier: String
  ) -> some View {
    accessibilityElement(children: .ignore)
      .accessibilityIdentifier(identifier)
      .accessibilityLabel(Text(label))
      .accessibilityValue(Text(value))
  }
}
