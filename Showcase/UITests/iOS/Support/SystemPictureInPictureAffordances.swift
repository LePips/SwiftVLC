import UIKit
import XCTest

@MainActor
struct SystemPictureInPictureAffordances {
  let close: XCUIElement
  let restore: XCUIElement
}

private struct SystemPictureInPictureAffordanceFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

@MainActor
private struct SystemPictureInPictureButtonObservation {
  let index: Int
  let element: XCUIElement
  let exists: Bool
  let isHittable: Bool
  let frame: CGRect
  let label: String
  let identifier: String

  var hasUsableFrame: Bool {
    exists && isHittable && !frame.isEmpty && !frame.isInfinite && !frame.isNull
  }
}

@MainActor
extension ShowcaseIOSTestCase {
  /// Reveals the real SpringBoard PiP controls and resolves their close and
  /// restore buttons from accessibility role and frame alone. The detected
  /// moving-video region supplies a bounded top control band; this deliberately
  /// does not enlarge that evidence-derived region or depend on localized
  /// labels.
  ///
  /// A valid system surface has exactly two hittable buttons intersecting its
  /// top band, one on either side of the region midpoint. Any ambiguity fails
  /// closed with the full observed button geometry attached.
  func locateSystemPictureInPictureAffordances(
    in region: SystemPictureInPictureWindowRegion,
    attachmentName: String
  )
    throws -> SystemPictureInPictureAffordances {
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    guard springboard.waitForExistence(timeout: 2) else {
      throw SystemPictureInPictureAffordanceFailure(
        "SpringBoard was not available while resolving system PiP controls"
      )
    }

    let screenFrame = springboard.frame
    guard !screenFrame.isEmpty, !screenFrame.isInfinite, !screenFrame.isNull else {
      throw SystemPictureInPictureAffordanceFailure(
        "SpringBoard published an invalid screen frame: \(screenFrame)"
      )
    }
    let seedFrame = CGRect(
      x: screenFrame.minX + screenFrame.width * region.normalizedX,
      y: screenFrame.minY + screenFrame.height * region.normalizedY,
      width: screenFrame.width * region.normalizedWidth,
      height: screenFrame.height * region.normalizedHeight
    )
    let topBand = CGRect(
      x: seedFrame.minX,
      y: seedFrame.minY,
      width: seedFrame.width,
      height: seedFrame.height * 0.4
    )

    // System controls auto-hide. Waiting first makes the center tap a reveal
    // gesture rather than an accidental play/pause action.
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    springboard.coordinate(
      withNormalizedOffset: region.normalizedPoint(x: 0.5, y: 0.5)
    ).tap()

    let deadline = Date().addingTimeInterval(2)
    var lastObservations: [SystemPictureInPictureButtonObservation] = []
    repeat {
      lastObservations = observeSystemPictureInPictureButtons(in: springboard)
      let resolution = resolveSystemPictureInPictureAffordances(
        from: lastObservations,
        seedFrame: seedFrame,
        topBand: topBand
      )
      if let close = resolution.close, let restore = resolution.restore {
        attachSystemPictureInPictureAffordanceDiagnostics(
          observations: lastObservations,
          screenFrame: screenFrame,
          seedFrame: seedFrame,
          topBand: topBand,
          attachmentName: attachmentName
        )
        return SystemPictureInPictureAffordances(close: close, restore: restore)
      }
      if Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
      }
    } while Date() < deadline

    let diagnostics = attachSystemPictureInPictureAffordanceDiagnostics(
      observations: lastObservations,
      screenFrame: screenFrame,
      seedFrame: seedFrame,
      topBand: topBand,
      attachmentName: attachmentName
    )
    throw SystemPictureInPictureAffordanceFailure(
      "System PiP close/restore accessibility contract was ambiguous. \(diagnostics)"
    )
  }

  private func observeSystemPictureInPictureButtons(
    in springboard: XCUIApplication
  ) -> [SystemPictureInPictureButtonObservation] {
    springboard.buttons.allElementsBoundByIndex.enumerated().map { index, element in
      let exists = element.exists
      return SystemPictureInPictureButtonObservation(
        index: index,
        element: element,
        exists: exists,
        isHittable: exists && element.isHittable,
        frame: exists ? element.frame : .null,
        label: exists ? element.label : "",
        identifier: exists ? element.identifier : ""
      )
    }
  }

  private func resolveSystemPictureInPictureAffordances(
    from observations: [SystemPictureInPictureButtonObservation],
    seedFrame: CGRect,
    topBand: CGRect
  ) -> (close: XCUIElement?, restore: XCUIElement?) {
    let topBandButtons = observations.filter {
      $0.hasUsableFrame
        && $0.frame.intersects(seedFrame)
        && $0.frame.intersects(topBand)
        && $0.frame.midY <= topBand.maxY
    }
    let sorted = topBandButtons.sorted { $0.frame.midX < $1.frame.midX }
    guard
      sorted.count == 2,
      sorted[0].index != sorted[1].index,
      sorted[0].frame.midX < seedFrame.midX,
      sorted[1].frame.midX > seedFrame.midX
    else { return (nil, nil) }
    return (sorted[0].element, sorted[1].element)
  }

  @discardableResult
  private func attachSystemPictureInPictureAffordanceDiagnostics(
    observations: [SystemPictureInPictureButtonObservation],
    screenFrame: CGRect,
    seedFrame: CGRect,
    topBand: CGRect,
    attachmentName: String
  ) -> String {
    let observedButtons = observations.map { observation in
      let intersectsSeed = observation.hasUsableFrame
        && observation.frame.intersects(seedFrame)
      let intersectsTopBand = intersectsSeed && observation.frame.intersects(topBand)
      let isTopBandCandidate = intersectsTopBand && observation.frame.midY <= topBand.maxY
      return """
      [\(observation.index)] role=button exists=\(observation.exists) \
      hittable=\(observation.isHittable) frame=\(observation.frame) \
      intersectsSeed=\(intersectsSeed) intersectsTopBand=\(intersectsTopBand) \
      topBandCandidate=\(isTopBandCandidate) \
      identifier=\(String(reflecting: observation.identifier)) \
      label=\(String(reflecting: observation.label))
      """
    }
    let diagnostics = """
    screen=\(screenFrame)
    motionSeed=\(seedFrame)
    topControlBand=\(topBand)
    observedSpringBoardButtons=\(observations.count)
    \(observedButtons.joined(separator: "\n"))
    """
    let attachment = XCTAttachment(string: diagnostics)
    attachment.name = "\(attachmentName)-ax-targets"
    attachment.lifetime = .keepAlways
    add(attachment)

    let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    screenshot.name = "\(attachmentName)-controls"
    screenshot.lifetime = .keepAlways
    add(screenshot)
    return diagnostics
  }
}
