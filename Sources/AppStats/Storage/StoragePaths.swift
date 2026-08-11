// StoragePaths.swift - Platform-aware local storage paths
// Copyright © 2026 One Thum Software

import Foundation

enum StoragePaths {

    private static let appStatsDirectoryName = "AppStats"
    private static let eventsFileName = "events.json"
    private static let crashMarkerFileName = "crash.txt"
    private static let userPropertiesFileName = "user_properties.json"

    #if os(tvOS)
    private static let baseDirectoryKind: FileManager.SearchPathDirectory = .cachesDirectory
    #else
    private static let baseDirectoryKind: FileManager.SearchPathDirectory = .applicationSupportDirectory
    #endif

    static func appStatsDirectory(fileManager: FileManager = .default) throws -> URL {
        let baseDirectory = try fileManager.url(
            for: baseDirectoryKind,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )

        return baseDirectory.appendingPathComponent(appStatsDirectoryName, isDirectory: true)
    }

    static func ensureAppStatsDirectoryExists(fileManager: FileManager = .default) throws -> URL {
        let directory = try appStatsDirectory(fileManager: fileManager)

        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        return directory
    }

    static func eventsFileURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try appStatsDirectory(fileManager: fileManager)
        return directory.appendingPathComponent(eventsFileName)
    }

    static func crashMarkerURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try appStatsDirectory(fileManager: fileManager)
        return directory.appendingPathComponent(crashMarkerFileName)
    }

    static func userPropertiesFileURL(fileManager: FileManager = .default) throws -> URL {
        let directory = try appStatsDirectory(fileManager: fileManager)
        return directory.appendingPathComponent(userPropertiesFileName)
    }
}
