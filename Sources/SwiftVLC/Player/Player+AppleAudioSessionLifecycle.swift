#if os(iOS)
import AVFoundation
#endif
import CLibVLC
import Foundation

extension Player {
  /// Session disruptions that can make the native audio graph diverge from
  /// SwiftVLC's public transport state.
  ///
  /// Notification ownership lives on `Player`, not `PiPController`: audio-
  /// only playback and ordinary `VideoView` playback need the same reset and
  /// route-loss boundary as PiP playback. These transport protections apply
  /// in application-managed mode too; observing a disruption and pausing VLC
  /// does not configure or activate the host-owned `AVAudioSession`.
  enum ManagedAppleAudioSessionDisruption: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeLost
    case mediaServicesLost
    case mediaServicesReset
  }

  #if os(iOS)
  /// Acquires this player's one exact claim on the process-wide native audio-
  /// session broker.
  ///
  /// AudioUnit, AVSampleBufferAudioRenderer, and Swift PiP all use the same
  /// native owner count. Keeping the opaque token on `Player` makes multiple
  /// transient PiP controllers idempotent and prevents one controller from
  /// deactivating another player's output.
  @discardableResult
  func acquireManagedAppleAudioSessionLeaseIfNeeded() -> Bool {
    guard appleAudioSessionPolicy.managesAudioSession else { return false }

    if managedAppleAudioSessionLease != 0 {
      if managedAppleAudioSessionLeaseOwner == pointer {
        return true
      }
      // A token can only belong to the handle that acquired it. Recover
      // defensively if a future replacement path forgets to transfer the
      // lease. The old pointer may already be destroyed, so do not dereference
      // it here; native player destruction consumes its remaining lease.
      managedAppleAudioSessionLease = 0
      managedAppleAudioSessionLeaseOwner = nil
      invalidateManagedAppleAudioSessionActivationLatches()
    }

    var lease: swiftvlc_apple_audio_session_lease_t = 0
    let result = swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(
      pointer,
      &lease
    )
    guard
      result == Int32(swiftvlc_apple_audio_session_lease_acquired.rawValue),
      lease != 0
    else { return false }

    managedAppleAudioSessionLease = lease
    managedAppleAudioSessionLeaseOwner = pointer
    return true
  }

  /// Consumes the exact token once, clearing Swift state even if the native
  /// broker rejects it as stale after a media-services epoch change.
  ///
  /// Clearing first is intentional: a reset-invalidated token must not block a
  /// later user action from acquiring a new current-epoch lease.
  @discardableResult
  func releaseManagedAppleAudioSessionLeaseIfNeeded() -> Bool {
    guard
      managedAppleAudioSessionLease != 0,
      let owner = managedAppleAudioSessionLeaseOwner
    else { return false }

    let lease = managedAppleAudioSessionLease
    managedAppleAudioSessionLease = 0
    managedAppleAudioSessionLeaseOwner = nil
    return swiftvlc_libvlc_media_player_release_apple_audio_session_lease(
      owner,
      lease
    )
  }

  /// Releases the predecessor claim before terminal native-handle teardown.
  /// Returns whether a claim had been held.
  func relinquishManagedAppleAudioSessionLeaseForHandleReplacement() -> Bool {
    let wasHeld = managedAppleAudioSessionLease != 0
    if wasHeld {
      _ = releaseManagedAppleAudioSessionLeaseIfNeeded()
    }
    return wasHeld
  }

  /// Moves a live claim to a prepared successor without letting the broker's
  /// owner count reach zero between handles. `nil` means no claim existed;
  /// `false` means successor acquisition failed and controller latches must be
  /// invalidated so the next playback signal retries.
  func transferManagedAppleAudioSessionLease(
    to successor: OpaquePointer
  ) -> Bool? {
    guard
      managedAppleAudioSessionLease != 0,
      let predecessor = managedAppleAudioSessionLeaseOwner
    else { return nil }

    let predecessorLease = managedAppleAudioSessionLease
    var successorLease: swiftvlc_apple_audio_session_lease_t = 0
    let result = swiftvlc_libvlc_media_player_acquire_apple_audio_session_lease(
      successor,
      &successorLease
    )
    let acquired = result
      == Int32(swiftvlc_apple_audio_session_lease_acquired.rawValue)
      && successorLease != 0

    // AVAudioSession mutation can synchronously deliver NotificationCenter
    // callbacks. If one invalidated or replaced the predecessor while native
    // acquisition was in flight, this transfer no longer owns the Swift slot.
    // Consume the just-created token instead of resurrecting stale focus.
    guard
      managedAppleAudioSessionLease == predecessorLease,
      managedAppleAudioSessionLeaseOwner == predecessor
    else {
      if acquired {
        _ = swiftvlc_libvlc_media_player_release_apple_audio_session_lease(
          successor,
          successorLease
        )
      }
      return false
    }

    if acquired {
      // Publish the successor token before consuming the predecessor. The
      // native broker already counts both, so the final release cannot
      // deactivate the process session in the transfer window.
      managedAppleAudioSessionLease = successorLease
      managedAppleAudioSessionLeaseOwner = successor
    } else {
      managedAppleAudioSessionLease = 0
      managedAppleAudioSessionLeaseOwner = nil
    }
    _ = swiftvlc_libvlc_media_player_release_apple_audio_session_lease(
      predecessor,
      predecessorLease
    )
    return acquired
  }

  func invalidateManagedAppleAudioSessionActivationLatches() {
    for controller in managedAppleAudioSessionControllers.allObjects {
      controller.hasActivatedAudioSession = false
    }
  }

  func startManagedAppleAudioSessionObservationIfNeeded() {
    guard managedAppleAudioSessionObservers.isEmpty else { return }

    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    managedAppleAudioSessionObservers = [
      center.addObserver(
        forName: AVAudioSession.interruptionNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
        MainActor.assumeIsolated {
          guard
            let self,
            let rawType,
            let type = AVAudioSession.InterruptionType(rawValue: rawType)
          else { return }
          switch type {
          case .began:
            self.handleManagedAppleAudioSessionDisruption(.interruptionBegan)
          case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
            self.handleManagedAppleAudioSessionDisruption(
              .interruptionEnded(shouldResume: options.contains(.shouldResume))
            )
          @unknown default:
            break
          }
        }
      },
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification,
        object: session,
        queue: .main
      ) { [weak self] notification in
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        MainActor.assumeIsolated {
          guard
            let self,
            let rawReason,
            let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason),
            reason == .oldDeviceUnavailable
          else { return }
          self.handleManagedAppleAudioSessionDisruption(.routeLost)
        }
      },
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereLostNotification,
        object: session,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleManagedAppleAudioSessionDisruption(.mediaServicesLost)
        }
      },
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification,
        object: session,
        queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.handleManagedAppleAudioSessionDisruption(.mediaServicesReset)
        }
      }
    ]
  }

  func stopManagedAppleAudioSessionObservationIfNeeded() {
    for observer in managedAppleAudioSessionObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    managedAppleAudioSessionObservers.removeAll()
    managedAppleAudioSessionControllers.removeAllObjects()
    preferredManagedAppleAudioSessionController = nil
  }

  #else
  func acquireManagedAppleAudioSessionLeaseIfNeeded() -> Bool {
    true
  }

  func releaseManagedAppleAudioSessionLeaseIfNeeded() -> Bool {
    false
  }

  func relinquishManagedAppleAudioSessionLeaseForHandleReplacement() -> Bool {
    false
  }

  func transferManagedAppleAudioSessionLease(to _: OpaquePointer) -> Bool? {
    nil
  }

  func invalidateManagedAppleAudioSessionActivationLatches() {}
  func startManagedAppleAudioSessionObservationIfNeeded() {}
  func stopManagedAppleAudioSessionObservationIfNeeded() {}
  #endif

  #if os(iOS) || os(macOS)
  /// Registers a controller as a possible effect owner without adding a
  /// second process-notification subscription. If more than one controller is
  /// alive for a player, only one handles each disruption.
  func registerManagedAppleAudioSessionController(_ controller: PiPController) {
    guard appleAudioSessionPolicy.managesAudioSession else { return }
    managedAppleAudioSessionControllers.add(controller)
    preferredManagedAppleAudioSessionController = controller
  }

  func unregisterManagedAppleAudioSessionController(_ controller: PiPController) {
    managedAppleAudioSessionControllers.remove(controller)
    if preferredManagedAppleAudioSessionController === controller {
      preferredManagedAppleAudioSessionController =
        managedAppleAudioSessionControllers.allObjects.last
    }
  }
  #endif

  /// Routes a system disruption to a single PiP policy owner, or applies the
  /// player-level safety policy when playback has no PiP controller.
  func handleManagedAppleAudioSessionDisruption(
    _ disruption: ManagedAppleAudioSessionDisruption
  ) {
    guard !isShutdown else { return }

    switch disruption {
    case .interruptionBegan, .mediaServicesLost, .mediaServicesReset:
      // These signals invalidate the activation represented by the current
      // lease. Consume it before any controller attempts recovery; a reset can
      // make the native release stale, but the local token must still clear.
      _ = releaseManagedAppleAudioSessionLeaseIfNeeded()
    case .interruptionEnded, .routeLost:
      break
    }

    #if os(iOS) || os(macOS)
    do {
      let controllers = managedAppleAudioSessionControllers.allObjects.filter(
        \.managesAudioSession
      )
      let preferred = preferredManagedAppleAudioSessionController.flatMap { candidate in
        controllers.first { $0 === candidate }
      }
      let controller = controllers.first(where: \.isActive)
        ?? preferred
        ?? controllers.last
      switch disruption {
      case .interruptionBegan, .interruptionEnded,
           .mediaServicesLost, .mediaServicesReset:
        // Activation belongs to each controller, unlike suspension/quarantine
        // state which is player-scoped. Invalidate every live latch so an
        // older reconstructed controller can never regain ownership while
        // trusting a pre-disruption session. Only the selected controller
        // below performs effects or attempts reactivation.
        for candidate in controllers {
          candidate.hasActivatedAudioSession = false
        }
      case .routeLost:
        break
      }
      if let controller {
        switch disruption {
        case .interruptionBegan:
          controller.react(to: .interruptionBegan)
        case .interruptionEnded(let shouldResume):
          controller.react(to: .interruptionEnded(shouldResume: shouldResume))
        case .routeLost:
          controller.react(to: .routeLost)
        case .mediaServicesLost:
          controller.react(to: .mediaServicesLost)
        case .mediaServicesReset:
          controller.react(to: .mediaServicesReset)
        }
        return
      }
    }
    #endif

    applyManagedAppleAudioSessionFallback(disruption)
  }

  /// Transport-only fallback for audio-only and ordinary video playback.
  /// Native libVLC owns graph/category recovery; Swift owns the public intent
  /// boundary so a reset cannot silently restart old playback permission.
  private func applyManagedAppleAudioSessionFallback(
    _ disruption: ManagedAppleAudioSessionDisruption
  ) {
    switch disruption {
    case .interruptionBegan, .interruptionEnded:
      // The native Apple audio output stops/restarts its render graph for an
      // interruption. No PiP activation latch exists on this path.
      break

    case .routeLost:
      // Do not let an unplugged private route continue on the speaker.
      _ = issuePause()

    case .mediaServicesLost:
      let wasAlreadySuspended = isManagedAudioLifecycleSuspended
        || isManagedAudioMediaServicesSuspended
      guard isPlaybackRequestedActive, !wasAlreadySuspended else { return }
      if issueManagedAudioPause() {
        isManagedAudioMediaServicesSuspended = true
      }

    case .mediaServicesReset:
      // Install the quarantine before issuing the native pause. Reset can
      // synchronously enqueue an active-state callback while rebuilding.
      beginMediaServicesResetPlaybackQuarantine()
      _ = issuePause()
    }
  }
}
