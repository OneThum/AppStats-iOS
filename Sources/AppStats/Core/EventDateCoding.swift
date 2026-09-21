// EventDateCoding.swift - Event timestamp encoding
// Copyright © 2026 One Thum Software

import Foundation

/// How the SDK writes and reads event timestamps, on the wire and on disk.
///
/// Timestamps carry millisecond precision ("2026-09-18T01:55:22.123Z"), matching
/// the Android SDK. `JSONEncoder`'s built-in `.iso8601` strategy writes whole
/// seconds, so every event created within the same second shared a timestamp:
/// the dashboard could not tell which of `app_background` and `session_end`
/// came first, or order two screen views in the same second.
///
/// Decoding accepts both forms. Events already queued on disk by earlier SDK
/// versions are whole-second, and `JSONDecoder`'s built-in `.iso8601` strategy
/// rejects fractional seconds outright -- so changing only the encoder would
/// make every event queued by this version unreadable after the next launch.
enum EventDateCoding {
    private static let withFractionalSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let wholeSeconds = Date.ISO8601FormatStyle()

    /// UTC, millisecond precision.
    static func string(from date: Date) -> String {
        date.formatted(withFractionalSeconds)
    }

    /// Accepts ISO-8601 with or without fractional seconds.
    static func date(from string: String) -> Date? {
        if let date = try? withFractionalSeconds.parse(string) { return date }
        return try? wholeSeconds.parse(string)
    }
}

extension JSONEncoder.DateEncodingStrategy {
    /// Millisecond-precision ISO-8601. Use for every encoder that writes events.
    static var appStatsISO8601: Self {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(EventDateCoding.string(from: date))
        }
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// ISO-8601 with or without fractional seconds. Use for every decoder that
    /// reads events, so queues written by earlier SDK versions still load.
    static var appStatsISO8601: Self {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = EventDateCoding.date(from: string) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected an ISO-8601 date, got \(string)"
                )
            }
            return date
        }
    }
}
