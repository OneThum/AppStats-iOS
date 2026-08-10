// DeviceInfo.swift - Device metadata utilities
// Copyright © 2026 One Thum Software

import Foundation

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Provides information about the device
enum DeviceInfo {
    
    /// Device model identifier (e.g., "iPhone15,2")
    static var deviceModel: String {
        #if canImport(UIKit)
        var systemInfo = utsname()
        uname(&systemInfo)
        let machineMirror = Mirror(reflecting: systemInfo.machine)
        let identifier = machineMirror.children.reduce("") { identifier, element in
            guard let value = element.value as? Int8, value != 0 else { return identifier }
            return identifier + String(UnicodeScalar(UInt8(value)))
        }
        return identifier
        #elseif canImport(AppKit)
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        // Convert CChar to UInt8 for UTF8 decoding
        let bytes = model.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
        #else
        return "unknown"
        #endif
    }
    
    /// OS version (e.g., "17.4.1")
    /// Uses ProcessInfo so this stays nonisolated under Swift 6 (UIDevice is MainActor).
    static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
    
    /// Platform identifier
    static var platform: String {
        #if os(iOS)
        return "ios"
        #elseif os(macOS)
        return "macos"
        #elseif os(visionOS)
        return "visionos"
        #elseif os(tvOS)
        return "tvos"
        #elseif os(watchOS)
        return "watchos"
        #else
        return "unknown"
        #endif
    }
    
    /// Screen resolution (width x height)
    static var screenResolution: String {
        #if canImport(UIKit) && !os(watchOS)
        if Thread.isMainThread {
            return MainActor.assumeIsolated { uiKitScreenResolution() }
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated { uiKitScreenResolution() }
        }
        #elseif canImport(AppKit)
        guard let screen = NSScreen.main else { return "unknown" }
        let frame = screen.frame
        let backing = screen.backingScaleFactor
        let width = Int(frame.width * backing)
        let height = Int(frame.height * backing)
        return "\(width)x\(height)"
        #else
        return "unknown"
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    @MainActor
    private static func uiKitScreenResolution() -> String {
        let screen = UIScreen.main
        let scale = screen.scale
        let bounds = screen.bounds
        let width = Int(bounds.width * scale)
        let height = Int(bounds.height * scale)
        return "\(width)x\(height)"
    }
    #endif
    
    /// Device locale
    static var locale: String {
        Locale.current.identifier
    }
    
    /// Device timezone
    static var timezone: String {
        TimeZone.current.identifier
    }
    
    /// Total memory in bytes
    static var totalMemory: UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }
    
    /// Low power mode enabled (iOS only)
    static var isLowPowerModeEnabled: Bool {
        #if canImport(UIKit) && !os(tvOS) && !os(watchOS)
        return ProcessInfo.processInfo.isLowPowerModeEnabled
        #else
        return false
        #endif
    }
}
