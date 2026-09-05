// CrashReporter.swift - Crash detection and reporting
// Copyright © 2026 One Thum Software

import Foundation

#if canImport(Darwin)
import Darwin
#endif

/// Crash detection and reporting
enum CrashReporter {

    /// Structured crash details recovered from the marker written on the previous launch.
    struct PreviousCrash {
        let timestamp: Date
        let signal: String
        let reason: String
        let sessionID: String
        let stackTrace: String
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var sessionID: UUID?
    private nonisolated(unsafe) static var previousSignalHandlers: [Int32: sigaction] = [:]

    /// Signal-handler-safe mirror of `previousSignalHandlers`.
    ///
    /// The dictionary is kept for the rest of the type, but a signal handler must not touch
    /// it: a `Dictionary` lookup can allocate, and allocating inside a handler deadlocks when
    /// the crash itself happened under the allocator lock. These fixed-size arrays are filled
    /// once during `installSignalHandlers()` and only read afterwards.
    private nonisolated(unsafe) static var handledSignals = [Int32](repeating: 0, count: 8)
    // `Array(repeating:)` rather than `[sigaction](repeating:)`: `sigaction` names both a
    // struct and a function on Darwin, and the explicit-element form resolves to an array of
    // the *function* type and fails to compile. Inferring the element from `sigaction()`
    // picks the struct initialiser.
    private nonisolated(unsafe) static var savedDispositions = Array(repeating: sigaction(), count: 8)
    private nonisolated(unsafe) static var handledSignalCount = 0

    /// Guards against installing our handler twice.
    ///
    /// `AppStats.configure()` is public and has no re-entry guard, so a host app can call it
    /// more than once. A second install would capture *our own* handler as the "previous"
    /// disposition, and restoring that on crash would re-enter this handler — reintroducing
    /// exactly the live-lock this handler exists to avoid.
    private nonisolated(unsafe) static var signalHandlersInstalled = false
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
        guard !signalHandlersInstalled else { return }
        signalHandlersInstalled = true

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

            // …and again where the signal handler itself can reach it without allocating.
            if handledSignalCount < handledSignals.count {
                handledSignals[handledSignalCount] = signal
                savedDispositions[handledSignalCount] = oldAction
                handledSignalCount += 1
            }
        }
    }
    
    private static let signalHandler: @convention(c) (Int32, UnsafeMutablePointer<__siginfo>?, UnsafeMutableRawPointer?) -> Void = { signal, info, context in

        // Restore the previous disposition for this signal BEFORE doing anything else.
        //
        // This must happen first. The handler ends by re-raising, and while this handler is
        // still installed that re-raise is delivered straight back here — the process spins
        // in its own crash handler instead of dying. Observed in the field as a hang, not a
        // crash: the app burns ~185% CPU indefinitely, produces no crash report, and is
        // eventually killed by the watchdog with a cause that points nowhere near the real
        // fault. Under XCTest there is no watchdog at all, so the test host hangs until the
        // CI job times out.
        //
        // Restoring first also removes the need to invoke the previous handler by hand: once
        // the disposition is back to what it was, `raise` runs it (or the default action)
        // exactly as the system would have.
        restorePreviousDisposition(signal)

        // Create minimal crash report
        let timestamp = Date()
        let signalName = signalNameForCode(signal)

        // Write crash marker to file (for next launch detection)
        writeCrashMarker(signal: signalName, timestamp: timestamp)

        // Re-raise. The previous handler — or SIG_DFL — now owns the signal, so this
        // terminates rather than re-entering.
        signal_raise(signal)
    }

    /// Reinstalls whatever was handling `signal` before AppStats did, falling back to the
    /// default action when we never recorded one.
    ///
    /// Reads from a fixed-size array rather than the `previousSignalHandlers` dictionary:
    /// a Swift `Dictionary` lookup can allocate, and allocating inside a signal handler
    /// deadlocks whenever the crash happened while the allocator lock was held — which is
    /// exactly the case for a heap-corruption `SIGABRT`.
    private static func restorePreviousDisposition(_ signal: Int32) {
        for index in 0..<handledSignalCount where handledSignals[index] == signal {
            var previous = savedDispositions[index]
            sigaction(signal, &previous, nil)
            return
        }

        var fallback = sigaction()
        fallback.__sigaction_u.__sa_handler = SIG_DFL
        sigaction(signal, &fallback, nil)
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

    /// Returns crash details from the previous launch, or nil if there was none.
    /// Deletes the marker on read so it isn't reported twice.
    static func consumePreviousCrash() -> PreviousCrash? {
        guard let crashFileURL = getCrashFileURL(),
              FileManager.default.fileExists(atPath: crashFileURL.path),
              let raw = try? String(contentsOf: crashFileURL, encoding: .utf8) else {
            return nil
        }

        try? FileManager.default.removeItem(at: crashFileURL)

        return parseMarker(raw)
    }

    private static func parseMarker(_ raw: String) -> PreviousCrash {
        var timestamp = Date()
        var signal = "UNKNOWN"
        var reason = ""
        var sessionID = ""
        var stackTraceLines: [String] = []
        var inStackTrace = false

        for substring in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(substring)
            if inStackTrace {
                stackTraceLines.append(line)
            } else if line.hasPrefix("CRASH_TIMESTAMP:") {
                let value = line.dropFirst("CRASH_TIMESTAMP:".count).trimmingCharacters(in: .whitespaces)
                if let seconds = Double(value) {
                    timestamp = Date(timeIntervalSince1970: seconds)
                }
            } else if line.hasPrefix("SIGNAL:") {
                signal = line.dropFirst("SIGNAL:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("REASON:") {
                reason = line.dropFirst("REASON:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("SESSION_ID:") {
                sessionID = line.dropFirst("SESSION_ID:".count).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("STACK_TRACE:") {
                inStackTrace = true
            }
        }

        return PreviousCrash(
            timestamp: timestamp,
            signal: signal,
            reason: reason,
            sessionID: sessionID,
            stackTrace: stackTraceLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

#if canImport(Darwin)
private func signal_raise(_ signal: Int32) {
    raise(signal)
}
#endif
