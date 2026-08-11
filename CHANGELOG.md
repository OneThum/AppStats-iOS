# Changelog

All notable changes to the AppStats SDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.14] - 2026-08-11

### Fixed
- `setUserProperty` was a no-op: the private `setProperty` it delegated to had an empty body, so a property set before `track()` never appeared on any event. User properties are now stored on the `AppStats` instance, merged into every event (custom, lifecycle, and app-launch), and persisted to disk so they survive a cold relaunch.
- Crash markers were written on crash but never read back: `checkForPreviousCrash()` was `internal` (unreachable by host apps) and nothing in the SDK called it either, so the crash-reporting feature was non-functional end-to-end. `initialize()` now automatically replays any crash from the previous launch as a `crash` event before continuing normal startup.

## [1.0.13] - 2026-08-10

### Fixed
- Swift 6 / Xcode 16.4: `DeviceInfo.osVersion` now uses `ProcessInfo` instead of MainActor-isolated `UIDevice`.
- Swift 6 / Xcode 16.4: `DeviceInfo.screenResolution` hops to the main actor before reading `UIScreen`, so package clients build under Strict Concurrency.

## [1.0.12] - 2026-05-09

### Added
- Send `X-AS-SDK-Platform: swift` header on every ingest request so the backend (and upcoming dashboard breakdowns) can distinguish Swift-emitted events from Kotlin-emitted events. This aligns the Swift SDK with the new cross-SDK protocol shared with the Kotlin SDK at `OneThum/AppStats-Android`.
- Audited all event field names against `schemas/event.v1.json` (the canonical wire schema in AppStats-PVT). No drift was found; this release is wire-compatible with v1.0.11.

## [1.0.11] - 2026-03-16

### Fixed
- Switched SDK local storage on `tvOS` from `Application Support` to `Caches` to avoid on-device sandbox permission failures during initialization.
- Centralized AppStats storage path selection so event persistence and crash markers use the same platform-aware directory rules.
- Made storage initialization degrade gracefully to in-memory queueing if disk persistence is unavailable, so analytics can stay active without local files.
- Recreate the AppStats storage directory lazily when needed so cache eviction on `tvOS` does not break later event writes.

## [1.0.7] - 2026-02-21

### Fixed
- Fixed a backward compatibility decoding bug where older persisted events missing newly added fields (`screen_resolution`, `locale`, `timezone`) would fail to decode, causing `StorageManager.loadEvents()` to throw `keyNotFound`.
- Replaced `.decode` with `.decodeIfPresent` and fallback values for new properties, making them migration-safe for older SDK data.

## [1.0.6] - 2026-02-21

### Added
- Added automatic tracking for `screen_resolution`, `locale`, and `timezone` to `Event` and `DeviceInfo`.

## [1.0.1] - 2026-02-16

### Fixed
- Compression bug fix for payloads.

## [1.0.0] - 2026-02-15

### Added
- Initial public release of AppStats SDK
- Automatic tracking of app launches, screen views, and lifecycle events
- Swift 6.0 concurrency support
- iOS 16+, macOS 13+, visionOS 1.0+ support
- Crash reporting with symbolicated stack traces
- Offline event queueing with retry logic
- Privacy-first design (no IDFA, no persistent IDs)
- Zero-config setup
- Manual event tracking API
- User properties support

### Features
- < 200KB binary size
- < 5ms launch impact
- Full offline support
- Automatic screen tracking for SwiftUI and UIKit
- Resilient network handling with circuit breaker
- Gzip compression for network efficiency
