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
    }
  }
}
