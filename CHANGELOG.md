# Changelog

All notable changes to **Maccar** are documented in this file.

## [v1.3.0] - 2026-11-12 14:05 +0700
### Added
- First public open-source release under **GPL-3.0**, with a bilingual (English primary, Indonesian secondary) README and an SEO-tuned landing page in `docs/` targeted at "Headless Sidecar" / "Sidecar tanpa monitor".
- `ReleaseUpdater` (`Sources/MaccarKit/ReleaseUpdater.swift`) and `UpdateController` (`Sources/MaccarApp/UpdateController.swift`): a pure-Swift updater that resolves `manifest.json`, verifies SHA-256 plus size, and stages the `Maccar.app` bundle, leaving the Ed25519 signature path intact for when a release key is pinned.
- `MenuBarMenuBuilder` (`Sources/MaccarApp/MenuBarMenuBuilder.swift`) extracting menu construction from `MenuBarController`, plus `Check for Updates...` and `Auto-Check Updates` menu items.
- Zero-TCC release-screenshot pipeline (`ScreenshotCanvas`, `ScreenshotExporter`, `--export-screenshots`) that renders 2x window chrome and the live menu popover offscreen, so no Screen Recording or Accessibility prompt appears and no PID collides with a running `/Applications/Maccar.app`.
- `scripts/generate_manifest.sh` for reproducible manifest generation and Ed25519 signing, plus GitHub Actions workflows for CI, tagged releases, and GitHub Pages.
- `install.sh`, a manifest-driven installer that verifies the bundle identifier and supports version pinning and a dry-run mode.

### Changed
- Version metadata bumped to `v1.3.0` (build `5`) in `scripts/Info.plist`, `main.swift`, and the About window; `MaccarUpdatePublicKey` / `MaccarUpdateKeyId` ship present but **empty**, so this release is unpinned while the verification code stays live.
- About window credits now acknowledge the open-source heritage it builds on, and the footer reads `Licensed under GPL-3.0`.

### Fixed
- Fixed the About window screenshot (and any PDF capture) truncating everything drawn after the app icon: `MaccarIconRenderer.renderAppIcon` called `restoreGState()` without a matching `saveGState()`, popping the enclosing recorder's state.

## [v1.2.1] - 2026-11-11 12:49 +0700
### Added
- IOKit `USBDeviceAttachMonitor` (`USBAttachMonitoring`, matching `IOUSBHostDevice` Apple `0x05AC` devices with an `"iPad"` product/name filter) and a `750ms` debounced attach hook in `DeviceWatcherObserver` to wake `.autoRetryPaused` on physical USB reconnect while keeping `isManualDisconnectHold` sovereign.
- `DeviceWatcherBackoff.Tracker` (`DeviceWatcherBackoff.swift`) with `-200` (`SidecarErrorDomain` / `com.maccar.sidecar`) escalation (`20s -> 60s -> 180s -> pause`) and `DeviceWatcherStatus.autoRetryPaused(targetName:)`.
- `MaccarLogger.resolveDefaultLogDirectory(...)` test-runner log isolation (`MACCAR_LOG_DIR` override and automatic `XCTest` / `swiftpm-testing-helper` isolation to `$TMPDIR/maccar-test-logs-<pid>/maccar.log`).
- Expanded `MaccarKitTests` suite to `52` tests across `6` suites (`LoggerTests`, `ResolutionTests`, `SidecarServiceTests`, `DeviceWatcherBackoffTests`, `DeviceWatcherTests`, `DeviceWatcherResilienceTests`).

### Changed
- Bounded, interruptible `0.4s` post-disconnect settle window in `SidecarService.waitPostDisconnectSettle` (`-302` cancellation preserved) and `DeviceWatcher.settleAfterDisconnect` (`DeviceWatcher+Reconnect.swift`).
- Synchronized Menu Bar target and Auto-Connect toggle state (`MenuBarController.clearDeviceNameTapped()` -> `DeviceWatcher.shared.clearTargetState()`, `toggleAutoConnect()` -> `setAutoConnectEnabled(_:)`) with immediate `updateTitle(for:)` refresh.
- Hardened `scripts/cleanup_legacy.sh` with `PlistBuddy :Label` + `launchctl bootout`, saved/restored `nullglob` & `nocaseglob`, `*headless-sidecar*` / `*sidecarone*` globs, bracketed `pkill -f`, and zero hardcoded personal paths.

### Fixed
- Fixed `-200` (`DeviceNotFound`) alert storm when a sleeping/unreachable iPad remains BLE-reachable (`reachableDevices()`), pausing unattended `-200` retries after 4 attempts (`0s, +20s, +80s, +260s`) while keeping `-201`/`-202`/`-300` on flat `20s` retries and unblocking Control Center Sidecar adoption.
- Fixed `-101` / `RelayError -6700` teardown collisions caused by zero-settle reconnects.
- Fixed `DeviceWatcher.tick()` premature consumption of `manualReconnectRequested` before backoff readiness via atomic `consumeAutoConnectGate(autoConnectEnabled:at:)`.
- Fixed synthetic test logs polluting production `~/Library/Logs/Maccar/maccar.log`.

## [v1.2.0] - 2026-11-11 09:05 +0700
### Added
- Event-driven `SidecarDevicesChangedNotification` and `SidecarDisplayManagerConnectedDevicesChangedNotification` observers in `CMaccarBridge` (`SidecarCoreStartObservingNotifications` / `SidecarCoreStopObservingNotifications`) paired with `CGDisplayRegisterReconfigurationCallback` in `DeviceWatcher` for `< 500ms` debounced state synchronization.
- Protocol-backed dependency injection seams (`ServiceProtocols.swift`: `SidecarControlling`, `VirtualDisplayControlling`, `DisplayMirroring`, `SettingsProviding`) enabling deterministic mock-backed Swift Testing suites (`SidecarServiceTests` and expanded `DeviceWatcherTests`) covering `RC-1` through `RC-5`.
- Active Sidecar session and virtual display mirror status reporting (`Connected iPads` and `Mirror Status`) in `maccar status`.

### Changed
- Force-Reset `Reconnect` (`reconnectNow()` / `⌃⌥⌘R`): tears down active or wedged Sidecar sessions (`disableMirroring` + `disconnect`) before establishing a clean wired session and re-syncing mirroring.
- Strict `isManualDisconnectHold` priority over passive `isDeviceConnected` checks across ghost bounces, clearing only on explicit user reconnect or debounced physical USB detachment.
- Non-blocking `@MainActor` `MenuBarController` actions (`reconnectTapped`, `disconnectTapped`, `resolutionTapped`, `deviceSelectedTapped`) dispatched asynchronously off the main thread, backed by cached `reachableDevices` menu rendering (`<= 16ms`).
- Serialized Sidecar connect/disconnect operations with interruptible `-100` retry cancellation and unified backoff enforcement.

### Fixed
- Fixed silent no-op when triggering `Reconnect` while status was `.connected` (`RC-1`).
- Fixed `isManualDisconnectHold` override caused by 3s grace expiration and ghost re-attach sessions (`RC-2`).
- Fixed stale `.connected` deadlock when `autoConnect == false` and premature `.disconnectedManually` mutation on failed disconnect; made `SidecarCoreDisconnectDevice` idempotent when the target device is already disconnected (`RC-3`).
- Fixed orphan sessions left behind by late-completing `SidecarCoreConnectDevice` calls after the 10s `-300` timeout via `os_unfair_lock`-guarded async disconnect cleanup (`RC-4`).
- Filtered `CGDisplayIsBuiltin(id) == 0` in `DisplayMirrorManager.findIPadDisplay` to eliminate non-iPad internal display selection risk (`RC-5`).

## [v1.1.0] - 2026-11-10 14:53 +0700
### Added
- Async ring-buffer `MaccarLogger` (`500` entries, `512 KB` log rotation) and `LogWindowController`, conflict-free Carbon global hotkey (`⌃⌥⌘R` with `⌃⌥⇧⌘R` fallback), branded `AboutWindowController` with developer attribution and studio brand buttons, `MaccarKitTests` Swift Testing suite with `./maccar.sh test`, and manual-disconnect hold + `Reconnect` controls.

### Changed
- Full English localization across Menu Bar UI, CLI output, and `README.md`; live `CGDisplayModeIsUsableForDesktopGUI` menu filtering.

### Fixed
- Non-destructive in-place `1280x840` display mode switching (1x desktop-usable fallback without calling `destroy()`) and deduplicated `CGVirtualDisplayBridge` mode descriptors.

## [v1.0.0] - 2026-11-10 07:30 +0700
### Added
- Initial Sidecar One / Maccar release unifying `CGVirtualDisplay` headless virtual display creation, `DisplayMirrorManager` iPad aspect-ratio matching, `SidecarCore.framework` Objective-C bridge (`CMaccarBridge`), `DeviceWatcher` USB auto-connect loop, CLI commands, and native `LSUIElement` Menu Bar application.
