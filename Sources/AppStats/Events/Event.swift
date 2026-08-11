// Event.swift - Core event model
// Copyright © 2026 One Thum Software

import Foundation

/// Represents an analytics event captured by the SDK.
public struct Event: Codable, Sendable {
    
    /// Event type classification
    public enum EventType: String, Codable, Sendable {
        case sessionStart = "session_start"
        case sessionEnd = "session_end"
        case screenView = "screen_view"
        case appLaunch = "app_launch"
        case appBackground = "app_background"
        case appForeground = "app_foreground"
        case crash = "crash"
        case custom = "custom"
    }
    
    // MARK: - Properties
    
    /// Unique event identifier
    public let id: UUID
    
    /// Event timestamp (device time)
    public let timestamp: Date
    
    /// Event type
    public let type: EventType
    
    /// Event name (for custom events)
    public let name: String?
    
    /// Session identifier
    public let sessionID: UUID
    
    /// Screen name (for screen_view events)
    public let screenName: String?
    
    /// App version
    public let appVersion: String
    
    /// Build number
    public let buildNumber: String
    
    /// Device model
    public let deviceModel: String
    
    /// OS version
    public let osVersion: String
    
    /// Platform (ios, macos, visionos)
    public let platform: String
    
    /// Screen resolution in pixels (e.g. "1290x2796")
    public let screenResolution: String
    
    /// Device locale (e.g. "en_US")
    public let locale: String
    
    /// Device timezone (e.g. "America/New_York")
    public let timezone: String
    
    /// SDK version
    public let sdkVersion: String
    
    /// Custom properties
    public let properties: [String: AnyCodable]?
    
    // MARK: - Initialization
    
    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        type: EventType,
        name: String? = nil,
        sessionID: UUID,
        screenName: String? = nil,
        properties: [String: Any]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.type = type
        self.name = name
        self.sessionID = sessionID
        self.screenName = screenName
        self.appVersion = AppInfo.version
        self.buildNumber = AppInfo.buildNumber
        self.deviceModel = DeviceInfo.deviceModel
        self.osVersion = DeviceInfo.osVersion
        self.platform = DeviceInfo.platform
        self.screenResolution = DeviceInfo.screenResolution
        self.locale = DeviceInfo.locale
        self.timezone = DeviceInfo.timezone
        self.sdkVersion = SDKInfo.version
        
        // Convert properties to AnyCodable
        if let props = properties {
            self.properties = props.mapValues { AnyCodable($0) }
        } else {
            self.properties = nil
        }
    }
    
    // MARK: - JSON Decoding
    
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        
        id             = try c.decode(UUID.self,    forKey: .id)
        timestamp      = try c.decode(Date.self,    forKey: .timestamp)
        type           = try c.decode(EventType.self, forKey: .type)
        name           = try c.decodeIfPresent(String.self, forKey: .name)
        sessionID      = try c.decode(UUID.self,    forKey: .sessionID)
        screenName     = try c.decodeIfPresent(String.self, forKey: .screenName)
        appVersion     = try c.decode(String.self,  forKey: .appVersion)
        buildNumber    = try c.decode(String.self,  forKey: .buildNumber)
        deviceModel    = try c.decode(String.self,  forKey: .deviceModel)
        osVersion      = try c.decode(String.self,  forKey: .osVersion)
        platform       = try c.decode(String.self,  forKey: .platform)
        
        // Migration-safe: New in 1.0.6 — fall back gracefully for events persisted by older SDK versions
        screenResolution = try c.decodeIfPresent(String.self, forKey: .screenResolution) ?? "unknown"
        locale           = try c.decodeIfPresent(String.self, forKey: .locale)           ?? "unknown"
        timezone         = try c.decodeIfPresent(String.self, forKey: .timezone)         ?? "unknown"
        
        sdkVersion     = try c.decode(String.self,  forKey: .sdkVersion)
        properties     = try c.decodeIfPresent([String: AnyCodable].self, forKey: .properties)
    }
    
    // MARK: - JSON Encoding
    
    enum CodingKeys: String, CodingKey {
        case id
        case timestamp
        case type = "event_type"
        case name = "event_name"
        case sessionID = "session_id"
        case screenName = "screen_name"
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case deviceModel = "device_model"
        case osVersion = "os_version"
        case platform
        case screenResolution = "screen_resolution"
        case locale
        case timezone
        case sdkVersion = "sdk_version"
        case properties
    }
}

// MARK: - AnyCodable

/// Type-erased wrapper for encoding any value to JSON
public enum AnyCodable: Codable, Sendable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    case string(String)
    case null
    
    init(_ value: Any) {
        if let intValue = value as? Int {
            self = .int(intValue)
        } else if let doubleValue = value as? Double {
            self = .double(doubleValue)
        } else if let boolValue = value as? Bool {
            self = .bool(boolValue)
        } else if let stringValue = value as? String {
            self = .string(stringValue)
        } else {
            self = .null
        }
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let intValue = try? container.decode(Int.self) {
            self = .int(intValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .double(doubleValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .bool(boolValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported type"
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    /// Unwraps back to the underlying value, for merging into an `Any`-typed properties dict.
    var unwrapped: Any {
        switch self {
        case .int(let value): return value
        case .double(let value): return value
        case .bool(let value): return value
        case .string(let value): return value
        case .null: return NSNull()
        }
    }
}
