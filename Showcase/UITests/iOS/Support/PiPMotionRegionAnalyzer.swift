/// One RGB sample in a downsampled screen capture.
///
/// This type and the analyzer below deliberately have no UIKit, Core Graphics,
/// or XCTest dependency. The physical-device UI test is only an adapter from
/// `UIImage` to this deterministic, platform-neutral input.
struct PiPMotionPixel: Equatable {
  let red: UInt8
  let green: UInt8
  let blue: UInt8

  static let black = Self(red: 0, green: 0, blue: 0)

  func differs(from other: Self, threshold: Int) -> Bool {
    max(
      abs(Int(red) - Int(other.red)),
      abs(Int(green) - Int(other.green)),
      abs(Int(blue) - Int(other.blue))
    ) >= threshold
  }

  func isNonBlack(threshold: UInt8) -> Bool {
    max(red, green, blue) > threshold
  }
}

/// A row-major RGB frame consumed by `PiPMotionRegionAnalyzer`.
struct PiPMotionFrame: Equatable {
  let width: Int
  let height: Int
  let pixels: [PiPMotionPixel]

  init(width: Int, height: Int, pixels: [PiPMotionPixel]) {
    precondition(width > 0 && height > 0)
    precondition(pixels.count == width * height)
    self.width = width
    self.height = height
    self.pixels = pixels
  }
}

/// Distinguishes a settled SpringBoard surface from the app-switcher/home
/// transition that immediately follows `XCUIDevice.press(.home)`.
///
/// A real PiP window may change several percent of the screen on every frame,
/// so stability is defined as a bounded whole-screen delta rather than pixel
/// equality. The motion oracle still performs the stricter region, geometry,
/// persistence, motion, and non-black checks after this gate.
struct PiPSystemSurfaceStabilityDetector {
  struct Configuration: Equatable {
    var pixelDeltaThreshold = 28
    var maximumChangedPixelRatio = 0.12

    static let physicalPiP = Self()
  }

  var configuration: Configuration = .physicalPiP

  func changedPixelRatio(
    from first: PiPMotionFrame,
    to second: PiPMotionFrame
  ) -> Double? {
    guard first.width == second.width, first.height == second.height else { return nil }
    let changed = zip(first.pixels, second.pixels).count {
      $0.differs(from: $1, threshold: configuration.pixelDeltaThreshold)
    }
    return Double(changed) / Double(max(1, first.pixels.count))
  }

  func isStableTransition(
    from first: PiPMotionFrame,
    to second: PiPMotionFrame
  ) -> Bool {
    changedPixelRatio(from: first, to: second)
      .map { $0 <= configuration.maximumChangedPixelRatio } == true
  }
}

/// Integer coordinates in the analyzer's downsampled frame.
struct PiPMotionRegion: Equatable {
  let x: Int
  let y: Int
  let width: Int
  let height: Int

  var maxX: Int {
    x + width
  }

  var maxY: Int {
    y + height
  }

  var area: Int {
    width * height
  }

  var centerX: Double {
    Double(x) + Double(width) / 2
  }

  var centerY: Double {
    Double(y) + Double(height) / 2
  }

  func intersectionArea(with other: Self) -> Int {
    let overlapWidth = max(0, min(maxX, other.maxX) - max(x, other.x))
    let overlapHeight = max(0, min(maxY, other.maxY) - max(y, other.y))
    return overlapWidth * overlapHeight
  }
}

struct PiPMotionRegionAnalysis: Equatable {
  enum CandidateSource: String, Equatable {
    case persistentIntersection = "persistent-intersection"
    case temporalUnion = "temporal-union"
  }

  enum Failure: String, Equatable {
    case insufficientFrames = "fewer than five frames"
    case mismatchedFrameDimensions = "frame dimensions changed"
    case noStablePiPSizedComponent = "no contiguous, persistent PiP-sized motion component"
    case ambiguousMotionRegions = "multiple similarly sized persistent motion components"
    case unstableRegion = "motion component position drifted"
    case insufficientSustainedMotion = "motion was not sustained in the detected region"
    case insufficientNonBlackContent = "detected region did not contain sustained non-black pixels"
  }

  let frameWidth: Int
  let frameHeight: Int
  let region: PiPMotionRegion?
  let candidateSource: CandidateSource?
  let failure: Failure?
  let pairMotionRatios: [Double]
  let frameNonBlackRatios: [Double]
  let requiredPairCount: Int
  let requiredNonBlackFrameCount: Int
  let matchingPairCount: Int
  let sustainedMotionPairCount: Int
  let nonBlackFrameCount: Int
  let persistentComponentCount: Int
  let regionAreaRatio: Double
  let regionAspectRatio: Double
  let persistentFillRatio: Double
  let horizontalCenterDriftRatio: Double
  let verticalCenterDriftRatio: Double
  let largestPersistentComponentAreaRatio: Double

  var passed: Bool {
    failure == nil
  }
}

/// Finds one bounded, persistent motion component with the geometry and pixel
/// evidence expected of a landscape system PiP window.
///
/// The oracle intentionally does not use a whole-screen changed-pixel ratio:
/// every accepted pair must support the same persistent component, and the
/// same bounded region must contain both sustained motion and non-black
/// pixels. Pair-component centers are retained as diagnostics only: motion
/// inside a fixed video window can legitimately traverse its full width.
struct PiPMotionRegionAnalyzer {
  struct Configuration: Equatable {
    var minimumFrames = 5
    var pixelDeltaThreshold = 28
    var nonBlackThreshold: UInt8 = 40
    var tileSize = 3
    var activeTileChangedRatio = 0.10
    var minimumRegionAreaRatio = 0.012
    var maximumRegionAreaRatio = 0.30
    var minimumRegionAspectRatio = 1.45
    var maximumRegionAspectRatio = 2.05
    var minimumPersistentFillRatio = 0.30
    var minimumClusterPersistentFillRatio = 0.08
    var minimumTemporalUnionFillRatio = 0.08
    var minimumPairComponentSupportRatio = 0.35
    var minimumTemporalPairComponentSupportRatio = 0.06
    /// Temporal union may recover fixed PiP geometry from sparse motion, but
    /// each supporting pair must still cover a meaningful part of both axes.
    /// Otherwise unrelated animations can manufacture a landscape bounding
    /// box only after changes from several moments are combined.
    var minimumTemporalPairHorizontalCoverageRatio = 0.50
    var minimumTemporalPairVerticalCoverageRatio = 0.50
    var minimumPairRegionAreaScale = 0.25
    /// A pair can contain much more connected motion than the persistent
    /// component (for example, a fast scene cut inside the fixed PiP window).
    /// Bound that match by the screen, not by the often-small persistent
    /// subcomponent. This still rejects a whole-screen transition while
    /// allowing legitimate high-motion PiP content.
    var maximumPairRegionAreaRatio = 0.35
    var minimumPairMotionRatio = 0.06
    var minimumFrameNonBlackRatio = 0.20
    var ambiguitySizeRatio = 0.65

    static let physicalPiP = Self()
  }

  var configuration: Configuration = .physicalPiP

  func analyze(_ frames: [PiPMotionFrame]) -> PiPMotionRegionAnalysis {
    guard frames.count >= configuration.minimumFrames else {
      return emptyAnalysis(
        frames: frames,
        failure: .insufficientFrames
      )
    }

    let width = frames[0].width
    let height = frames[0].height
    guard frames.allSatisfy({ $0.width == width && $0.height == height }) else {
      return emptyAnalysis(
        frames: frames,
        failure: .mismatchedFrameDimensions
      )
    }

    let pairCount = frames.count - 1
    let requiredPairCount = max(2, pairCount - 1)
    let tileColumns = divideRoundingUp(width, by: configuration.tileSize)
    let tileRows = divideRoundingUp(height, by: configuration.tileSize)
    let pairData = zip(frames, frames.dropFirst()).map {
      makePairData(
        first: $0,
        second: $1,
        tileColumns: tileColumns,
        tileRows: tileRows
      )
    }
    let pairComponents = pairData.map {
      connectedComponents(
        in: $0.activeTiles,
        columns: tileColumns,
        rows: tileRows
      )
    }

    var persistentCounts = [Int](repeating: 0, count: tileColumns * tileRows)
    for data in pairData {
      for (index, active) in data.activeTiles.enumerated() where active {
        persistentCounts[index] += 1
      }
    }

    let persistentTiles = persistentCounts.map { $0 >= requiredPairCount }
    let persistentComponents = connectedComponents(
      in: persistentTiles,
      columns: tileColumns,
      rows: tileRows
    )
    var componentsToEvaluate = persistentComponents.map { (component: $0, isCluster: false) }
    if persistentComponents.count > 1 {
      componentsToEvaluate.append(
        (component: combinedComponent(persistentComponents), isCluster: true)
      )
    }
    let evaluatedPersistentComponents = componentsToEvaluate.map {
      evaluate(
        component: $0.component,
        frameWidth: width,
        frameHeight: height,
        tileColumns: tileColumns,
        minimumFillRatio: $0.isCluster
          ? configuration.minimumClusterPersistentFillRatio
          : configuration.minimumPersistentFillRatio
      )
    }
    let persistentCandidates = evaluatedPersistentComponents
      .filter(\.isPiPSized)
      .sorted {
        if $0.component.indices.count == $1.component.indices.count {
          return $0.region.area > $1.region.area
        }
        return $0.component.indices.count > $1.component.indices.count
      }

    // Some real PiP fixtures deliberately keep most pixels static and move a
    // diagonal, timestamp, checker, and a few markers. Requiring the exact
    // same tiles to change in four of five pairs reduces that truthful window
    // to a small non-16:9 fragment. The temporal fallback may recover geometry
    // around a connected component that persists for the required pair count.
    //
    // A raw union of every active tile is unsafe: one transient bridge can join
    // unrelated animations, after which disconnected corner motion can box a
    // convincing landscape region. Instead, each candidate carries a stable
    // identity core. Only pair components connected to that same core may
    // contribute geometry or satisfy the per-pair support gate below.
    var evaluatedTemporalComponents: [EvaluatedComponent] = []
    for identityCore in persistentComponents {
      let identityIndices = Set(identityCore.indices)
      let identityPairComponents = pairComponents.compactMap { components in
        let matches = components.filter {
          $0.indices.contains(where: identityIndices.contains)
        }
        return matches.isEmpty ? nil : combinedComponent(matches)
      }
      // A bridge visible in only one captured frame changes both on arrival
      // and departure, so it can contaminate two adjacent frame-pairs. Bounds
      // must therefore be independently reached by a core-connected component
      // in at least three pairs. Pixels may still move within those supported
      // bounds; demanding the exact same sparse pixels would defeat the
      // temporal fallback.
      if
        let component = temporallyPersistentComponent(
          identityPairComponents,
          minimumBoundSupport: min(3, requiredPairCount),
          tileColumns: tileColumns
        ) {
        let evaluated = evaluate(
          component: component,
          frameWidth: width,
          frameHeight: height,
          tileColumns: tileColumns,
          minimumFillRatio: configuration.minimumTemporalUnionFillRatio,
          identityCoreIndices: identityCore.indices
        )
        if
          let duplicate = evaluatedTemporalComponents.firstIndex(where: {
            Set($0.component.indices) == Set(evaluated.component.indices)
          }) {
          if
            evaluated.identityCoreIndices.count
            > evaluatedTemporalComponents[duplicate].identityCoreIndices.count {
            evaluatedTemporalComponents[duplicate] = evaluated
          }
        } else {
          evaluatedTemporalComponents.append(evaluated)
        }
      }
    }
    let temporalCandidates = evaluatedTemporalComponents
      .filter(\.isPiPSized)
      .sorted {
        if $0.component.indices.count == $1.component.indices.count {
          return $0.region.area > $1.region.area
        }
        return $0.component.indices.count > $1.component.indices.count
      }
    let largestAreaRatio = (
      evaluatedPersistentComponents.map(\.areaRatio)
        + evaluatedTemporalComponents.map(\.areaRatio)
    ).max() ?? 0

    let candidates: [EvaluatedComponent]
    let candidateSource: PiPMotionRegionAnalysis.CandidateSource
    if !persistentCandidates.isEmpty {
      candidates = persistentCandidates
      candidateSource = .persistentIntersection
    } else {
      candidates = temporalCandidates
      candidateSource = .temporalUnion
    }

    guard let candidate = candidates.first else {
      return analysis(
        width: width,
        height: height,
        region: nil,
        candidateSource: nil,
        failure: .noStablePiPSizedComponent,
        requiredPairCount: requiredPairCount,
        persistentComponentCount: persistentComponents.count,
        largestAreaRatio: largestAreaRatio
      )
    }

    if
      candidates.count > 1,
      Double(candidates[1].component.indices.count)
      >= Double(candidate.component.indices.count) * configuration.ambiguitySizeRatio {
      return analysis(
        width: width,
        height: height,
        region: candidate.region,
        candidateSource: candidateSource,
        failure: .ambiguousMotionRegions,
        requiredPairCount: requiredPairCount,
        persistentComponentCount: persistentComponents.count,
        regionAreaRatio: candidate.areaRatio,
        regionAspectRatio: candidate.aspectRatio,
        persistentFillRatio: candidate.fillRatio,
        largestAreaRatio: largestAreaRatio
      )
    }

    let candidateIndices = Set(candidate.component.indices)
    let identityIndices = candidateSource == .temporalUnion
      ? Set(candidate.identityCoreIndices)
      : candidateIndices
    let minimumPairComponentSupportRatio = candidateSource == .temporalUnion
      ? configuration.minimumTemporalPairComponentSupportRatio
      : configuration.minimumPairComponentSupportRatio
    var matchingRegions: [PiPMotionRegion] = []
    var matchingPairCount = 0
    var pairMotionRatios: [Double] = []
    var sustainedMotionPairCount = 0

    for (data, components) in zip(pairData, pairComponents) {
      let matchingComponents = components.filter {
        $0.indices.contains { identityIndices.contains($0) }
      }
      let match = matchingComponents.isEmpty ? nil : combinedComponent(matchingComponents)
      let overlap = match?.indices.count { candidateIndices.contains($0) } ?? 0
      let supportRatio = Double(overlap) / Double(max(1, candidate.component.indices.count))
      let motionRatio = changedRatio(
        in: candidate.region,
        changedPixels: data.changedPixels,
        frameWidth: width
      )
      pairMotionRatios.append(motionRatio)

      if let match {
        let matchedRegion = region(
          for: match,
          frameWidth: width,
          frameHeight: height,
          tileColumns: tileColumns
        )
        let areaScale = Double(matchedRegion.area) / Double(candidate.region.area)
        let matchedAreaRatio = Double(matchedRegion.area) / Double(width * height)
        let horizontalCoverage = axisCoverage(
          minimum: matchedRegion.x,
          maximum: matchedRegion.maxX,
          candidateMinimum: candidate.region.x,
          candidateMaximum: candidate.region.maxX
        )
        let verticalCoverage = axisCoverage(
          minimum: matchedRegion.y,
          maximum: matchedRegion.maxY,
          candidateMinimum: candidate.region.y,
          candidateMaximum: candidate.region.maxY
        )
        let temporalCoverageIsSufficient = candidateSource != .temporalUnion
          || (
            horizontalCoverage
              >= configuration.minimumTemporalPairHorizontalCoverageRatio
              && verticalCoverage
              >= configuration.minimumTemporalPairVerticalCoverageRatio
          )
        guard
          supportRatio >= minimumPairComponentSupportRatio,
          areaScale >= configuration.minimumPairRegionAreaScale,
          matchedAreaRatio <= configuration.maximumPairRegionAreaRatio,
          temporalCoverageIsSufficient
        else { continue }

        matchingPairCount += 1
        matchingRegions.append(matchedRegion)
        if motionRatio >= configuration.minimumPairMotionRatio {
          sustainedMotionPairCount += 1
        }
      }
    }

    let horizontalDrift = centerDrift(
      matchingRegions.map(\.centerX),
      relativeTo: candidate.region.width
    )
    let verticalDrift = centerDrift(
      matchingRegions.map(\.centerY),
      relativeTo: candidate.region.height
    )
    let nonBlackRatios = frames.map {
      nonBlackRatio(in: candidate.region, frame: $0)
    }
    let nonBlackFrameCount = nonBlackRatios.count {
      $0 >= configuration.minimumFrameNonBlackRatio
    }
    let requiredNonBlackFrameCount = max(2, frames.count - 1)

    let failure: PiPMotionRegionAnalysis.Failure? = if matchingPairCount < requiredPairCount {
      .unstableRegion
    } else if sustainedMotionPairCount < requiredPairCount {
      .insufficientSustainedMotion
    } else if nonBlackFrameCount < requiredNonBlackFrameCount {
      .insufficientNonBlackContent
    } else {
      nil
    }

    return PiPMotionRegionAnalysis(
      frameWidth: width,
      frameHeight: height,
      region: candidate.region,
      candidateSource: candidateSource,
      failure: failure,
      pairMotionRatios: pairMotionRatios,
      frameNonBlackRatios: nonBlackRatios,
      requiredPairCount: requiredPairCount,
      requiredNonBlackFrameCount: requiredNonBlackFrameCount,
      matchingPairCount: matchingPairCount,
      sustainedMotionPairCount: sustainedMotionPairCount,
      nonBlackFrameCount: nonBlackFrameCount,
      persistentComponentCount: persistentComponents.count,
      regionAreaRatio: candidate.areaRatio,
      regionAspectRatio: candidate.aspectRatio,
      persistentFillRatio: candidate.fillRatio,
      horizontalCenterDriftRatio: horizontalDrift,
      verticalCenterDriftRatio: verticalDrift,
      largestPersistentComponentAreaRatio: largestAreaRatio
    )
  }
}

extension PiPMotionRegionAnalyzer {
  fileprivate struct PairData {
    let changedPixels: [Bool]
    let activeTiles: [Bool]
  }

  fileprivate struct TileComponent {
    let indices: [Int]
    let minimumColumn: Int
    let maximumColumn: Int
    let minimumRow: Int
    let maximumRow: Int
  }

  fileprivate struct EvaluatedComponent {
    let component: TileComponent
    let region: PiPMotionRegion
    let areaRatio: Double
    let aspectRatio: Double
    let fillRatio: Double
    let isPiPSized: Bool
    let identityCoreIndices: [Int]
  }

  private func makePairData(
    first: PiPMotionFrame,
    second: PiPMotionFrame,
    tileColumns: Int,
    tileRows: Int
  ) -> PairData {
    let changedPixels = zip(first.pixels, second.pixels).map {
      $0.differs(from: $1, threshold: configuration.pixelDeltaThreshold)
    }
    var activeTiles = [Bool](repeating: false, count: tileColumns * tileRows)

    for row in 0..<tileRows {
      for column in 0..<tileColumns {
        let minimumX = column * configuration.tileSize
        let minimumY = row * configuration.tileSize
        let maximumX = min(first.width, minimumX + configuration.tileSize)
        let maximumY = min(first.height, minimumY + configuration.tileSize)
        var changedCount = 0
        var sampleCount = 0

        for y in minimumY..<maximumY {
          for x in minimumX..<maximumX {
            sampleCount += 1
            if changedPixels[y * first.width + x] {
              changedCount += 1
            }
          }
        }

        let changedRatio = Double(changedCount) / Double(max(1, sampleCount))
        activeTiles[row * tileColumns + column] =
          changedRatio >= configuration.activeTileChangedRatio
      }
    }

    return PairData(changedPixels: changedPixels, activeTiles: activeTiles)
  }

  private func connectedComponents(
    in mask: [Bool],
    columns: Int,
    rows: Int
  ) -> [TileComponent] {
    var visited = [Bool](repeating: false, count: mask.count)
    var result: [TileComponent] = []

    for start in mask.indices where mask[start] && !visited[start] {
      visited[start] = true
      var queue = [start]
      var nextQueueIndex = 0
      var indices: [Int] = []
      var minimumColumn = columns
      var maximumColumn = 0
      var minimumRow = rows
      var maximumRow = 0

      while nextQueueIndex < queue.count {
        let index = queue[nextQueueIndex]
        nextQueueIndex += 1
        indices.append(index)
        let column = index % columns
        let row = index / columns
        minimumColumn = min(minimumColumn, column)
        maximumColumn = max(maximumColumn, column)
        minimumRow = min(minimumRow, row)
        maximumRow = max(maximumRow, row)

        for rowOffset in -1...1 {
          for columnOffset in -1...1 where rowOffset != 0 || columnOffset != 0 {
            let neighborColumn = column + columnOffset
            let neighborRow = row + rowOffset
            guard
              neighborColumn >= 0,
              neighborColumn < columns,
              neighborRow >= 0,
              neighborRow < rows
            else { continue }

            let neighbor = neighborRow * columns + neighborColumn
            guard mask[neighbor], !visited[neighbor] else { continue }
            visited[neighbor] = true
            queue.append(neighbor)
          }
        }
      }

      result.append(
        TileComponent(
          indices: indices,
          minimumColumn: minimumColumn,
          maximumColumn: maximumColumn,
          minimumRow: minimumRow,
          maximumRow: maximumRow
        )
      )
    }

    return result
  }

  private func evaluate(
    component: TileComponent,
    frameWidth: Int,
    frameHeight: Int,
    tileColumns: Int,
    minimumFillRatio: Double,
    identityCoreIndices: [Int] = []
  ) -> EvaluatedComponent {
    let componentRegion = region(
      for: component,
      frameWidth: frameWidth,
      frameHeight: frameHeight,
      tileColumns: tileColumns
    )
    let areaRatio = Double(componentRegion.area) / Double(frameWidth * frameHeight)
    let aspectRatio = Double(componentRegion.width) / Double(componentRegion.height)
    let tileBoundsArea = (component.maximumColumn - component.minimumColumn + 1)
      * (component.maximumRow - component.minimumRow + 1)
    let fillRatio = Double(component.indices.count) / Double(tileBoundsArea)
    let isPiPSized = areaRatio >= configuration.minimumRegionAreaRatio
      && areaRatio <= configuration.maximumRegionAreaRatio
      && aspectRatio >= configuration.minimumRegionAspectRatio
      && aspectRatio <= configuration.maximumRegionAspectRatio
      && fillRatio >= minimumFillRatio

    return EvaluatedComponent(
      component: component,
      region: componentRegion,
      areaRatio: areaRatio,
      aspectRatio: aspectRatio,
      fillRatio: fillRatio,
      isPiPSized: isPiPSized,
      identityCoreIndices: identityCoreIndices
    )
  }

  private func combinedComponent(_ components: [TileComponent]) -> TileComponent {
    precondition(!components.isEmpty)
    return TileComponent(
      indices: Array(Set(components.flatMap(\.indices))),
      minimumColumn: components.map(\.minimumColumn).min()!,
      maximumColumn: components.map(\.maximumColumn).max()!,
      minimumRow: components.map(\.minimumRow).min()!,
      maximumRow: components.map(\.maximumRow).max()!
    )
  }

  private func temporallyPersistentComponent(
    _ components: [TileComponent],
    minimumBoundSupport: Int,
    tileColumns: Int
  ) -> TileComponent? {
    guard
      minimumBoundSupport > 0,
      components.count >= minimumBoundSupport
    else { return nil }

    let supportIndex = minimumBoundSupport - 1
    let minimumColumn = components.map(\.minimumColumn).sorted()[supportIndex]
    let maximumColumn = components.map(\.maximumColumn).sorted(by: >)[supportIndex]
    let minimumRow = components.map(\.minimumRow).sorted()[supportIndex]
    let maximumRow = components.map(\.maximumRow).sorted(by: >)[supportIndex]
    guard minimumColumn <= maximumColumn, minimumRow <= maximumRow else {
      return nil
    }

    let indices = Array(Set(components.flatMap(\.indices))).filter { index in
      let column = index % tileColumns
      let row = index / tileColumns
      return column >= minimumColumn
        && column <= maximumColumn
        && row >= minimumRow
        && row <= maximumRow
    }
    guard !indices.isEmpty else { return nil }
    return TileComponent(
      indices: indices,
      minimumColumn: minimumColumn,
      maximumColumn: maximumColumn,
      minimumRow: minimumRow,
      maximumRow: maximumRow
    )
  }

  fileprivate func region(
    for component: TileComponent,
    frameWidth: Int,
    frameHeight: Int,
    tileColumns _: Int
  ) -> PiPMotionRegion {
    let minimumX = component.minimumColumn * configuration.tileSize
    let minimumY = component.minimumRow * configuration.tileSize
    let maximumX = min(
      frameWidth,
      (component.maximumColumn + 1) * configuration.tileSize
    )
    let maximumY = min(
      frameHeight,
      (component.maximumRow + 1) * configuration.tileSize
    )
    return PiPMotionRegion(
      x: minimumX,
      y: minimumY,
      width: maximumX - minimumX,
      height: maximumY - minimumY
    )
  }

  private func changedRatio(
    in region: PiPMotionRegion,
    changedPixels: [Bool],
    frameWidth: Int
  ) -> Double {
    var changedCount = 0
    for y in region.y..<region.maxY {
      for x in region.x..<region.maxX where changedPixels[y * frameWidth + x] {
        changedCount += 1
      }
    }
    return Double(changedCount) / Double(max(1, region.area))
  }

  private func nonBlackRatio(
    in region: PiPMotionRegion,
    frame: PiPMotionFrame
  ) -> Double {
    var nonBlackCount = 0
    for y in region.y..<region.maxY {
      for x in region.x..<region.maxX
        where frame.pixels[y * frame.width + x]
        .isNonBlack(threshold: configuration.nonBlackThreshold) {
        nonBlackCount += 1
      }
    }
    return Double(nonBlackCount) / Double(max(1, region.area))
  }

  private func centerDrift(_ centers: [Double], relativeTo extent: Int) -> Double {
    guard let minimum = centers.min(), let maximum = centers.max() else {
      return .infinity
    }
    return (maximum - minimum) / Double(max(1, extent))
  }

  private func axisCoverage(
    minimum: Int,
    maximum: Int,
    candidateMinimum: Int,
    candidateMaximum: Int
  ) -> Double {
    let overlap = max(
      0,
      min(maximum, candidateMaximum) - max(minimum, candidateMinimum)
    )
    return Double(overlap) / Double(max(1, candidateMaximum - candidateMinimum))
  }

  private func divideRoundingUp(_ value: Int, by divisor: Int) -> Int {
    (value + divisor - 1) / divisor
  }

  private func emptyAnalysis(
    frames: [PiPMotionFrame],
    failure: PiPMotionRegionAnalysis.Failure
  ) -> PiPMotionRegionAnalysis {
    analysis(
      width: frames.first?.width ?? 0,
      height: frames.first?.height ?? 0,
      region: nil,
      failure: failure,
      requiredPairCount: max(2, frames.count - 2),
      persistentComponentCount: 0,
      largestAreaRatio: 0
    )
  }

  private func analysis(
    width: Int,
    height: Int,
    region: PiPMotionRegion?,
    candidateSource: PiPMotionRegionAnalysis.CandidateSource? = nil,
    failure: PiPMotionRegionAnalysis.Failure,
    requiredPairCount: Int,
    persistentComponentCount: Int,
    regionAreaRatio: Double = 0,
    regionAspectRatio: Double = 0,
    persistentFillRatio: Double = 0,
    largestAreaRatio: Double
  ) -> PiPMotionRegionAnalysis {
    PiPMotionRegionAnalysis(
      frameWidth: width,
      frameHeight: height,
      region: region,
      candidateSource: candidateSource,
      failure: failure,
      pairMotionRatios: [],
      frameNonBlackRatios: [],
      requiredPairCount: requiredPairCount,
      requiredNonBlackFrameCount: requiredPairCount + 1,
      matchingPairCount: 0,
      sustainedMotionPairCount: 0,
      nonBlackFrameCount: 0,
      persistentComponentCount: persistentComponentCount,
      regionAreaRatio: regionAreaRatio,
      regionAspectRatio: regionAspectRatio,
      persistentFillRatio: persistentFillRatio,
      horizontalCenterDriftRatio: 0,
      verticalCenterDriftRatio: 0,
      largestPersistentComponentAreaRatio: largestAreaRatio
    )
  }
}
