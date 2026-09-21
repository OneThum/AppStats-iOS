# Changelog

All notable changes to the AppStats SDK will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.19] - 2026-09-21

### Changed
- The privacy manifest now declares `NSPrivacyCollectedDataTypeCoarseLocation` (analytics; not linked to identity, not used for tracking). The SDK requests no location permission and sends no location field, but the receiving service resolves each request's IP address to a country, city and city-level coordinates and keeps them with the event for 90 days, which is past servicing the request. Apple separates coarse from precise by the resolution of the information rather than by stored decimal places, and an IP lookup yields a city-area centroid, so it is declared coarse. Previously the manifest declared only product interaction and crash data.

## [1.0.18] - 2026-09-21

### Changed
- Minimum iOS deployment target lowered from iOS 16.0 to iOS 15.0, so apps that still support iOS 15 can link the SDK. Nothing in the SDK needed iOS 16: every API it calls (`URLSession.data(for:)`, `Date.ISO8601FormatStyle`, Swift concurrency) is available on iOS 15. Other platform minimums are unchanged.

### Fixed
- Event timestamps were sent with whole-second precision. `JSONEncoder`'s built-in `.iso8601` strategy drops fractional seconds, so every event created within the same second shared a timestamp and the dashboard could not order them — `app_background` could appear after `session_end`, and two screen views in the same second came back in arbitrary order. Timestamps now carry milliseconds (`2026-09-18T01:55:22.250Z`), matching the Android SDK.

- The privacy manifest (`PrivacyInfo.xcprivacy`) is restored. It was added to the public repository directly (PR #4), but that repository is regenerated from this one on every sync, which deletes anything not present here — so it was removed by the next sync, before any release included it. No released version has shipped a privacy manifest; this is the first.

### Notes
- Events already queued on disk by earlier versions are whole-second, and the built-in `.iso8601` *decoding* strategy rejects fractional seconds, so the on-disk queue now decodes both forms. Without this, updating only the encoder would have made every event queued by this version unreadable after the next launch.

## [1.0.17] - 2026-09-15

### Fixed
- `CrashReporter`'s `NSException` handler captured `exception.reason` and `callStackSymbols` verbatim with no bound. Both are app-authored strings — code routinely builds exception messages by interpolating live state (a KVC key path, a malformed input value, a URL with query params) — so an unbounded capture could carry incidental PII off the device despite this README's "No PII" claim. Both fields are now capped (1,000 / 4,000 characters) at the capture site, and the README's privacy claims were reworded to describe what the SDK actually guarantees.
- `EventCollector.flush()` could partially evict a batch it was actively retrying. `flush()` removes events from `eventQueue` before `await`-ing the network send; that suspension let concurrent `collect()` calls grow the queue, and on failure the catch block trimmed back down to `maxQueueSize` from the head — meaning a batch that had already failed once and was about to be retried could lose events to arrivals that hadn't even been attempted yet. The trim now happens from the tail, so a batch under retry always survives ahead of newer, unattempted events.

## [1.0.16] - 2026-09-06

### Fixed
- The crash marker write is now genuinely async-signal-safe. `writeCrashMarker()` ran inside the signal handler under a comment claiming it was safe, when it called `Date()`, built the marker with Swift string interpolation, and wrote it through `String.write(to:atomically:encoding:)` — all of which allocate or take locks. A crash that happened while the allocator lock was held would deadlock in the handler: the same class of hang 1.0.15 closed for signal *dispositions*, still open for the marker *write*. The handler now uses a separate path built only from `open`/`write`/`close` and `time(nil)`, with the file path resolved and the scratch buffers allocated up front on a normal thread.
- The signal handler no longer calls `Date()` or `signalNameForCode` (which returns a Swift `String`). The raw signal number is written instead and resolved back to a name on the next launch, when the marker is parsed on a normal thread.

### Changed
- Markers written from a signal now use `CRASH_SIGNAL:`/`CRASH_EPOCH:`. `NSException` crashes are unaffected: that handler runs as an ordinary call on the throwing thread, so it keeps the existing richer marker with reason and stack trace. Both formats are read back.

### Notes
- The crashing session's id is still recorded on the signal path (pre-formatted at setup, since `UUID.uuidString` allocates), so a replayed crash stays attributed to the session that crashed rather than to the session live when the marker is read.

## [1.0.15] - 2026-09-05

### Fixed
- The crash handler live-locked instead of crashing. It re-raised the signal while still installed as that signal's handler, so the re-raise was delivered straight back into itself and the process spun in its own crash handler rather than dying. In the field this cost the crash report outright: the app appeared frozen at ~185% CPU, produced no report, and was eventually killed by the watchdog with a cause pointing nowhere near the real fault. Under XCTest there is no watchdog, so a single test case hung 34 minutes. The handler now restores the previous disposition *before* re-raising, so `raise` runs the previous handler — or the default action — exactly as the system would.
- Removed the hand-rolled chained call into the previous handler, which is now redundant (and previously ran the previous handler twice). It also crashed outright when the previous disposition was `SIG_IGN`: `SIG_IGN` is the address `0x1`, which the old code treated as a real function pointer and called. `SIG_IGN` on `SIGPIPE` is common on Apple platforms.
- The handler no longer reads the `previousSignalHandlers` dictionary. A Swift `Dictionary` lookup can allocate, and allocating inside a signal handler deadlocks whenever the crash happened while the allocator lock was held — precisely the heap-corruption `SIGABRT` case crash reporting most needs to survive. Handler-reachable state now lives in fixed-size arrays populated at install time; the dictionary is unchanged and still used elsewhere.
- `installSignalHandlers()` is now idempotent. `AppStats.configure()` is public and has no re-entry guard, so a host app could call it twice; the second install captured AppStats' own handler as the "previous" disposition, which would reintroduce the live-lock on restore.

### Known issue
- `writeCrashMarker()` is still called from the signal handler and is still not async-signal-safe (Foundation plus filesystem). This is pre-existing and unchanged. It is a real hazard, but it is not what caused the live-lock; making the marker write genuinely signal-safe (pre-serialise at setup, `write(2)` only) is its own change.

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
