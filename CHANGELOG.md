# Changelog

All notable changes to the AppStats SDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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
