// EventDateCodingTests.swift - Event timestamp encoding
// Copyright © 2026 One Thum Software

import XCTest
@testable import AppStats

final class EventDateCodingTests: XCTestCase {

    /// 2026-09-18T01:55:22.250Z. A quarter second is exact in binary floating
    /// point, so the expected string does not depend on rounding.
    private let reference: Date = {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 18
        components.hour = 1
        components.minute = 55
        components.second = 22
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!.addingTimeInterval(0.25)
    }()

    // MARK: - Encoding

    func testEncodesUTCWithMillisecondPrecision() {
        XCTAssertEqual(EventDateCoding.string(from: reference), "2026-09-18T01:55:22.250Z")
    }

    func testEventsInTheSameSecondNoLongerShareATimestamp() {
        // The bug this fixes: whole-second encoding gave both of these the same
        // timestamp, so the dashboard could not tell which happened first.
        let background = reference
        let sessionEnd = reference.addingTimeInterval(0.1)
        let a = EventDateCoding.string(from: background)
        let b = EventDateCoding.string(from: sessionEnd)
        XCTAssertNotEqual(a, b)
        XCTAssertLessThan(a, b, "string order must match time order")
    }

    // MARK: - Decoding

    func testDecodesMillisecondTimestamps() {
        XCTAssertEqual(EventDateCoding.date(from: "2026-09-18T01:55:22.250Z"), reference)
    }

    func testDecodesWholeSecondTimestampsWrittenByEarlierVersions() {
        XCTAssertEqual(EventDateCoding.date(from: "2026-09-18T01:55:22Z"), reference.addingTimeInterval(-0.25))
    }

    func testRejectsNonDates() {
        XCTAssertNil(EventDateCoding.date(from: "yesterday"))
        XCTAssertNil(EventDateCoding.date(from: ""))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .appStatsISO8601
        XCTAssertThrowsError(try decoder.decode([Date].self, from: Data(#"["not a date"]"#.utf8)))
    }

    // MARK: - Upgrade path

    /// A queue saved to disk by an earlier SDK version -- written with
    /// JSONEncoder's built-in whole-second `.iso8601` -- must still load after
    /// upgrading. Otherwise every event queued before the update is lost.
    func testQueueWrittenByEarlierVersionStillLoads() throws {
        let session = UUID()
        let queued = [
            Event(timestamp: reference, type: .sessionStart, sessionID: session),
            Event(timestamp: reference.addingTimeInterval(4), type: .screenView, sessionID: session, screenName: "Home"),
        ]
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        let legacyData = try legacyEncoder.encode(queued)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .appStatsISO8601
        let loaded = try decoder.decode([Event].self, from: legacyData)

        XCTAssertEqual(loaded.map(\.id), queued.map(\.id))
        XCTAssertEqual(loaded[0].timestamp, reference.addingTimeInterval(-0.25), "legacy format is whole-second")
        XCTAssertEqual(loaded[1].screenName, "Home")
    }

    /// And a queue written by this version must load back -- the half of the
    /// upgrade that switching only the encoder would break.
    func testEventRoundTripsKeepingMilliseconds() throws {
        // .3733 rather than .373: away from a millisecond boundary, so the expected
        // string holds whether Foundation rounds or truncates the fraction.
        let original = Event(timestamp: reference.addingTimeInterval(0.1233), type: .appBackground, sessionID: UUID())

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .appStatsISO8601
        let data = try encoder.encode([original])
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("2026-09-18T01:55:22.373Z"), "wire format carries milliseconds: \(json)")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .appStatsISO8601
        let loaded = try decoder.decode([Event].self, from: data)
        XCTAssertEqual(
            loaded[0].timestamp.timeIntervalSince1970,
            original.timestamp.timeIntervalSince1970,
            accuracy: 0.001
        )
    }

    /// Ordering survives a round trip: events in the same second come back in
    /// the order they happened.
    func testSameSecondOrderSurvivesRoundTrip() throws {
        let session = UUID()
        let events = [
            Event(timestamp: reference, type: .appBackground, sessionID: session),
            Event(timestamp: reference.addingTimeInterval(0.004), type: .sessionEnd, sessionID: session),
        ]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .appStatsISO8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .appStatsISO8601
        let loaded = try decoder.decode([Event].self, from: encoder.encode(events))
        XCTAssertLessThan(loaded[0].timestamp, loaded[1].timestamp)
    }
}
