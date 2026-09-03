import SwiftUI
import SwiftVLC

@main
struct ShowcaseApp: App {
  @AppStorage(TestStreamURL.revisionDefaultsKey) private var testStreamRevision = ""

  init() {
    TestStreamURL.startSession()
    // Qualification must install its native log callback before any player
    // setup can emit diagnostics. Outside UI-test mode this returns without
    // touching VLCInstance, so normal launch retains background prewarming.
    UITestSupport.startLogMirrorIfRequested()
    VLCInstance.prewarmShared()
    CastTrustResponder.shared.start()
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .id(testStreamRevision)
        .tint(.orange)
        .overlay(alignment: .topLeading) {
          if let binding = LaunchArguments.qualificationCandidateRuntimeBindingValue {
            // This surface exists only under the UI-test launch contract. It
            // proves which signed candidate process XCTest actually observed,
            // even if another qualification tries to replace the installed app.
            Text(binding)
              .font(.system(size: 1))
              .lineLimit(1)
              .frame(width: 1, height: 1)
              .clipped()
              .accessibilityLabel(binding)
              .accessibilityIdentifier(
                AccessibilityID.Qualification.candidateRuntimeBinding
              )
              .accessibilityHidden(false)
              .allowsHitTesting(false)
          }
        }
    }
  }
}
