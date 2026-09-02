#if os(macOS)
@_spi(PrivateMacOSPiP) @testable import SwiftVLC
import AppKit

@MainActor
final class PiPReshapeProbeView: NSView {
  var reshapeCount = 0

  @objc(reshape)
  func reshapeForTesting() {
    reshapeCount += 1
  }
}

final class OpenMacVoutContainerProbe {
  let container: MacNativePiPDrawableView

  init(container: MacNativePiPDrawableView) {
    self.container = container
  }
}

final class MacWeakBox<T: AnyObject> {
  weak var value: T?

  init(_ value: T?) {
    self.value = value
  }
}

@MainActor
final class MacPrivatePiPViewControllerProbe: NSViewController {
  @objc dynamic var delegate: NSObject?
  @objc dynamic var replacementWindow: NSWindow?
  @objc dynamic var replacementRect: NSValue?
  @objc dynamic var playing = false
  @objc dynamic var aspectRatio: NSValue?

  private(set) var presentedViewController: NSViewController?
  private(set) var dismissCount = 0

  @objc(presentViewControllerAsPictureInPicture:)
  func presentAsPictureInPicture(_ viewController: NSViewController) {
    presentedViewController = viewController
  }

  @objc(dismissPictureInPictureWithCompletionHandler:)
  func dismissPictureInPicture(
    completion: @escaping @convention(block) () -> Void
  ) {
    dismissCount += 1
    completion()
  }
}

struct MacHostChurnResult {
  let currentHost: MacNativePiPHostView
  let originalDrawable: MacNativePiPDrawableView
  let originalBackend: MacNativePiPBackend
  let nativeHandle: OpaquePointer
  let retiredHosts: [MacWeakBox<MacNativePiPHostView>]
}

@MainActor
func churnMacHosts(
  for player: Player,
  count: Int
) -> MacHostChurnResult {
  var currentHost = autoreleasepool {
    let host = MacNativePiPHostView()
    host.attach(to: player)
    return host
  }
  let originalDrawable = currentHost.drawableView
  let originalBackend = currentHost.nativePiPBackend
  let nativeHandle = player.pointer
  player.nativePlayerHasStartedPlayback = true
  var retiredHosts: [MacWeakBox<MacNativePiPHostView>] = []

  for _ in 0..<count {
    currentHost = autoreleasepool {
      replaceMacHost(
        currentHost,
        for: player,
        recording: &retiredHosts
      )
    }
  }

  return MacHostChurnResult(
    currentHost: currentHost,
    originalDrawable: originalDrawable,
    originalBackend: originalBackend,
    nativeHandle: nativeHandle,
    retiredHosts: retiredHosts
  )
}

@MainActor
func replaceMacHost(
  _ retiredHost: MacNativePiPHostView,
  for player: Player,
  recording retiredHosts: inout [MacWeakBox<MacNativePiPHostView>]
) -> MacNativePiPHostView {
  let successorHost = MacNativePiPHostView()
  successorHost.attach(to: player)
  retiredHost.detach()
  retiredHosts.append(MacWeakBox(retiredHost))
  return successorHost
}
#endif
