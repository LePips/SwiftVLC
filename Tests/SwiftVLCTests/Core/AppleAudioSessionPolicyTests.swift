@testable import SwiftVLC
import CLibVLC
import CustomDump
import Foundation
import Testing

#if os(iOS) || os(macOS)
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
#endif

extension Integration {
  struct AppleAudioSessionPolicyTests {
    private let lifecycleArguments = ["--no-video", "--no-audio", "--quiet"]

    @Test
    func `VLCInstance defaults to library-managed ownership`() throws {
      let instance = try VLCInstance(arguments: lifecycleArguments)

      expectNoDifference(instance.appleAudioSessionPolicy, .libraryManaged)
      try expectNoDifference(
        instance.arguments,
        VLCInstance.arguments(
          lifecycleArguments,
          applying: .libraryManaged,
          nativeExtensionVersion: swiftvlc_libvlc_pip_extensions_version()
        )
      )
    }

    @Test
    func `Version 8 propagates the default policy as one canonical argument`() throws {
      let resolved = try VLCInstance.arguments(
        VLCInstance.defaultArguments,
        applying: .libraryManaged,
        nativeExtensionVersion: 8
      )

      expectNoDifference(
        resolved,
        VLCInstance.defaultArguments + [
          "--apple-audio-session-management=library"
        ]
      )
    }

    @Test
    func `Version 8 propagates application ownership as one canonical argument`() throws {
      let resolved = try VLCInstance.arguments(
        lifecycleArguments,
        applying: .applicationManaged,
        nativeExtensionVersion: 8
      )

      expectNoDifference(
        resolved,
        lifecycleArguments + [
          "--apple-audio-session-management=application"
        ]
      )
    }

    @Test
    func `Released native versions preserve implicit library management`() throws {
      let resolved = try VLCInstance.arguments(
        lifecycleArguments,
        applying: .libraryManaged,
        nativeExtensionVersion: 7
      )

      expectNoDifference(resolved, lifecycleArguments)
    }

    @Test
    func `Released native versions reject unsupported application ownership`() {
      #expect(
        throws: VLCError.operationFailed(
          "Create VLCInstance with application-managed Apple audio session: "
            + "linked libVLC extension version 7 is older than required version 8"
        )
      ) {
        _ = try VLCInstance.arguments(
          lifecycleArguments,
          applying: .applicationManaged,
          nativeExtensionVersion: 7
        )
      }
    }

    @Test(
      .enabled(
        if: !VLCInstance.supportsApplicationManagedAppleAudioSession,
        "Current archive is already extension version 8 or newer"
      )
    )
    func `Current pre-version-8 archive rejects before libVLC sees an unknown option`() {
      let nativeVersion = swiftvlc_libvlc_pip_extensions_version()

      #expect(
        throws: VLCError.operationFailed(
          "Create VLCInstance with application-managed Apple audio session: "
            + "linked libVLC extension version \(nativeVersion) is older than required version 8"
        )
      ) {
        _ = try VLCInstance(
          arguments: lifecycleArguments,
          appleAudioSessionPolicy: .applicationManaged
        )
      }
    }

    @Test(
      arguments: [
        "--apple-audio-session-management",
        "--apple-audio-session-management=library",
        "--apple-audio-session-management=application",
        "--no-apple-audio-session-management",
        "--noapple-audio-session-management=true"
      ]
    )
    func `Raw ownership options are rejected in favor of the typed policy`(
      argument: String
    ) {
      #expect(
        throws: VLCError.invalidInput(
          "arguments must not contain --apple-audio-session-management; "
            + "use appleAudioSessionPolicy instead"
        )
      ) {
        _ = try VLCInstance(
          arguments: lifecycleArguments + [argument],
          appleAudioSessionPolicy: .libraryManaged
        )
      }
    }

    @Test
    @MainActor
    func `Player exposes the policy inherited from its instance`() throws {
      let instance = try VLCInstance(arguments: lifecycleArguments)
      let player = Player(instance: instance)

      expectNoDifference(player.appleAudioSessionPolicy, .libraryManaged)
      expectNoDifference(
        player.appleAudioSessionPolicy,
        instance.appleAudioSessionPolicy
      )
    }

    @Test(
      .enabled(
        if: VLCInstance.supportsApplicationManagedAppleAudioSession,
        "Requires the extension-version-8 native audio-session contract"
      )
    )
    @MainActor
    func `Player inherits application ownership from a version 8 instance`() throws {
      let instance = try VLCInstance(
        arguments: lifecycleArguments,
        appleAudioSessionPolicy: .applicationManaged
      )
      let player = Player(instance: instance)

      expectNoDifference(player.appleAudioSessionPolicy, .applicationManaged)
      expectNoDifference(
        instance.arguments.last,
        "--apple-audio-session-management=application"
      )
    }

    @Test(
      .enabled(
        if: VLCInstance.supportsApplicationManagedAppleAudioSession,
        "Requires the extension-version-8 native audio-session contract"
      )
    )
    func `Simultaneously live instances retain independent ownership policies`() throws {
      let libraryManaged = try VLCInstance(
        arguments: lifecycleArguments,
        appleAudioSessionPolicy: .libraryManaged
      )
      let applicationManaged = try VLCInstance(
        arguments: lifecycleArguments,
        appleAudioSessionPolicy: .applicationManaged
      )

      expectNoDifference(
        libraryManaged.appleAudioSessionPolicy,
        .libraryManaged
      )
      expectNoDifference(
        applicationManaged.appleAudioSessionPolicy,
        .applicationManaged
      )
      expectNoDifference(
        libraryManaged.arguments.last,
        "--apple-audio-session-management=library"
      )
      expectNoDifference(
        applicationManaged.arguments.last,
        "--apple-audio-session-management=application"
      )
    }

    @Test
    func `Legacy PiP conflicts resolve to the immutable instance owner`() {
      expectNoDifference(
        AppleAudioSessionPolicy.libraryManaged.resolvingLegacyPiPOverride(false),
        AppleAudioSessionPolicyResolution(
          managesAudioSession: true,
          diagnostic: .ignoredLegacyPiPOverride(
            requestedManagement: false,
            inheritedPolicy: .libraryManaged
          )
        )
      )
      expectNoDifference(
        AppleAudioSessionPolicy.applicationManaged.resolvingLegacyPiPOverride(true),
        AppleAudioSessionPolicyResolution(
          managesAudioSession: false,
          diagnostic: .ignoredLegacyPiPOverride(
            requestedManagement: true,
            inheritedPolicy: .applicationManaged
          )
        )
      )
      expectNoDifference(
        AppleAudioSessionPolicy.applicationManaged.resolvingLegacyPiPOverride(false),
        AppleAudioSessionPolicyResolution(
          managesAudioSession: false,
          diagnostic: nil
        )
      )
    }
  }
}

#if os(iOS) || os(macOS)
extension Integration {
  @Suite(.tags(.mainActor))
  @MainActor struct AppleAudioSessionPiPPolicyTests {
    private let lifecycleArguments = ["--no-video", "--no-audio", "--quiet"]

    @Test
    func `Direct PiP controller derives library ownership from Player`() throws {
      let instance = try VLCInstance(arguments: lifecycleArguments)
      let player = Player(instance: instance)
      let controller = PiPController(player: player)

      expectNoDifference(controller.managesAudioSession, true)
      expectNoDifference(controller.audioSessionPolicyDiagnostic, nil)
    }

    @Test(
      .enabled(
        if: VLCInstance.supportsApplicationManagedAppleAudioSession,
        "Requires the extension-version-8 native audio-session contract"
      )
    )
    func `Direct PiP controller derives application ownership from Player`() throws {
      let instance = try VLCInstance(
        arguments: lifecycleArguments,
        appleAudioSessionPolicy: .applicationManaged
      )
      let player = Player(instance: instance)
      let controller = PiPController(player: player)

      expectNoDifference(controller.managesAudioSession, false)
      expectNoDifference(controller.audioSessionPolicyDiagnostic, nil)
    }

    @Test(
      .enabled(
        if: VLCInstance.supportsApplicationManagedAppleAudioSession,
        "Requires the extension-version-8 native audio-session contract"
      )
    )
    func `PiPVideoView derives application ownership from Player`() async throws {
      let instance = try VLCInstance(
        arguments: lifecycleArguments,
        appleAudioSessionPolicy: .applicationManaged
      )
      let player = Player(instance: instance)
      let result = try await host(player: player)

      expectNoDifference(result.controller.managesAudioSession, false)
      expectNoDifference(result.controller.audioSessionPolicyDiagnostic, nil)
      withExtendedLifetime(result.host) {}
    }

    #if canImport(AppKit)
    @Test
    @available(*, deprecated, message: "Exercises the pre-1.1 compatibility initializer")
    func `PiPVideoView legacy conflict is nonfatal and instance policy wins`() async throws {
      let instance = try VLCInstance(arguments: lifecycleArguments)
      let player = Player(instance: instance)
      let result = try await legacyHost(
        player: player,
        managesAudioSession: false
      )

      expectNoDifference(result.controller.managesAudioSession, true)
      expectNoDifference(
        result.controller.audioSessionPolicyDiagnostic,
        .ignoredLegacyPiPOverride(
          requestedManagement: false,
          inheritedPolicy: .libraryManaged
        )
      )
      withExtendedLifetime(result.host) {}
    }
    #endif

    private func host(player: Player)
      async throws -> (host: AnyObject, controller: PiPController) {
      let storage = AppleAudioSessionControllerBox()
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      return try await host(
        rootView: PiPVideoView(player, controller: binding),
        storage: storage
      )
    }

    #if canImport(AppKit)
    @available(*, deprecated, message: "Exercises the pre-1.1 compatibility initializer")
    private func legacyHost(
      player: Player,
      managesAudioSession: Bool
    )
      async throws -> (host: AnyObject, controller: PiPController) {
      let storage = AppleAudioSessionControllerBox()
      let binding = Binding<PiPController?>(
        get: { storage.value },
        set: { storage.value = $0 }
      )
      return try await host(
        rootView: PiPVideoView(
          player,
          controller: binding,
          managesAudioSession: managesAudioSession
        ),
        storage: storage
      )
    }
    #endif

    private func host(
      rootView: PiPVideoView,
      storage: AppleAudioSessionControllerBox
    )
      async throws -> (host: AnyObject, controller: PiPController) {
      #if canImport(UIKit)
      let host = UIHostingController(rootView: rootView)
      host.loadViewIfNeeded()
      host.view.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
      host.view.layoutIfNeeded()
      #elseif canImport(AppKit)
      let host = NSHostingView(rootView: rootView)
      host.frame = NSRect(x: 0, y: 0, width: 320, height: 180)
      host.layoutSubtreeIfNeeded()
      #endif

      for _ in 0..<20 where storage.value == nil {
        await Task.yield()
      }

      return try (host, #require(storage.value))
    }
  }
}

@MainActor
private final class AppleAudioSessionControllerBox {
  var value: PiPController?
}
#endif
