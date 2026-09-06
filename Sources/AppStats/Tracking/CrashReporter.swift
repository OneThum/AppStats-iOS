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

    // MARK: - Async-signal-safe marker write

    /// The crash marker's file path, as raw NUL-terminated UTF-8 bytes, resolved once on a
    /// normal thread before any signal handler can fire.
    ///
    /// The signal handler must not resolve paths itself: `StoragePaths.crashMarkerURL()` goes
    /// through `FileManager`, which allocates and takes locks internally, and doing that from a
    /// signal handler deadlocks whenever the crash happened while one of those locks was already
    /// held — the same class of bug `restorePreviousDisposition` exists to close for signal
    /// *dispositions*, here for the marker *write*. This buffer, and `signalSafeScratchBuffer`
    /// below, are the only state the handler touches, and both are pre-allocated: a `static var`
    /// initializes lazily on first access, so `prepareSignalSafeCrashMarkerPath()` must run from
    /// `setup(sessionID:)` — before `installSignalHandlers()` — to force that allocation to
    /// happen outside the handler, not the first time the handler itself reads it.
    private nonisolated(unsafe) static var signalSafePathBuffer = [UInt8](repeating: 0, count: 1024)
    private nonisolated(unsafe) static var signalSafePathLength = 0

    /// Reused scratch space for formatting the marker line. Mutated in place only — never
    /// resized or reassigned — so writing into it does not allocate.
    private nonisolated(unsafe) static var signalSafeScratchBuffer = [UInt8](repeating: 0, count: 64)

    /// The complete `SESSION_ID:<uuid>\n` line, formatted once on a normal thread.
    ///
    /// The signal handler cannot build this itself — `UUID.uuidString` allocates — but it must
    /// still be recorded: without it a crash is attributed to whatever session happens to be
    /// live when the marker is read on the *next* launch, not the session that actually
    /// crashed. Pre-formatting here keeps the handler down to a `write(2)` of bytes that were
    /// already sitting in memory.
    private nonisolated(unsafe) static var signalSafeSessionBuffer = [UInt8](repeating: 0, count: 64)
    private nonisolated(unsafe) static var signalSafeSessionLength = 0

    /// Resolves and caches the crash marker path for `writeCrashMarkerSignalSafe`. Safe to call
    /// repeatedly; must be called at least once, from a normal thread, before any signal handler
    /// can fire.
    private static func prepareSignalSafeCrashMarkerPath() {
        // Format the session line first, so it is ready (and its buffer's lazy static
        // initialization already forced) even if path resolution below fails.
        if let sessionID {
            let sessionBytes = Array("SESSION_ID:\(sessionID.uuidString)\n".utf8)
            let sessionCount = min(sessionBytes.count, signalSafeSessionBuffer.count)
            signalSafeSessionBuffer.withUnsafeMutableBufferPointer { buf in
                for i in 0..<sessionCount { buf[i] = sessionBytes[i] }
            }
            signalSafeSessionLength = sessionCount
        }

        guard let url = try? StoragePaths.crashMarkerURL() else { return }
        let bytes = Array(url.path.utf8)
        let count = min(bytes.count, signalSafePathBuffer.count - 1)
        signalSafePathBuffer.withUnsafeMutableBufferPointer { buf in
            for i in 0..<count { buf[i] = bytes[i] }
            buf[count] = 0 // NUL-terminate for `open`.
        }
        signalSafePathLength = count
        // Touch the scratch buffer too, so its first (allocating) access also happens here.
        signalSafeScratchBuffer.withUnsafeMutableBufferPointer { _ in }
    }

    /// Writes a minimal crash marker using only functions POSIX guarantees are safe to call from
    /// a signal handler: `open`, `write`, `close`. No Swift string interpolation, no Foundation,
    /// no `Date()`, and no heap allocation on this path — everything that could allocate was
    /// already done by `prepareSignalSafeCrashMarkerPath()`.
    ///
    /// Deliberately minimal: just the signal number. The richer marker with reason and stack
    /// trace (`writeCrashMarker` below) stays exactly as it was, because it is only ever called
    /// from the `NSUncaughtExceptionHandler` path, which runs as an ordinary function call on
    /// the throwing thread — not inside a signal handler — so Foundation is safe to use there.
    private static func writeCrashMarkerSignalSafe(signalNumber: Int32) {
        guard signalSafePathLength > 0 else { return }

        let fd = signalSafePathBuffer.withUnsafeMutableBufferPointer { pathBuf -> Int32 in
            pathBuf.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pathBuf.count) { cPath in
                open(cPath, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
            }
        }
        guard fd >= 0 else { return }

        signalSafeScratchBuffer.withUnsafeMutableBufferPointer { buf in
            var idx = 0
            let prefix: StaticString = "CRASH_SIGNAL:"
            prefix.withUTF8Buffer { p in
                for byte in p where idx < buf.count { buf[idx] = byte; idx += 1 }
            }

            // Manual decimal formatting: digits written directly into place, most-significant
            // digit first, with no intermediate array and no snprintf (whose async-signal
            // safety POSIX does not guarantee).
            if signalNumber == 0 {
                if idx < buf.count { buf[idx] = UInt8(ascii: "0"); idx += 1 }
            } else {
                var value = signalNumber
                var digitCount = 0
                var probe = value
                while probe > 0 { digitCount += 1; probe /= 10 }
                var writeIndex = idx + digitCount - 1
                while value > 0 && writeIndex >= 0 && writeIndex < buf.count {
                    buf[writeIndex] = UInt8(ascii: "0") + UInt8(value % 10)
                    value /= 10
                    writeIndex -= 1
                }
                idx += digitCount
            }
            if idx < buf.count { buf[idx] = UInt8(ascii: "\n"); idx += 1 }

            // `time(nil)` — unlike `Date()` — is on POSIX's async-signal-safe list, and is cheap
            // enough to include: the marker is otherwise useless for telling *when* a crash from
            // months of backlogged reports happened.
            let epochPrefix: StaticString = "CRASH_EPOCH:"
            epochPrefix.withUTF8Buffer { p in
                for byte in p where idx < buf.count { buf[idx] = byte; idx += 1 }
            }
            var epoch = Int64(time(nil))
            if epoch == 0 {
                if idx < buf.count { buf[idx] = UInt8(ascii: "0"); idx += 1 }
            } else {
                var digitCount = 0
                var probe = epoch
                while probe > 0 { digitCount += 1; probe /= 10 }
                var writeIndex = idx + digitCount - 1
                while epoch > 0 && writeIndex >= 0 && writeIndex < buf.count {
                    buf[writeIndex] = UInt8(ascii: "0") + UInt8(epoch % 10)
                    epoch /= 10
                    writeIndex -= 1
                }
                idx += digitCount
            }
            if idx < buf.count { buf[idx] = UInt8(ascii: "\n"); idx += 1 }

            // `idx` is advanced by a digit count that is computed before the bounds-checked
            // write loop, so clamp rather than trusting the two to agree: passing a length past
            // the end of the buffer would hand `write` unrelated heap bytes. Unreachable at the
            // current buffer size (the longest possible line is well under it), which is exactly
            // why it is worth pinning here rather than in arithmetic thirty lines away.
            _ = write(fd, buf.baseAddress, min(idx, buf.count))
        }

        // Pre-formatted on a normal thread — see signalSafeSessionBuffer. Written separately
        // so the handler never has to copy it anywhere first.
        if signalSafeSessionLength > 0 {
            signalSafeSessionBuffer.withUnsafeMutableBufferPointer { sessionBuf in
                _ = write(fd, sessionBuf.baseAddress, min(signalSafeSessionLength, sessionBuf.count))
            }
        }

        close(fd)
    }
    
    static func setup(sessionID: UUID) {
        self.sessionID = sessionID

        do {
            _ = try StoragePaths.ensureAppStatsDirectoryExists()
        } catch {
            Logger.warning("Crash marker storage unavailable: \(error)")
        }

        // Must run before installSignalHandlers(): resolves the crash marker path and forces
        // the scratch buffers' lazy static initialization, so the signal handler never performs
        // either for the first time from inside a signal.
        prepareSignalSafeCrashMarkerPath()

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

        // Write crash marker to file (for next launch detection). Deliberately the
        // *signal-safe* writer, not `writeCrashMarker` below: `Date()` and `signalNameForCode`
        // (a Swift String return) used to be called directly here, and neither is guaranteed
        // async-signal-safe — Foundation's `Date()` can allocate internally, and while a short
        // ASCII `String` literal usually avoids the heap via small-string optimization, that is
        // an implementation detail, not a language guarantee, and this is exactly the context
        // where relying on "usually" is how the previous bug in this file happened. The signal
        // number is all the safe path carries; the human-readable name is resolved later, on a
        // normal thread, when `consumePreviousCrash()` parses the marker back.
        writeCrashMarkerSignalSafe(signalNumber: signal)

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
            } else if line.hasPrefix("CRASH_SIGNAL:") {
                // Written by the async-signal-safe path, which cannot resolve a name string
                // (or even call Date()) from inside the handler — see writeCrashMarkerSignalSafe.
                // Translate the raw number back to a name here, on a normal thread, where doing
                // so is unremarkable.
                let value = line.dropFirst("CRASH_SIGNAL:".count).trimmingCharacters(in: .whitespaces)
                if let code = Int32(value) {
                    signal = signalNameForCode(code)
                }
            } else if line.hasPrefix("CRASH_EPOCH:") {
                let value = line.dropFirst("CRASH_EPOCH:".count).trimmingCharacters(in: .whitespaces)
                if let seconds = Double(value) {
                    timestamp = Date(timeIntervalSince1970: seconds)
                }
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
