// AppStats SDK - Main Entry Point
// Copyright © 2026 One Thum Software

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The main AppStats SDK interface.
///
/// AppStats provides lightweight, privacy-first analytics for iOS, macOS, and visionOS apps.
/// Configure once in your app's launch sequence and the SDK automatically tracks app lifecycle,
/// screen views, and crashes.
///
/// Example usage:
/// ```swift
/// import AppStats
///
/// @main
/// struct MyApp: App {
///     var body: some Scene {
///         WindowGroup {
///             ContentView()
///                 .task {
///                     AppStats.configure(apiKey: "as_live_xxxxxxxxxxxx")
///                 }
///         }
///     }
/// }
/// ```
@MainActor
public final class AppStats {
    
    // MARK: - Public API
    
    /// Configure the AppStats SDK with your API key.
    ///
    /// Call once during app launch. In SwiftUI apps, the recommended call site is a
    /// `.task` modifier on your root view so the first frame renders without delay.
    /// Calling from `App.init()` or `application(_:didFinishLaunchingWithOptions:)`
    /// also works — the heavy initialization is already async.
    ///
    /// - Parameters:
    ///   - apiKey: Your AppStats API key (e.g., "as_live_xxxxxxxxxxxx")
    ///   - autoTrackScreens: Whether to automatically track screen views (default: true)
    ///   - flushInterval: How often to send events to the server in seconds (default: 30)
    public static func configure(
        apiKey: String,
        autoTrackScreens: Bool = true,
        flushInterval: TimeInterval = 30
    ) {
        let config = Configuration(
            apiKey: apiKey,
            autoTrackScreens: autoTrackScreens,
            flushInterval: flushInterval
        )
        
        let instance = AppStats(configuration: config)
        instance.isInitializing = true
        
        // Set shared instance AFTER marking as initializing to prevent race conditions
        shared = instance
        
        // All heavy initialization happens on background queue
        Task.detached(priority: .utility) {
            await instance.initialize()
        }
    }
    
    /// Track a custom event with optional properties.
    ///
    /// - Parameters:
    ///   - eventName: The name of the event (e.g., "purchase_completed")
    ///   - properties: Optional key-value properties (strings, numbers, booleans only)
    public static func track(_ eventName: String, properties: [String: Any]? = nil) {
        guard let instance = shared else {
            Logger.warning("AppStats not configured - call configure() first")
            return
        }
        
        // Events are automatically queued during initialization, so no warning needed
        Task {
            await instance.queueOrTrackEvent(eventName, properties: properties)
        }
    }
    
    /// Manually flush queued events to the server.
    ///
    /// The SDK automatically flushes events periodically, but you can call this method
    /// to force an immediate flush (e.g., before the app terminates).
    public static func flush() {
        guard let instance = shared else { return }
        Task {
            await instance.flushEvents()
        }
    }
    
    /// Async variant of flush — awaits completion of the network send.
    ///
    /// Prefer this form when calling from an async context (e.g., `.background` scene
    /// phase handler) so the flush finishes before the OS suspends the app.
    public static func flushAsync() async {
        guard let instance = shared else { return }
        await instance.flushEvents()
    }
    
    /// Set a custom user property that will be included with all events.
    ///
    /// - Parameters:
    ///   - key: The property key
    ///   - value: The property value (string, number, or boolean)
    public static func setUserProperty(_ key: String, value: Any) {
        guard let instance = shared else { return }
        
        Task {
            await instance.setProperty(key, value: value)
        }
    }
    
    // MARK: - Internal State
    
    private static var shared: AppStats?
    
    private let configuration: Configuration
    private var eventCollector: EventCollector?
    private var networkManager: NetworkManager?
    private var storageManager: StorageManager?
    private var sessionID: UUID
    private var isInitialized = false
    private var isInitializing = false
    private var isDisabled = false
    private var errorCount = 0
    private var pendingEvents: [(eventName: String, properties: [String: Any]?)] = []
    
    // MARK: - Initialization
    
    private init(configuration: Configuration) {
        self.configuration = configuration
        self.sessionID = UUID()
    }
    
    private func initialize() async {
        // Defensive: catch all errors during initialization
        do {
            // Create managers
            self.storageManager = try StorageManager()
            self.networkManager = NetworkManager(
                apiKey: configuration.apiKey,
                baseURL: configuration.baseURL
            )
            self.eventCollector = EventCollector(
                sessionID: sessionID,
                storage: storageManager!,
                network: networkManager!
            )
            
            // Setup automatic tracking
            if configuration.autoTrackScreens {
                #if canImport(UIKit) && !os(watchOS)
                setupUIKitScreenTracking()
                #endif
            }
            
            // Setup lifecycle observers
            setupLifecycleObservers()
            
            // Setup crash reporting
            setupCrashReporting()
            
            // Start periodic flush timer
            startFlushTimer()
            
            // Track app launch
            await trackAppLaunch()
            
            // Mark initialization as complete
            self.isInitialized = true
            self.isInitializing = false
            Logger.info("AppStats SDK initialized successfully")
            
            // Process any events that were queued during initialization
            await processPendingEvents()
            
        } catch {
            Logger.error("AppStats initialization failed: \(error)")
            self.isDisabled = true
            self.isInitializing = false
            self.pendingEvents.removeAll()
        }
    }
    
    // MARK: - Event Tracking
    
    private func queueOrTrackEvent(_ eventName: String, properties: [String: Any]?) async {
        // If still initializing, queue the event for later
        if isInitializing {
            pendingEvents.append((eventName: eventName, properties: properties))
            return
        }
        
        // Otherwise track immediately
        await trackEvent(eventName, properties: properties)
    }
    
    private func processPendingEvents() async {
        guard !pendingEvents.isEmpty else { return }
        
        Logger.info("Processing \(pendingEvents.count) pending event(s)")
        
        let events = pendingEvents
        pendingEvents.removeAll()
        
        for event in events {
            await trackEvent(event.eventName, properties: event.properties)
        }
    }
    
    private func trackEvent(_ eventName: String, properties: [String: Any]?) async {
        guard !isDisabled, isInitialized, let eventCollector = eventCollector else {
            return
        }
        
        do {
            let event = Event(
                type: .custom,
                name: eventName,
                sessionID: sessionID,
                properties: properties
            )
            
            try await eventCollector.collect(event)
            
        } catch {
            handleError(error)
        }
    }
    
    private func trackAppLaunch() async {
        guard let eventCollector = eventCollector else { return }
        
        do {
            // Emit session_start first — this is what the live dashboard
            // listens for to count active sessions and place map pins.
            let sessionStart = Event(
                type: .sessionStart,
                sessionID: sessionID,
                properties: [
                    "app_version": AppInfo.version,
                    "os_version": DeviceInfo.osVersion,
                    "device_model": DeviceInfo.deviceModel
                ]
            )
            try await eventCollector.collect(sessionStart)

            let launch = Event(
                type: .appLaunch,
                sessionID: sessionID,
                properties: [
                    "app_version": AppInfo.version,
                    "build_number": AppInfo.buildNumber,
                    "os_version": DeviceInfo.osVersion,
                    "device_model": DeviceInfo.deviceModel
                ]
            )
            try await eventCollector.collect(launch)
            
        } catch {
            handleError(error)
        }
    }
    
    private func flushEvents() async {
        guard let eventCollector = eventCollector else { return }
        
        do {
            try await eventCollector.flush()
        } catch {
            handleError(error)
        }
    }
    
    private func setProperty(_ key: String, value: Any) async {
        // Store user properties for inclusion in all events
        // Implementation in EventCollector
    }
    
    // MARK: - Lifecycle
    
    private func setupLifecycleObservers() {
        #if canImport(UIKit) && !os(watchOS)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleAppBackground() }
        }
        
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleAppForeground() }
        }
        #elseif canImport(AppKit)
        // macOS lifecycle observers
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.handleAppForeground() }
        }
        #endif
    }
    
    private func handleAppBackground() async {
        // Request time from the OS to finish the network send before suspend.
        // Without this, the unstructured Task from the notification observer can
        // be killed mid-flight and events are silently lost.
        #if canImport(UIKit) && !os(watchOS)
        let app = await UIApplication.shared
        var bgTaskID = UIBackgroundTaskIdentifier.invalid
        bgTaskID = await app.beginBackgroundTask(withName: "AppStats.flush") {
            // Expiration handler — clean up if we ran out of time
            Task { @MainActor in
                if bgTaskID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgTaskID)
                    bgTaskID = .invalid
                }
            }
        }
        #endif

        // Track session end + background event, then flush everything
        if let eventCollector = eventCollector, !isDisabled, isInitialized {
            let sessionEnd = Event(type: .sessionEnd, sessionID: sessionID)
            try? await eventCollector.collect(sessionEnd)
            let background = Event(type: .appBackground, sessionID: sessionID)
            try? await eventCollector.collect(background)
        }
        await flushEvents()

        #if canImport(UIKit) && !os(watchOS)
        let taskToEnd = bgTaskID
        Task { @MainActor in
            if taskToEnd != .invalid {
                UIApplication.shared.endBackgroundTask(taskToEnd)
            }
        }
        #endif
    }
    
    private func handleAppForeground() async {
        // Each foreground transition is a new session
        sessionID = UUID()
        
        guard let eventCollector = eventCollector else { return }
        
        do {
            // session_start so the live dashboard picks up the new session
            let sessionStart = Event(
                type: .sessionStart,
                sessionID: sessionID,
                properties: [
                    "app_version": AppInfo.version,
                    "os_version": DeviceInfo.osVersion,
                    "device_model": DeviceInfo.deviceModel
                ]
            )
            try await eventCollector.collect(sessionStart)

            let foreground = Event(
                type: .appForeground,
                sessionID: sessionID
            )
            try await eventCollector.collect(foreground)
        } catch {
            handleError(error)
        }
    }
    
    // MARK: - Screen Tracking
    
    #if canImport(UIKit) && !os(watchOS)
    private func setupUIKitScreenTracking() {
        // Method swizzling for automatic screen tracking
        // Implementation in ScreenTracker.swift
        ScreenTracker.setupAutomaticTracking()
    }
    #endif
    
    // MARK: - Crash Reporting
    
    private func setupCrashReporting() {
        // Setup signal handlers and NSException handler
        // Implementation in CrashReporter.swift
        CrashReporter.setup(sessionID: sessionID)
    }
    
    // MARK: - Timer
    
    private func startFlushTimer() {
        // Must use .common run loop mode so the timer fires even during active touch
        // interactions (UITrackingRunLoopMode). Without this, the timer is silently
        // suppressed during gameplay in touch-heavy apps.
        let timer = Timer(timeInterval: configuration.flushInterval, repeats: true) { [weak self] _ in
            Task {
                await self?.flushEvents()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    
    // MARK: - Error Handling
    
    private func handleError(_ error: Error) {
        if let networkError = error as? NetworkError {
            switch networkError {
            case .inBackoff:
                Logger.warning("In backoff mode due to repeated failures - will retry automatically")
                return // Don't count backoff as a hard error
            case .clientError(let code) where code == 401 || code == 403:
                // Auth errors are configuration problems - count them
                errorCount += 1
                Logger.error("Auth error \(code) - check API key: \(configuration.apiKey.prefix(12))...")
            case .clientError(let code):
                // Other 4xx - log but don't count as fatal
                Logger.warning("Client error \(code) - events may be malformed")
                return
            case .serverError(let code):
                // Server errors are transient - don't count against kill switch
                Logger.warning("Server error \(code) - service may be temporarily unavailable")
                return
            case .compressionFailed:
                errorCount += 1
                Logger.error("Failed to compress event data")
            default:
                Logger.error("AppStats error: \(error)")
                return
            }
        } else if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                Logger.warning("Request timed out - check network connection")
            case .notConnectedToInternet:
                Logger.warning("No internet connection - events will be retried")
            case .cannotConnectToHost:
                Logger.warning("Cannot connect to server - will retry later")
            case .networkConnectionLost:
                Logger.warning("Network connection lost - will retry")
            case .dnsLookupFailed:
                Logger.warning("DNS lookup failed - check network settings")
            default:
                Logger.warning("Network error: \(urlError.localizedDescription)")
            }
            // Network errors are transient - don't count against kill switch
            return
        } else {
            Logger.error("AppStats error: \(error)")
        }
        
        // Only disable after repeated auth/compression failures (not transient network issues)
        if errorCount >= 10 {
            Logger.error("AppStats disabled after \(errorCount) consecutive auth/config errors - check API key")
            isDisabled = true
        }
    }
}

// MARK: - Configuration

extension AppStats {
    struct Configuration {
        let apiKey: String
        let autoTrackScreens: Bool
        let flushInterval: TimeInterval
        let baseURL: URL
        
        init(
            apiKey: String,
            autoTrackScreens: Bool,
            flushInterval: TimeInterval,
            baseURL: URL = URL(string: "https://ingest.appstats.app")!
        ) {
            self.apiKey = apiKey
            self.autoTrackScreens = autoTrackScreens
            self.flushInterval = flushInterval
            self.baseURL = baseURL
        }
    }
}

// MARK: - Logging

private enum Logger {
    static func info(_ message: String) {
        #if DEBUG
        print("[AppStats] ℹ️ \(message)")
        #endif
    }
    
    static func warning(_ message: String) {
        #if DEBUG
        print("[AppStats] ⚠️ \(message)")
        #endif
    }
    
    // Errors are always logged (even in release) so misconfiguration is visible
    static func error(_ message: String) {
        print("[AppStats] ❌ \(message)")
    }
}
