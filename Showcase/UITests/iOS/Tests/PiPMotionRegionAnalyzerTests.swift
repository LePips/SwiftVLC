import XCTest

final class PiPMotionRegionAnalyzerTests: XCTestCase {
  private let analyzer = PiPMotionRegionAnalyzer()
  private let screenWidth = 160
  private let screenHeight = 240
  private let expectedPiP = PiPMotionRegion(x: 64, y: 156, width: 80, height: 45)
  private let iOS27SizedPiP = PiPMotionRegion(x: 96, y: 24, width: 56, height: 32)

  func testNormalizedSystemPiPControlPointUsesDetectedBounds() {
    let region = SystemPictureInPictureWindowRegion(
      normalizedX: 0.4,
      normalizedY: 0.65,
      normalizedWidth: 0.5,
      normalizedHeight: 0.1875
    )

    let close = region.normalizedPoint(x: 0.12, y: 0.18)
    let restore = region.normalizedPoint(x: 0.88, y: 0.18)

    XCTAssertEqual(close.dx, 0.46, accuracy: 0.0001)
    XCTAssertEqual(close.dy, 0.68375, accuracy: 0.0001)
    XCTAssertEqual(restore.dx, 0.84, accuracy: 0.0001)
    XCTAssertEqual(restore.dy, close.dy, accuracy: 0.0001)
  }

  func testMovingVideoInsideFixedSixteenByNinePiPRegionPasses() throws {
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: self.expectedPiP, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    let detected = try XCTUnwrap(analysis.region)
    XCTAssertGreaterThanOrEqual(
      Double(detected.intersectionArea(with: expectedPiP)) / Double(expectedPiP.area),
      0.85,
      diagnostics(for: analysis)
    )
    XCTAssertGreaterThanOrEqual(analysis.sustainedMotionPairCount, analysis.requiredPairCount)
    XCTAssertGreaterThanOrEqual(analysis.nonBlackFrameCount, frames.count - 1)
  }

  func testSparseMotionInsideIOS27SizedPiPRegionPassesTemporalUnionFallback() throws {
    let frames = sparsePiPFrames(regions: [iOS27SizedPiP])

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.candidateSource, .temporalUnion, diagnostics(for: analysis))
    let detected = try XCTUnwrap(analysis.region)
    XCTAssertGreaterThanOrEqual(
      Double(detected.intersectionArea(with: iOS27SizedPiP)) / Double(iOS27SizedPiP.area),
      0.75,
      diagnostics(for: analysis)
    )
    XCTAssertGreaterThanOrEqual(analysis.sustainedMotionPairCount, analysis.requiredPairCount)
    XCTAssertGreaterThanOrEqual(analysis.nonBlackFrameCount, frames.count - 1)
  }

  func testTwoSparseIOS27SizedMotionRegionsFailAsAmbiguous() {
    let second = PiPMotionRegion(x: 4, y: 176, width: 56, height: 32)
    let frames = sparsePiPFrames(regions: [iOS27SizedPiP, second])

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .ambiguousMotionRegions, diagnostics(for: analysis))
  }

  func testTemporalUnionRejectsSweepingBandsThatOnlyFormPiPGeometryOverTime() {
    let frames = sweepingBandFrames(in: iOS27SizedPiP)

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertNil(analysis.candidateSource, diagnostics(for: analysis))
    XCTAssertEqual(
      analysis.failure,
      .noStablePiPSizedComponent,
      diagnostics(for: analysis)
    )
  }

  func testTemporalUnionDoesNotBoxDisconnectedAnimationsIntoPiPGeometry() {
    let frames = disconnectedCornerAnimationFrames(in: iOS27SizedPiP)

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertNil(analysis.candidateSource, diagnostics(for: analysis))
    XCTAssertEqual(
      analysis.failure,
      .noStablePiPSizedComponent,
      diagnostics(for: analysis)
    )
  }

  func testTemporalUnionRejectsTransientBridgeBetweenAlternatingCornerAnimations() {
    let frames = transientBridgeCornerAnimationFrames(in: iOS27SizedPiP)

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertNil(analysis.candidateSource, diagnostics(for: analysis))
    XCTAssertEqual(
      analysis.failure,
      .noStablePiPSizedComponent,
      diagnostics(for: analysis)
    )
  }

  func testSystemSurfaceStabilityAllowsBoundedMovingPiP() throws {
    let frames = sparsePiPFrames(regions: [iOS27SizedPiP], count: 2)
    let detector = PiPSystemSurfaceStabilityDetector()

    let changedRatio = try XCTUnwrap(
      detector.changedPixelRatio(from: frames[0], to: frames[1])
    )

    XCTAssertGreaterThan(changedRatio, 0)
    XCTAssertLessThanOrEqual(changedRatio, 0.12)
    XCTAssertTrue(detector.isStableTransition(from: frames[0], to: frames[1]))
  }

  func testSystemSurfaceStabilityRejectsWholeScreenTransition() throws {
    let before = syntheticFrames(count: 1) { _, _, _, _ in .background }[0]
    let after = syntheticFrames(count: 1) { _, _, _, _ in
      .pixel(PiPMotionPixel(red: 180, green: 180, blue: 180))
    }[0]
    let detector = PiPSystemSurfaceStabilityDetector()

    let changedRatio = try XCTUnwrap(detector.changedPixelRatio(from: before, to: after))

    XCTAssertGreaterThan(changedRatio, 0.90)
    XCTAssertFalse(detector.isStableTransition(from: before, to: after))
  }

  func testWholeScreenAnimationFails() {
    let fullScreen = PiPMotionRegion(
      x: 0,
      y: 0,
      width: screenWidth,
      height: screenHeight
    )
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: fullScreen, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertGreaterThan(analysis.largestPersistentComponentAreaRatio, 0.90)
  }

  func testSmallWidgetAnimationFails() {
    let widget = PiPMotionRegion(x: 104, y: 18, width: 36, height: 36)
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: widget, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertGreaterThan(analysis.largestPersistentComponentAreaRatio, 0.012)
  }

  func testMediumHomeScreenWidgetAnimationFails() {
    let widget = PiPMotionRegion(x: 28, y: 22, width: 104, height: 48)
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: widget, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertGreaterThan(analysis.largestPersistentComponentAreaRatio, 0.10)
  }

  func testSpinnerSizedAnimationFails() {
    let spinner = PiPMotionRegion(x: 132, y: 26, width: 12, height: 12)
    let frames = syntheticFrames { _, _, _, frameIndex in
      .animated(region: spinner, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
    XCTAssertLessThan(analysis.largestPersistentComponentAreaRatio, 0.012)
  }

  func testRandomScatteredChangesFail() {
    let frames = (0..<6).map(scatteredFrame)

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertNil(analysis.candidateSource, diagnostics(for: analysis))
    XCTAssertEqual(
      analysis.failure,
      .noStablePiPSizedComponent,
      diagnostics(for: analysis)
    )
  }

  func testStaticNonBlackPiPRegionFails() {
    let frames = syntheticFrames { x, y, _, _ in
      self.expectedPiP.contains(x: x, y: y)
        ? .pixel(PiPMotionPixel(red: 80, green: 170, blue: 220))
        : .background
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
  }

  func testBlackMotionlessFramesFail() {
    let frames = syntheticFrames { _, _, _, _ in .background }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .noStablePiPSizedComponent)
  }

  func testDarkAnimatedPiPRegionFailsNonBlackGate() {
    let frames = syntheticFrames { x, y, _, frameIndex in
      guard self.expectedPiP.contains(x: x, y: y) else { return .background }
      let value: UInt8 = frameIndex.isMultiple(of: 2) ? 0 : 35
      return .pixel(PiPMotionPixel(red: value, green: value, blue: value))
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .insufficientNonBlackContent)
    XCTAssertGreaterThanOrEqual(
      analysis.sustainedMotionPairCount,
      analysis.requiredPairCount
    )
    XCTAssertEqual(analysis.nonBlackFrameCount, 0)
  }

  func testPiPRelocationCreatesAmbiguousPersistentRegionsAndFails() {
    let frames = syntheticFrames { _, _, _, frameIndex in
      let region = frameIndex.isMultiple(of: 2)
        ? PiPMotionRegion(x: 8, y: 30, width: 80, height: 45)
        : PiPMotionRegion(x: 72, y: 156, width: 80, height: 45)
      return .animated(region: region, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertFalse(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.failure, .ambiguousMotionRegions, diagnostics(for: analysis))
  }

  func testRoundedCornersAndStaticControlsStillPass() throws {
    let frames = syntheticFrames { x, y, _, frameIndex in
      guard self.expectedPiP.contains(x: x, y: y) else { return .background }
      guard self.isInsideRoundedPiP(x: x, y: y) else { return .background }
      if self.isStaticControl(x: x, y: y) {
        return .pixel(PiPMotionPixel(red: 92, green: 92, blue: 92))
      }
      return .animated(region: self.expectedPiP, frameIndex: frameIndex)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    let detected = try XCTUnwrap(analysis.region)
    XCTAssertGreaterThanOrEqual(
      Double(detected.intersectionArea(with: expectedPiP)) / Double(expectedPiP.area),
      0.80,
      diagnostics(for: analysis)
    )
    XCTAssertGreaterThan(analysis.persistentFillRatio, 0.65)
  }

  func testDisconnectedMotionInsideOneFixedPiPRegionPasses() throws {
    let frames = syntheticFrames { x, y, _, frameIndex in
      guard self.expectedPiP.contains(x: x, y: y) else { return .background }

      let localX = x - self.expectedPiP.x
      let localY = y - self.expectedPiP.y
      let movingDiagonal = abs(localY - ((localX + frameIndex * 3) % self.expectedPiP.height)) <= 2
      let movingBlock = localX >= 52 && localX < 72
        && localY >= 25 && localY < 39
        && (localX / 3 + localY / 3 + frameIndex).isMultiple(of: 2)
      if movingDiagonal || movingBlock {
        return .animated(region: self.expectedPiP, frameIndex: frameIndex)
      }
      return .pixel(PiPMotionPixel(red: 60, green: 80, blue: 180))
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    let detected = try XCTUnwrap(analysis.region)
    XCTAssertGreaterThanOrEqual(
      Double(detected.intersectionArea(with: expectedPiP)) / Double(expectedPiP.area),
      0.75,
      diagnostics(for: analysis)
    )
  }

  func testOneWholeScreenTransitionDoesNotDisplaceStablePiP() {
    let changedBackground = PiPMotionPixel(red: 110, green: 110, blue: 110)
    let frames = syntheticFrames { x, y, _, frameIndex in
      if self.expectedPiP.contains(x: x, y: y) {
        return .animated(region: self.expectedPiP, frameIndex: frameIndex)
      }
      return frameIndex < 2 ? .background : .pixel(changedBackground)
    }

    let analysis = analyzer.analyze(frames)

    XCTAssertTrue(analysis.passed, diagnostics(for: analysis))
    XCTAssertEqual(analysis.matchingPairCount, analysis.requiredPairCount)
    XCTAssertGreaterThanOrEqual(
      analysis.sustainedMotionPairCount,
      analysis.requiredPairCount
    )
  }
}

extension PiPMotionRegionAnalyzerTests {
  fileprivate enum SyntheticPixel {
    case background
    case pixel(PiPMotionPixel)
    case animated(region: PiPMotionRegion, frameIndex: Int)
  }

  private func syntheticFrames(
    count: Int = 6,
    pixel: (Int, Int, Int, Int) -> SyntheticPixel
  ) -> [PiPMotionFrame] {
    (0..<count).map { frameIndex in
      var pixels: [PiPMotionPixel] = []
      pixels.reserveCapacity(screenWidth * screenHeight)
      for y in 0..<screenHeight {
        for x in 0..<screenWidth {
          switch pixel(x, y, y * screenWidth + x, frameIndex) {
          case .background:
            pixels.append(.black)
          case .pixel(let value):
            pixels.append(value)
          case .animated(let region, let animationFrame):
            pixels.append(
              region.contains(x: x, y: y)
                ? animatedPixel(x: x, y: y, frameIndex: animationFrame)
                : .black
            )
          }
        }
      }
      return PiPMotionFrame(
        width: screenWidth,
        height: screenHeight,
        pixels: pixels
      )
    }
  }

  private func scatteredFrame(frameIndex: Int) -> PiPMotionFrame {
    var pixels = [PiPMotionPixel](
      repeating: .black,
      count: screenWidth * screenHeight
    )
    var state = UInt64(frameIndex + 1) &* 0x9E37_79B9_7F4A_7C15
    for sample in 0..<280 {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      let index = Int(state % UInt64(pixels.count))
      pixels[index] = animatedPixel(
        x: index % screenWidth,
        y: index / screenWidth,
        frameIndex: frameIndex + sample
      )
    }
    return PiPMotionFrame(width: screenWidth, height: screenHeight, pixels: pixels)
  }

  private func sparsePiPFrames(
    regions: [PiPMotionRegion],
    count: Int = 6
  ) -> [PiPMotionFrame] {
    let staticBars = [
      PiPMotionPixel(red: 220, green: 35, blue: 35),
      PiPMotionPixel(red: 35, green: 220, blue: 45),
      PiPMotionPixel(red: 235, green: 225, blue: 40),
      PiPMotionPixel(red: 45, green: 65, blue: 225),
      PiPMotionPixel(red: 220, green: 45, blue: 215),
      PiPMotionPixel(red: 40, green: 215, blue: 220)
    ]
    return syntheticFrames(count: count) { x, y, _, frameIndex in
      guard let region = regions.first(where: { $0.contains(x: x, y: y) }) else {
        return .background
      }
      let localX = x - region.x
      let localY = y - region.y
      let diagonalY = (localX / 2 + frameIndex * 4) % region.height
      let movingDiagonal = abs(localY - diagonalY) <= 1
      let checker = localX >= region.width * 2 / 3
        && localX < region.width - 3
        && localY >= region.height / 2
        && localY < region.height - 3
        && (localX / 2 + localY / 2 + frameIndex).isMultiple(of: 2)
      let markerX = (frameIndex * 7 + region.width / 4) % region.width
      let movingMarker = abs(localX - markerX) <= 1
        && abs(localY - region.height / 3) <= 1
      if movingDiagonal || checker || movingMarker {
        return .pixel(animatedPixel(x: x, y: y, frameIndex: frameIndex))
      }
      let bar = min(staticBars.count - 1, localX * staticBars.count / region.width)
      return .pixel(staticBars[bar])
    }
  }

  /// A static non-black landscape widget with one animated horizontal band at
  /// a time. Its temporal union has PiP geometry and every pair has ample
  /// motion, but no pair contains a window-shaped moving surface.
  private func sweepingBandFrames(in region: PiPMotionRegion) -> [PiPMotionFrame] {
    let background = PiPMotionPixel(red: 80, green: 115, blue: 155)
    let bandColors = [
      PiPMotionPixel(red: 230, green: 45, blue: 45),
      PiPMotionPixel(red: 45, green: 225, blue: 70)
    ]
    return syntheticFrames { x, y, _, frameIndex in
      guard region.contains(x: x, y: y) else { return .background }
      let localY = y - region.y
      let band = frameIndex % 5
      let lowerBound = band * 6
      if localY >= lowerBound, localY < min(region.height, lowerBound + 6) {
        return .pixel(bandColors[frameIndex.isMultiple(of: 2) ? 0 : 1])
      }
      return .pixel(background)
    }
  }

  /// Four disconnected corner animations collectively outline a landscape
  /// box over time. No connected moving surface ever has PiP geometry, so a
  /// temporal fallback must not combine those components into one candidate.
  private func disconnectedCornerAnimationFrames(
    in region: PiPMotionRegion
  ) -> [PiPMotionFrame] {
    let background = PiPMotionPixel(red: 80, green: 115, blue: 155)
    let off = PiPMotionPixel(red: 210, green: 45, blue: 55)
    let on = PiPMotionPixel(red: 45, green: 220, blue: 75)
    let firstDiagonalStates = [false, true, false, false, false, false]
    let secondDiagonalStates = [false, false, false, true, false, true]
    let blockSize = 9
    return syntheticFrames { x, y, _, frameIndex in
      guard region.contains(x: x, y: y) else { return .background }
      let localX = x - region.x
      let localY = y - region.y
      let left = localX < blockSize
      let right = localX >= region.width - blockSize
      let top = localY < blockSize
      let bottom = localY >= region.height - blockSize
      if (left && top) || (right && bottom) {
        return .pixel(firstDiagonalStates[frameIndex] ? on : off)
      }
      if (right && top) || (left && bottom) {
        return .pixel(secondDiagonalStates[frameIndex] ? on : off)
      }
      return .pixel(background)
    }
  }

  /// A single X-shaped flash connects four corner animations in the temporal
  /// union. Later pairs only alternate two disconnected opposite corners. A
  /// raw union plus a combined bounding box mistakes this static widget for a
  /// fixed moving PiP window; the persistent identity core must reject it.
  private func transientBridgeCornerAnimationFrames(
    in region: PiPMotionRegion
  ) -> [PiPMotionFrame] {
    let background = PiPMotionPixel(red: 80, green: 115, blue: 155)
    let off = PiPMotionPixel(red: 45, green: 225, blue: 70)
    let on = PiPMotionPixel(red: 230, green: 45, blue: 45)
    let cornerStates = [
      [false, false, false, false],
      [true, false, false, true],
      [true, true, true, true],
      [false, true, true, false],
      [false, false, false, false],
      [true, false, false, true]
    ]
    let blockSize = 9
    return syntheticFrames { x, y, _, frameIndex in
      guard region.contains(x: x, y: y) else { return .background }
      let localX = x - region.x
      let localY = y - region.y
      let left = localX < blockSize
      let right = localX >= region.width - blockSize
      let top = localY < blockSize
      let bottom = localY >= region.height - blockSize
      let corner: Int? = if left && top {
        0
      } else if right && top {
        1
      } else if left && bottom {
        2
      } else if right && bottom {
        3
      } else {
        nil
      }
      if let corner {
        return .pixel(cornerStates[frameIndex][corner] ? on : off)
      }

      let diagonalY = localX * (region.height - 1) / (region.width - 1)
      let reverseDiagonalY = region.height - 1 - diagonalY
      if
        frameIndex == 1,
        abs(localY - diagonalY) <= 1 || abs(localY - reverseDiagonalY) <= 1 {
        return .pixel(on)
      }
      return .pixel(background)
    }
  }

  private func animatedPixel(x: Int, y: Int, frameIndex: Int) -> PiPMotionPixel {
    let palette = [
      PiPMotionPixel(red: 225, green: 65, blue: 55),
      PiPMotionPixel(red: 50, green: 215, blue: 90),
      PiPMotionPixel(red: 55, green: 80, blue: 230),
      PiPMotionPixel(red: 235, green: 205, blue: 50),
      PiPMotionPixel(red: 190, green: 50, blue: 215),
      PiPMotionPixel(red: 50, green: 215, blue: 215)
    ]
    return palette[(x / 3 + y / 3 + frameIndex) % palette.count]
  }

  private func isInsideRoundedPiP(x: Int, y: Int) -> Bool {
    let localX = x - expectedPiP.x
    let localY = y - expectedPiP.y
    let radius = 8

    let cornerCenters = [
      (radius, radius),
      (expectedPiP.width - radius - 1, radius),
      (radius, expectedPiP.height - radius - 1),
      (expectedPiP.width - radius - 1, expectedPiP.height - radius - 1)
    ]
    for (centerX, centerY) in cornerCenters {
      let nearHorizontalEdge = centerX < expectedPiP.width / 2
        ? localX < radius
        : localX >= expectedPiP.width - radius
      let nearVerticalEdge = centerY < expectedPiP.height / 2
        ? localY < radius
        : localY >= expectedPiP.height - radius
      if nearHorizontalEdge, nearVerticalEdge {
        let deltaX = localX - centerX
        let deltaY = localY - centerY
        return deltaX * deltaX + deltaY * deltaY <= radius * radius
      }
    }
    return true
  }

  private func isStaticControl(x: Int, y: Int) -> Bool {
    let centerX = expectedPiP.x + expectedPiP.width / 2
    let centerY = expectedPiP.y + expectedPiP.height / 2
    let deltaX = x - centerX
    let deltaY = y - centerY
    let centerControl = deltaX * deltaX + deltaY * deltaY <= 7 * 7
    let bottomBar = y >= expectedPiP.maxY - 7
      && y < expectedPiP.maxY - 4
      && x >= centerX - 16
      && x <= centerX + 16
    return centerControl || bottomBar
  }

  private func diagnostics(for analysis: PiPMotionRegionAnalysis) -> String {
    "failure=\(analysis.failure?.rawValue ?? "none"), "
      + "region=\(String(describing: analysis.region)), "
      + "source=\(analysis.candidateSource?.rawValue ?? "none"), "
      + "pairMotion=\(analysis.pairMotionRatios), "
      + "nonBlack=\(analysis.frameNonBlackRatios), "
      + "matching=\(analysis.matchingPairCount)/\(analysis.requiredPairCount), "
      + "drift=(\(analysis.horizontalCenterDriftRatio), "
      + "\(analysis.verticalCenterDriftRatio))"
  }
}

extension PiPMotionRegion {
  fileprivate func contains(x: Int, y: Int) -> Bool {
    x >= self.x && x < maxX && y >= self.y && y < maxY
  }
}
