// CrashReporter.swift - Crash detection and reporting
// Copyright © 2026 One Thum Software

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Crash detection and reporting
enum CrashReporter {
    
    private static let lock = NSLock()
    private nonisolated(unsafe) static var sessionID: UUID?
    private nonisolated(unsafe) static var previousSignalHandlers: [Int32: sigaction] = [:]
    private nonisolated(unsafe) static var previousExceptionHandler: NSUncaughtExceptionHandler?
    
    static func setup(sessionID: UUID) {
        self.sessionID = sessionID

        do {
            _ = try StoragePaths.ensureAppStatsDirectoryExists()
        } catch {
            Logger.warning("Crash marker storage unavailable: \(error)")
        }
        
        // Install signal handlers
        installSignalHandlers()
        
        // Install NSException handler
        installExceptionHandler()
    }
    
    // MARK: - Signal Handlers
    
    private static func installSignalHandlers() {
        let signals: [Int32] = [
            SIGABRT,
            SIGILL,
            SIGSEGV,
            SIGFPE,
            SIGBUS,
            SIGPIPE
        ]
        
        for signal in signals {
            var newAction = sigaction()
            newAction.__sigaction_u.__sa_sigaction = signalHandler
            newAction.sa_flags = SA_SIGINFO
            
            var oldAction = sigaction()
            sigaction(signal, &newAction, &oldAction)
            
            // Store previous handler
            previousSignalHandlers[signal] = oldAction
        }
    }
    
    private static let signalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in
        
        // Create minimal crash report (async-signal-safe)
        let timestamp = Date()
        let signalName = signalNameForCode(signal)
        
        // Write crash marker to file (for next launch detection)
        writeCrashMarker(signal: signalName, timestamp: timestamp)
        
        // Call previous handler if exists
        if let previousHandler = previousSignalHandlers[signal] {
            if previousHandler.__sigaction_u.__sa_sigaction != nil {
                previousHandler.__sigaction_u.__sa_sigaction(signal, info, context)
            } else if previousHandler.__sigaction_u.__sa_handler != nil {
                let handler = previousHandler.__sigaction_u.__sa_handler
                handler?(signal)
            }
        }
        
        // Re-raise signal
        signal_raise(signal)
    }
    
    private static func signalNameForCode(_ code: Int32) -> String {
        switch code {
        case SIGABRT: return "SIGABRT"
        case SIGILL: return "SIGILL"
        case SIGSEGV: return "SIGSEGV"
        case SIGFPE: return "SIGFPE"
        case SIGBUS: return "SIGBUS"
        case SIGPIPE: return "SIGPIPE"
        default: return "UNKNOWN"
        }
    }
    
    // MARK: - NSException Handler
    
    private static func installExceptionHandler() {
        previousExceptionHandler = NSGetUncaughtExceptionHandler()
        
        NSSetUncaughtExceptionHandler(exceptionHandler)
    }
    
    private static let exceptionHandler: @convention(c) (NSException) -> Void = { exception in
        // Create crash report from exception
        let timestamp = Date()
        let name = exception.name.rawValue
        let reason = exception.reason ?? "No reason"
        let stackTrace = exception.callStackSymbols.joined(separator: "\n")
        
        writeCrashMarker(
            signal: "NSException: \(name)",
            timestamp: timestamp,
            reason: reason,
            stackTrace: stackTrace
        )
        
        // Call previous handler if exists
        if let previousHandler = previousExceptionHandler {
            previousHandler(exception)
        }
    }
    
    // MARK: - Crash Marker
    
    private static func writeCrashMarker(
        signal: String,
        timestamp: Date,
        reason: String? = nil,
        stackTrace: String? = nil
    ) {
        // Write to a pre-allocated file (async-signal-safe)
        guard let crashFileURL = getCrashFileURL() else { return }
        
        let crashInfo = """
        CRASH_TIMESTAMP: \(timestamp.timeIntervalSince1970)
        SIGNAL: \(signal)
        REASON: \(reason ?? "N/A")
        SESSION_ID: \(sessionID?.uuidString ?? "unknown")
        STACK_TRACE:
        \(stackTrace ?? "N/A")
        """
        
        try? crashInfo.write(to: crashFileURL, atomically: false, encoding: .utf8)
    }
    
    private static func getCrashFileURL() -> URL? {
        try? StoragePaths.crashMarkerURL()
    }
    
    // MARK: - Crash Detection (Next Launch)
    
    static func checkForPreviousCrash() -> String? {
        guard let crashFileURL = getCrashFileURL(),
              FileManager.default.fileExists(atPath: crashFileURL.path),
              let crashData = try? String(contentsOf: crashFileURL, encoding: .utf8) else {
            return nil
        }
        
        // Delete crash file
        try? FileManager.default.removeItem(at: crashFileURL)
        
        return crashData
    }
}

#if canImport(Darwin)
private func signal_raise(_ signal: Int32) {
    raise(signal)
}
#endif
