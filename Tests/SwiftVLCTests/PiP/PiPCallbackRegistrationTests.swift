#if os(iOS) || os(macOS)
@testable import SwiftVLC
import AVFoundation
import CoreMedia
import Foundation
import Synchronization
import Testing

private enum DirectPiPCallbackOperation: Equatable {
  case install(UInt)
  case clear(UInt)
}

private enum DirectPiPNativeCallbackOperation: Equatable {
  case atomicV2Install(UInt)
  case atomicV2Clear(UInt)
  case atomicInstall(UInt)
  case atomicClear(UInt)
  case legacyInstall(UInt)
  case legacyClear(UInt)
}

@MainActor
private final class DirectPiPNativeCallbackRecorder {
  let atomicV2Available: Bool
  let atomicAvailable: Bool
  private var atomicV2Results: [Int32]
  private var atomicResults: [Int32]
  private(set) var operations: [DirectPiPNativeCallbackOperation] = []

  init(
    atomicV2Available: Bool = false,
    atomicAvailable: Bool,
    atomicV2Results: [Int32] = [],
    atomicResults: [Int32] = []
  ) {
    self.atomicV2Available = atomicV2Available
    self.atomicAvailable = atomicAvailable
    self.atomicV2Results = atomicV2Results
    self.atomicResults = atomicResults
  }

  var nativeAPI: DirectPiPVideoCallbackNativeAPI {
    DirectPiPVideoCallbackNativeAPI(
      atomicV2CallbacksAvailable: { [atomicV2Available] in atomicV2Available },
      publishAtomicV2: { [weak self] handle, opaque in
        guard let self else { return -1 }
        let address = UInt(bitPattern: handle)
        operations.append(
          opaque == nil ? .atomicV2Clear(address) : .atomicV2Install(address)
        )
        return atomicV2Results.isEmpty ? 0 : atomicV2Results.removeFirst()
      },
      atomicCallbacksAvailable: { [atomicAvailable] in atomicAvailable },
      publishAtomic: { [weak self] handle, opaque in
        guard let self else { return -1 }
        let address = UInt(bitPattern: handle)
        operations.append(
          opaque == nil ? .atomicClear(address) : .atomicInstall(address)
        )
        return atomicResults.isEmpty ? 0 : atomicResults.removeFirst()
      },
      installLegacy: { [weak self] handle, _ in
        self?.operations.append(.legacyInstall(UInt(bitPattern: handle)))
      },
      clearLegacy: { [weak self] handle in
        self?.operations.append(.legacyClear(UInt(bitPattern: handle)))
      }
    )
  }
}

@MainActor
private final class DirectPiPCallbackRecorder {
  private(set) var operations: [DirectPiPCallbackOperation] = []
  private(set) var installedHandles: [UInt] = []
  private(set) var installedOpaques: [UInt] = []
  private(set) var clearedHandles: [UInt] = []
  private var installResults: [Bool]
  private var clearResults: [Bool]
  private let installedABI: DirectPiPVideoCallbackABI

  init(
    installResults: [Bool] = [],
    clearResults: [Bool] = [],
    installedABI: DirectPiPVideoCallbackABI = .atomicV1
  ) {
    self.installResults = installResults
    self.clearResults = clearResults
    self.installedABI = installedABI
  }

  var api: DirectPiPVideoCallbackAPI {
    DirectPiPVideoCallbackAPI(
      preferredABI: { [installedABI] in installedABI },
      install: { [weak self] handle, opaque, _ in
        let address = UInt(bitPattern: handle)
        self?.operations.append(.install(address))
        self?.installedHandles.append(address)
        self?.installedOpaques.append(UInt(bitPattern: opaque))
        return self?.takeInstallResult() ?? false
      },
      clear: { [weak self] handle, _ in
        let address = UInt(bitPattern: handle)
        self?.operations.append(.clear(address))
        self?.clearedHandles.append(address)
        return self?.takeClearResult() ?? false
      }
    )
  }

  private func takeInstallResult() -> Bool {
    installResults.isEmpty ? true : installResults.removeFirst()
  }

  private func takeClearResult() -> Bool {
    clearResults.isEmpty ? true : clearResults.removeFirst()
  }
}

@MainActor
private final class WeakPiPControllerProbe {
  weak var controller: PiPController?

  init(_ controller: PiPController) {
    self.controller = controller
  }
}

/// Keeps controller construction and release outside the async test's
/// coroutine frame, whose retained temporaries are not an ARC boundary.
@MainActor
private func makeDroppedPiPControllerProbe(player: Player) -> WeakPiPControllerProbe {
  autoreleasepool {
    let controller = PiPController(player: player)
    return WeakPiPControllerProbe(controller)
  }
}

extension Integration {
  /// Deterministic coverage for direct `PiPController` vmem registration.
  /// The tests inject native install/clear operations, so ownership races are
  /// asserted as exact handle/generation transitions rather than inferred
  /// from a real vout's timing.
  @Suite(.tags(.mainActor, .async), .serialized)
  @MainActor struct PiPCallbackRegistrationTests {
    @Test
    func `Atomic v2 publishes one timestamp-bearing install and clear generation`() throws {
      let recorder = DirectPiPNativeCallbackRecorder(
        atomicV2Available: true,
        atomicAvailable: true,
        atomicV2Results: [0, 0]
      )
      let api = DirectPiPVideoCallbackAPI.resolving(native: recorder.nativeAPI)
      let handle = try #require(OpaquePointer(bitPattern: 0xA706))
      let opaque = try #require(UnsafeMutableRawPointer(bitPattern: 0x0A06))

      #expect(api.preferredABI() == .atomicV2)
      #expect(api.install(handle, opaque, .atomicV2))
      #expect(api.clear(handle, .atomicV2))
      #expect(
        recorder.operations == [
          .atomicV2Install(UInt(bitPattern: handle)),
          .atomicV2Clear(UInt(bitPattern: handle))
        ]
      )
    }

    @Test
    func `Atomic v2 failure never falls through to v4 or legacy publication`() throws {
      let recorder = DirectPiPNativeCallbackRecorder(
        atomicV2Available: true,
        atomicAvailable: true,
        atomicV2Results: [-12]
      )
      let api = DirectPiPVideoCallbackAPI.resolving(native: recorder.nativeAPI)
      let handle = try #require(OpaquePointer(bitPattern: 0xA707))
      let opaque = try #require(UnsafeMutableRawPointer(bitPattern: 0x0A07))

      #expect(api.preferredABI() == .atomicV2)
      #expect(!api.install(handle, opaque, .atomicV2))
      #expect(
        recorder.operations == [.atomicV2Install(UInt(bitPattern: handle))]
      )
    }

    @Test
    func `Atomic v2 clear failure never switches generation API`() throws {
      let recorder = DirectPiPNativeCallbackRecorder(
        atomicV2Available: true,
        atomicAvailable: true,
        atomicV2Results: [0, -12]
      )
      let api = DirectPiPVideoCallbackAPI.resolving(native: recorder.nativeAPI)
      let handle = try #require(OpaquePointer(bitPattern: 0xA708))
      let opaque = try #require(UnsafeMutableRawPointer(bitPattern: 0x0A08))

      #expect(api.preferredABI() == .atomicV2)
      #expect(api.install(handle, opaque, .atomicV2))
      #expect(!api.clear(handle, .atomicV2))
      #expect(
        recorder.operations == [
          .atomicV2Install(UInt(bitPattern: handle)),
          .atomicV2Clear(UInt(bitPattern: handle))
        ]
      )
    }

    @Test
    func `Atomic callback API publishes install and clear as complete generations`() throws {
      let recorder = DirectPiPNativeCallbackRecorder(
        atomicAvailable: true,
        atomicResults: [0, 0]
      )
      let api = DirectPiPVideoCallbackAPI.resolving(native: recorder.nativeAPI)
      let handle = try #require(OpaquePointer(bitPattern: 0xA701))
      let opaque = try #require(UnsafeMutableRawPointer(bitPattern: 0x0A01))

      #expect(api.preferredABI() == .atomicV1)
      #expect(api.install(handle, opaque, .atomicV1))
      #expect(api.clear(handle, .atomicV1))
      #expect(
        recorder.operations == [
          .atomicInstall(UInt(bitPattern: handle)),
          .atomicClear(UInt(bitPattern: handle))
        ]
      )
    }

    @Test
    func `Atomic publication failure never falls back to mixed legacy setters`() throws {
      let recorder = DirectPiPNativeCallbackRecorder(
        atomicAvailable: true,
        atomicResults: [-12]
      )
      let api = DirectPiPVideoCallbackAPI.resolving(native: recorder.nativeAPI)
      let handle = try #require(OpaquePointer(bitPattern: 0xA702))
      let opaque = try #require(UnsafeMutableRawPointer(bitPattern: 0x0A02))

      #expect(api.preferredABI() == .atomicV1)
      #expect(!api.install(handle, opaque, .atomicV1))
      #expect(
        recorder.operations == [.atomicInstall(UInt(bitPattern: handle))]
      )
    }

    @Test
    func `Genuinely unavailable atomic extension uses the complete legacy path`() throws {
      let recorder = DirectPiPNativeCallbackRecorder(atomicAvailable: false)
      let api = DirectPiPVideoCallbackAPI.resolving(native: recorder.nativeAPI)
      let handle = try #require(OpaquePointer(bitPattern: 0xA703))
      let opaque = try #require(UnsafeMutableRawPointer(bitPattern: 0x0A03))

      #expect(api.preferredABI() == .legacy)
      #expect(api.install(handle, opaque, .legacy))
      #expect(api.clear(handle, .legacy))
      #expect(
        recorder.operations == [
          .legacyInstall(UInt(bitPattern: handle)),
          .legacyClear(UInt(bitPattern: handle))
        ]
      )
    }

    @Test
    func `Initial callback installation failure leaves direct PiP unclaimed`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder(installResults: [false])
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      let handle = UInt(bitPattern: player.pointer)

      #expect(!player.claimDirectPiPVideoCallbacks(registration))
      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(player.directPiPVideoCallbackSlot == nil)
      #expect(player.directPiPVideoCallbackGeneration == 0)
      #expect(!registration.isBound)
      #expect(recorder.operations == [.install(handle)])

      await player.shutdown()
    }

    @Test
    func `Stale PiPController cleanup cannot clear newer controller registration`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let first = PiPController(player: player)
      let firstGeneration = player.directPiPVideoCallbackGeneration

      let successor = PiPController(player: player)
      let successorRegistration = try #require(successor.callbackRegistration)
      let successorGeneration = player.directPiPVideoCallbackGeneration
      #expect(successorGeneration > firstGeneration)
      #expect(player.directPiPVideoCallbackRegistration === successorRegistration)

      first.invalidateForLifecycleEnd()

      #expect(player.directPiPVideoCallbackRegistration === successorRegistration)
      #expect(player.directPiPVideoCallbackGeneration == successorGeneration)

      // A delayed or duplicated lifecycle signal must remain a no-op after
      // the stale controller has already relinquished its generation.
      first.invalidateForLifecycleEnd()
      #expect(player.directPiPVideoCallbackRegistration === successorRegistration)
      #expect(player.directPiPVideoCallbackGeneration == successorGeneration)

      successor.invalidateForLifecycleEnd()
      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(player.directPiPVideoCallbackGeneration == successorGeneration &+ 1)

      let clearedGeneration = player.directPiPVideoCallbackGeneration
      successor.invalidateForLifecycleEnd()
      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(player.directPiPVideoCallbackGeneration == clearedGeneration)

      await player.shutdown()
    }

    @Test
    func `PiPController eventually deallocates after synchronous scoped drop`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let probe = makeDroppedPiPControllerProbe(player: player)

      #expect(
        try await poll(
          every: .milliseconds(10),
          timeout: .seconds(2),
          until: { probe.controller == nil }
        ),
        "PiPController remained alive after its synchronous creation scope and autorelease pool ended"
      )

      await player.shutdown()
    }

    @Test
    func `Superseded controller and its late cleanup cannot clear successor callbacks`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let handle = UInt(bitPattern: player.pointer)
      let firstRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())

      let first = DirectPiPVideoCallbackRegistration(
        renderer: firstRenderer,
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(first)
      let firstGeneration = try #require(first.currentGeneration)
      let firstOpaque = try #require(first.currentOpaqueForTesting)
      weak let firstContext = first.currentContextForTesting

      // A vmem output copies its opaque when it opens. Replacing the native
      // variables does not update that already-open copy. Negotiate this vout
      // while the first controller owns the slot, then prove the resulting
      // child opaque dynamically routes display to a successor.
      var opaqueSlot: UnsafeMutableRawPointer? = firstOpaque
      var chroma = [CChar](repeating: 0, count: 4)
      var width: UInt32 = 96
      var height: UInt32 = 54
      var pitch: UInt32 = 0
      var lines: UInt32 = 0
      let bufferCount = withUnsafeMutablePointer(to: &opaqueSlot) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          withUnsafeMutablePointer(to: &width) { widthPointer in
            withUnsafeMutablePointer(to: &height) { heightPointer in
              withUnsafeMutablePointer(to: &pitch) { pitchPointer in
                withUnsafeMutablePointer(to: &lines) { linesPointer in
                  pixelBufferFormatCallback(
                    opaque: opaquePointer,
                    chroma: chromaBuffer.baseAddress,
                    width: widthPointer,
                    height: heightPointer,
                    pitches: pitchPointer,
                    lines: linesPointer
                  )
                }
              }
            }
          }
        }
      }
      #expect(bufferCount > 0)
      let voutOpaque = try #require(opaqueSlot)
      weak var voutContext: PixelBufferRendererVoutCallbackContext?
      voutContext = pixelBufferVoutCallbackContext(from: voutOpaque)
      #expect(voutOpaque != firstOpaque)
      let voutDimensions = try {
        let context = try #require(voutContext)
        return context.decodeRenderer.state.withLock { ($0.width, $0.height) }
      }()
      #expect(voutDimensions == (96, 54))
      #expect(firstRenderer.state.withLock { ($0.width, $0.height) } == (0, 0))

      let successorRenderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
      successorRenderer.setRenderSize(CMVideoDimensions(width: 48, height: 28))
      let successor = DirectPiPVideoCallbackRegistration(renderer: successorRenderer, api: recorder.api)
      player.claimDirectPiPVideoCallbacks(successor)
      let successorGeneration = try #require(successor.currentGeneration)
      let successorOpaque = try #require(successor.currentOpaqueForTesting)
      weak let successorContext = successor.currentContextForTesting

      #expect(successorGeneration > firstGeneration)
      #expect(recorder.installedHandles == [handle])
      #expect(Set(recorder.installedOpaques).count == 1)
      #expect(successorOpaque == firstOpaque)
      #expect(firstContext === successorContext)
      #expect(recorder.clearedHandles.isEmpty)
      #expect(recorder.operations == [.install(handle)])
      #expect(player.directPiPVideoCallbackRegistration === successor)
      #expect(successorRenderer.state.withLock { ($0.width, $0.height) } == (0, 0))

      var plane: UnsafeMutableRawPointer?
      let picture = withUnsafeMutablePointer(to: &plane) {
        pixelBufferLockCallback(opaque: voutOpaque, planes: $0)
      }
      #expect(picture != nil)
      pixelBufferUnlockCallback(opaque: voutOpaque, picture: picture, planes: nil)
      pixelBufferDisplayCallback(opaque: voutOpaque, picture: picture)
      #expect(firstRenderer.state.withLock { $0.renderPool } == nil)
      #expect(
        successorRenderer.state.withLock { ($0.renderPoolWidth, $0.renderPoolHeight) }
          == (48, 28)
      )

      // Stale controller teardown owns neither the Player registry nor the
      // native variables anymore.
      player.relinquishDirectPiPVideoCallbacks(first)

      #expect(recorder.clearedHandles.isEmpty)
      #expect(player.directPiPVideoCallbackRegistration === successor)
      #expect(player.directPiPVideoCallbackGeneration == successorGeneration)
      #expect(firstContext != nil)

      player.relinquishDirectPiPVideoCallbacks(successor)
      #expect(recorder.clearedHandles == [handle])
      #expect(recorder.operations == [.install(handle), .clear(handle)])

      // An already-open vout keeps its per-vout opaque after the media-player
      // callback variables are cleared. A dormant slot keeps that decode
      // storage valid while dropping only display output; a sequential
      // successor then reuses the same handle-level routing opaque.
      var dormantPlane: UnsafeMutableRawPointer?
      let dormantPicture = withUnsafeMutablePointer(to: &dormantPlane) {
        pixelBufferLockCallback(opaque: voutOpaque, planes: $0)
      }
      #expect(dormantPicture != nil)
      #expect(dormantPlane != nil)
      pixelBufferUnlockCallback(
        opaque: voutOpaque,
        picture: dormantPicture,
        planes: nil
      )
      pixelBufferDisplayCallback(opaque: voutOpaque, picture: dormantPicture)
      #expect(firstContext != nil)
      // After this vout's cleanup there can be no later lock from that vout;
      // a racing future vout runs format first and recreates the decode pool.
      pixelBufferCleanupCallback(opaque: voutOpaque)
      #expect(voutContext == nil)
      let third = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(third)
      #expect(third.currentOpaqueForTesting == firstOpaque)
      #expect(third.currentContextForTesting === firstContext)
      #expect(
        recorder.operations == [.install(handle), .clear(handle), .install(handle)]
      )
      player.relinquishDirectPiPVideoCallbacks(third)

      await player.shutdown()
      #expect(player.directPiPVideoCallbackSlot == nil)
      #expect(
        recorder.operations
          == [.install(handle), .clear(handle), .install(handle), .clear(handle)]
      )
      #expect(firstContext == nil)
      #expect(successorContext == nil)
    }

    @Test
    func `Dormant slot is retired instead of copied to a replacement handle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(registration)

      let oldPointer = player.pointer
      let oldHandle = UInt(bitPattern: oldPointer)
      let oldLifetime = player.nativeHandleLifetime
      weak let oldContext = registration.currentContextForTesting
      player.relinquishDirectPiPVideoCallbacks(registration)

      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(player.directPiPVideoCallbackSlot != nil)
      #expect(recorder.operations == [.install(oldHandle), .clear(oldHandle)])

      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()

      #expect(player.pointer != oldPointer)
      #expect(player.directPiPVideoCallbackSlot == nil)
      #expect(recorder.operations == [.install(oldHandle), .clear(oldHandle)])

      try #require(
        await poll(timeout: .seconds(5)) { oldLifetime.isReleased },
        "offloaded release did not finish for the dormant callback slot"
      )
      // The native lifetime being released does not mean the Swift context has
      // deallocated: the final release is queued behind the offloaded teardown,
      // so a bare check here races it. Poll instead, as #121 did for the
      // drawable-release test.
      try #require(
        await poll(timeout: .seconds(5)) { oldContext == nil },
        "the callback context outlived its retired slot"
      )
      await player.shutdown()
    }

    @Test
    func `Native handle replacement installs successor generation before clearing old handle`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let firstRegistration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(firstRegistration)

      let oldPointer = player.pointer
      let oldLifetime = player.nativeHandleLifetime
      let oldHandle = UInt(bitPattern: oldPointer)
      weak let oldContext = firstRegistration.currentContextForTesting
      let oldOpaque = try #require(firstRegistration.currentOpaqueForTesting)
      let firstVoutGeneration = try {
        let context = try #require(oldContext)
        let vout = try #require(
          context.makeVoutContext(
            handleOpaque: oldOpaque,
            decodeRenderer: PixelBufferRenderer(),
            sourceGeometry: PixelBufferSourceGeometry(fullFrameWidth: 2, height: 2)
          )
        )
        defer { context.noteVoutClosed(voutGeneration: vout.voutGeneration) }
        return vout.voutGeneration
      }()

      // A successor controller adopts the same handle-level context. Its
      // later handle replacement must continue that context's vout sequence,
      // not restart from a controller-local counter.
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(registration)
      let oldGeneration = try #require(registration.currentGeneration)
      #expect(registration.currentContextForTesting === oldContext)
      #expect(registration.currentOpaqueForTesting == oldOpaque)

      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()

      let newPointer = player.pointer
      let newHandle = UInt(bitPattern: newPointer)
      let newGeneration = try #require(registration.currentGeneration)
      #expect(newPointer != oldPointer)
      #expect(newGeneration > oldGeneration)
      #expect(recorder.installedHandles == [oldHandle, newHandle])
      #expect(Set(recorder.installedOpaques).count == 2)
      #expect(recorder.clearedHandles == [oldHandle])
      #expect(
        recorder.operations == [.install(oldHandle), .install(newHandle), .clear(oldHandle)]
      )
      #expect(registration.currentLifetime === player.nativeHandleLifetime)
      let newContext = try #require(registration.currentContextForTesting)
      let newOpaque = try #require(registration.currentOpaqueForTesting)
      let secondVoutGeneration = try {
        let vout = try #require(
          newContext.makeVoutContext(
            handleOpaque: newOpaque,
            decodeRenderer: PixelBufferRenderer(),
            sourceGeometry: PixelBufferSourceGeometry(fullFrameWidth: 2, height: 2)
          )
        )
        defer { newContext.noteVoutClosed(voutGeneration: vout.voutGeneration) }
        return vout.voutGeneration
      }()
      #expect(secondVoutGeneration > firstVoutGeneration)

      player.relinquishDirectPiPVideoCallbacks(registration)
      #expect(recorder.clearedHandles == [oldHandle, newHandle])

      await player.shutdown()
      try #require(
        await poll(timeout: .seconds(5)) { oldLifetime.isReleased },
        "offloaded release did not finish for the replaced native handle"
      )
      // Same race as the sibling test above: the native lifetime releasing
      // does not mean the Swift context has deallocated.
      try #require(
        await poll(timeout: .seconds(5)) { oldContext == nil },
        "the callback context outlived the replaced native handle"
      )
    }

    @Test
    func `Replacement install failure retires both routes and revokes direct PiP`() async throws {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder(installResults: [true, false])
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      #expect(player.claimDirectPiPVideoCallbacks(registration))

      let oldPointer = player.pointer
      let oldHandle = UInt(bitPattern: oldPointer)
      let oldLifetime = player.nativeHandleLifetime
      let oldGeneration = player.directPiPVideoCallbackGeneration
      weak let oldContext = registration.currentContextForTesting

      player.setDrawable(NSObject())
      player.stop()
      try player.prepareDrawableForPlayback()

      let newHandle = UInt(bitPattern: player.pointer)
      #expect(newHandle != oldHandle)
      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(player.directPiPVideoCallbackSlot == nil)
      #expect(player.directPiPVideoCallbackGeneration == oldGeneration &+ 1)
      #expect(!registration.isBound)
      #expect(
        recorder.operations == [
          .install(oldHandle),
          .install(newHandle),
          .clear(oldHandle)
        ]
      )

      await player.shutdown()
      try #require(
        await poll(timeout: .seconds(5)) { oldLifetime.isReleased },
        "offloaded release did not finish for the failed callback replacement"
      )
      try #require(
        await poll(timeout: .seconds(5)) { oldContext == nil },
        "the failed callback replacement retained its outgoing context"
      )
    }

    @Test
    func `Player shutdown retires callbacks on the handle being released`() async {
      let player = Player(instance: TestInstance.makeAudioOnly())
      let recorder = DirectPiPCallbackRecorder()
      let registration = DirectPiPVideoCallbackRegistration(
        renderer: PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer()),
        api: recorder.api
      )
      player.claimDirectPiPVideoCallbacks(registration)
      let handle = UInt(bitPattern: player.pointer)
      weak let context = registration.currentContextForTesting

      await player.shutdown()

      #expect(recorder.operations == [.install(handle), .clear(handle)])
      #expect(player.directPiPVideoCallbackRegistration == nil)
      #expect(registration.currentGeneration == nil)
      #expect(context == nil)
    }

    @Test
    func `Failed atomic clear keeps its opaque valid until native handle release`() throws {
      let recorder = DirectPiPCallbackRecorder(
        clearResults: [false],
        installedABI: .atomicV2
      )
      let pointer = try #require(OpaquePointer(bitPattern: 0xD1CE_FA11))
      let lifetime = NativePlayerHandleLifetime(pointer: pointer)
      var retainedOpaque: UnsafeMutableRawPointer?
      weak var context: PixelBufferRendererCallbackContext?

      do {
        let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let slot = DirectPiPVideoCallbackSlot(
          lifetime: lifetime,
          decodeRenderer: renderer,
          api: recorder.api
        )
        #expect(slot.activate(renderer: renderer))
        retainedOpaque = slot.opaque
        context = slot.context
        #expect(!slot.retire())
        #expect(slot.callbacksInstalledForTesting)
        #expect(slot.installedABIForTesting == .atomicV2)
        #expect(slot.context.sourceTimestampTelemetrySnapshot.isAvailable)
      }

      let opaque = try #require(retainedOpaque)
      #expect(context != nil)
      #expect(context?.retirementRequestedForTesting == true)
      #expect(context?.sourceTimestampTelemetrySnapshot.isAvailable == true)
      #expect(
        recorder.operations == [
          .install(UInt(bitPattern: pointer)),
          .clear(UInt(bitPattern: pointer))
        ]
      )

      // The failed clear left this opaque in the published native tuple. A
      // racing future vout may therefore still copy and invoke it. Retirement
      // suppresses display forwarding but must keep decode/cleanup safe.
      var voutOpaque: UnsafeMutableRawPointer? = opaque
      var chroma: [CChar] = Array(repeating: 0, count: 4)
      var width: UInt32 = 96
      var height: UInt32 = 54
      var pitch: UInt32 = 0
      var lines: UInt32 = 0
      let bufferCount = withUnsafeMutablePointer(to: &voutOpaque) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          pixelBufferFormatCallback(
            opaque: opaquePointer,
            chroma: chromaBuffer.baseAddress,
            width: &width,
            height: &height,
            pitches: &pitch,
            lines: &lines
          )
        }
      }
      #expect(bufferCount > 0)
      let childOpaque = try #require(voutOpaque)
      #expect(childOpaque != opaque)
      pixelBufferCleanupCallback(opaque: childOpaque)
      #expect(context != nil)

      lifetime.initialOwnerDidRelease()
      #expect(context == nil)
    }

    @Test
    func `Retired future-vout opaque stays alive until every native owner releases`() throws {
      let recorder = DirectPiPCallbackRecorder()
      let pointer = try #require(OpaquePointer(bitPattern: 0xD1CE_CAFE))
      let lifetime = NativePlayerHandleLifetime(pointer: pointer)
      let listPlayerLease = lifetime.acquireNativeOwnerLease()
      var opaque: UnsafeMutableRawPointer?
      weak var context: PixelBufferRendererCallbackContext?
      do {
        let renderer = PixelBufferRenderer(displayLayer: AVSampleBufferDisplayLayer())
        let slot = DirectPiPVideoCallbackSlot(
          lifetime: lifetime,
          decodeRenderer: renderer,
          api: recorder.api
        )
        slot.activate(renderer: renderer)
        opaque = slot.opaque
        context = slot.context
        slot.retire()
      }
      let retainedOpaque = try #require(opaque)

      #expect(context != nil)
      #expect(context?.retirementRequestedForTesting == true)
      #expect(context?.nativePlayerHandleReleasedForTesting == false)

      // Model another callback arriving after retirement but before vout
      // cleanup and exact native-handle release. Its plane remains valid even
      // though the display target has been removed.
      var opaqueSlot: UnsafeMutableRawPointer? = retainedOpaque
      var chroma: [CChar] = Array(repeating: 0, count: 4)
      var width: UInt32 = 96
      var height: UInt32 = 54
      var pitch: UInt32 = 0
      var lines: UInt32 = 0
      let bufferCount = withUnsafeMutablePointer(to: &opaqueSlot) { opaquePointer in
        chroma.withUnsafeMutableBufferPointer { chromaBuffer in
          pixelBufferFormatCallback(
            opaque: opaquePointer,
            chroma: chromaBuffer.baseAddress,
            width: &width,
            height: &height,
            pitches: &pitch,
            lines: &lines
          )
        }
      }
      #expect(bufferCount > 0)
      let voutOpaque = try #require(opaqueSlot)
      #expect(voutOpaque != retainedOpaque)
      var plane: UnsafeMutableRawPointer?
      let lateLock = withUnsafeMutablePointer(to: &plane) {
        pixelBufferLockCallback(opaque: voutOpaque, planes: $0)
      }
      #expect(lateLock != nil)
      #expect(plane != nil)
      pixelBufferUnlockCallback(opaque: voutOpaque, picture: lateLock, planes: nil)
      pixelBufferDisplayCallback(opaque: voutOpaque, picture: lateLock)
      pixelBufferCleanupCallback(opaque: voutOpaque)
      #expect(context != nil)

      // SwiftVLC releasing its own reference is insufficient: a
      // MediaListPlayer still owns the same handle and can drive a vout.
      lifetime.initialOwnerDidRelease()
      #expect(context != nil)
      #expect(context?.nativePlayerHandleReleasedForTesting == false)

      listPlayerLease.endAfterNativeOwnerRelease()

      #expect(context == nil)
      #expect(recorder.clearedHandles == [UInt(bitPattern: pointer)])
    }
  }
}
#endif
