// EventWireFormatTests.swift - The JSON an Event becomes.
//
// The ingestion API validates every event against schemas/event.v1.json but does not reject
// it, so a field renamed on either side is accepted, stored half-empty, and only shows up as
// "[SchemaValidator] Invalid event" in a server log nobody is watching. That is how the test
// payloads in the repository drifted to camelCase for months without a single failure.
//
// These assert the encoded keys and values directly. The repository's JS suite checks the
// same names against the schema document, so between them a rename fails on whichever side
// moves first.
//
// Copyright © 2026 One Thum Software

import XCTest
@testable import AppStats

final class EventWireFormatTests: XCTestCase {

    private let sessionID = UUID()

    private func encode(_ event: Event) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .appStatsISO8601
        let data = try encoder.encode(event)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// Every key the schema requires, in the schema's spelling.
    private static let requiredKeys = [
        "id", "timestamp", "event_type", "session_id", "app_version", "build_number",
        "device_model", "os_version", "platform", "screen_resolution", "locale",
        "timezone", "sdk_version",
    ]

    /// The optional ones. Nothing outside these two sets may appear: the schema sets
    /// additionalProperties to false, so one stray key invalidates the whole event.
    private static let optionalKeys = ["event_name", "screen_name", "properties"]

    func testEncodesEveryKeyTheSchemaRequires() throws {
        let json = try encode(Event(type: .custom, name: "wire", sessionID: sessionID))

        let missing = Self.requiredKeys.filter { json[$0] == nil }
        XCTAssertEqual(missing, [], "required keys missing from the encoded event")
    }

    func testEncodesNoKeyTheSchemaDoesNotDefine() throws {
        let json = try encode(
            Event(type: .screenView, name: nil, sessionID: sessionID,
                  screenName: "Settings", properties: ["k": "v"])
        )

        let allowed = Set(Self.requiredKeys + Self.optionalKeys)
        let unexpected = json.keys.filter { !allowed.contains($0) }.sorted()
        XCTAssertEqual(unexpected, [], "camelCase or new keys would invalidate the event")
    }

    func testUsesTheSnakeCaseSpellingTheBackendReads() throws {
        let json = try encode(Event(type: .custom, name: "wire", sessionID: sessionID))

        // The mistake this guards is the obvious one: sessionId for session_id.
        for camel in ["sessionID", "sessionId", "appVersion", "buildNumber", "deviceModel",
                      "osVersion", "screenResolution", "sdkVersion", "eventType", "eventName"] {
            XCTAssertNil(json[camel], "\(camel) should be snake_case on the wire")
        }
        XCTAssertEqual(json["session_id"] as? String, sessionID.uuidString)
        XCTAssertEqual(json["event_type"] as? String, "custom")
        XCTAssertEqual(json["event_name"] as? String, "wire")
    }

    func testEncodesEveryEventTypeAsTheSchemaSpellsIt() throws {
        let expected: [Event.EventType: String] = [
            .sessionStart: "session_start",
            .sessionEnd: "session_end",
            .screenView: "screen_view",
            .appLaunch: "app_launch",
            .appBackground: "app_background",
            .appForeground: "app_foreground",
            .crash: "crash",
            .custom: "custom",
        ]

        for (type, wireValue) in expected {
            let json = try encode(Event(type: type, sessionID: sessionID))
            XCTAssertEqual(json["event_type"] as? String, wireValue)
        }

        XCTAssertEqual(expected.count, 8, "a new event type needs adding to the schema too")
    }

    func testReportsAPlatformTheSchemaAccepts() throws {
        let json = try encode(Event(type: .custom, name: "wire", sessionID: sessionID))
        let platform = try XCTUnwrap(json["platform"] as? String)

        // The schema's enum. "android" is the Kotlin SDK's; this one never emits it.
        XCTAssertTrue(
            ["ios", "macos", "visionos", "tvos", "watchos", "unknown"].contains(platform),
            "unexpected platform value: \(platform)"
        )
        XCTAssertNotEqual(platform, "android")
    }

    func testTimestampCarriesMillisecondsAndIsUTC() throws {
        let moment = Date(timeIntervalSince1970: 1_790_000_000.123)
        let json = try encode(
            Event(timestamp: moment, type: .custom, name: "wire", sessionID: sessionID)
        )

        let timestamp = try XCTUnwrap(json["timestamp"] as? String)

        // Shape, not an exact figure: .123 seconds is not representable as a Double, so
        // asserting the literal "123" fails on a rounding artefact rather than on anything
        // the SDK did. EventDateCodingTests covers the precision itself.
        XCTAssertNotNil(
            timestamp.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$"#,
                            options: .regularExpression),
            "expected ISO-8601 UTC with exactly three fractional digits, got \(timestamp)"
        )

        // And it round-trips to the instant it was given, to the millisecond the format keeps.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .appStatsISO8601
        let decoded = try decoder.decode(
            Event.self,
            from: JSONSerialization.data(withJSONObject: json)
        )
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970,
                       moment.timeIntervalSince1970, accuracy: 0.002)
    }

    func testOmitsOptionalFieldsRatherThanSendingEmptyStrings() throws {
        // A custom event has no screen name. Sending "" would store an empty string the
        // dashboard then has to special-case.
        let json = try encode(Event(type: .custom, name: "wire", sessionID: sessionID))

        XCTAssertNil(json["screen_name"])
        XCTAssertNil(json["properties"])
    }

    func testKeepsPrimitivePropertiesAsTheirOwnTypes() throws {
        let json = try encode(Event(
            type: .custom,
            name: "purchase_completed",
            sessionID: sessionID,
            properties: [
                "product_id": "premium_subscription",
                "price": 9.99,
                "quantity": 2,
                "gift": true,
            ]
        ))

        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual(properties["product_id"] as? String, "premium_subscription")
        XCTAssertEqual(properties["price"] as? Double, 9.99)
        XCTAssertEqual(properties["quantity"] as? Int, 2)
        XCTAssertEqual(properties["gift"] as? Bool, true)
    }

    func testCollapsesANonPrimitivePropertyToNull() throws {
        // The schema allows only string, number, boolean and null in properties. A developer
        // passing a dictionary or an array gets null rather than a nested object that would
        // invalidate the event.
        let json = try encode(Event(
            type: .custom,
            name: "wire",
            sessionID: sessionID,
            properties: [
                "nested": ["a": 1],
                "list": [1, 2, 3],
                "fine": "kept",
            ]
        ))

        let properties = try XCTUnwrap(json["properties"] as? [String: Any])
        XCTAssertEqual(properties["fine"] as? String, "kept")
        XCTAssertTrue(properties["nested"] is NSNull, "a dictionary must not reach the wire")
        XCTAssertTrue(properties["list"] is NSNull, "an array must not reach the wire")
    }

    func testIdAndSessionIdAreUUIDsTheBackendCanStore() throws {
        // Both columns are uuid in Postgres, so a non-UUID string is rejected on insert
        // rather than merely logged.
        let json = try encode(Event(type: .custom, name: "wire", sessionID: sessionID))

        let id = try XCTUnwrap(json["id"] as? String)
        XCTAssertNotNil(UUID(uuidString: id))
        let session = try XCTUnwrap(json["session_id"] as? String)
        XCTAssertNotNil(UUID(uuidString: session))
    }

    func testEachEventGetsItsOwnIdentity() throws {
        let first = try encode(Event(type: .custom, name: "wire", sessionID: sessionID))
        let second = try encode(Event(type: .custom, name: "wire", sessionID: sessionID))

        XCTAssertNotEqual(first["id"] as? String, second["id"] as? String)
        // Same session though -- the session only rotates on a foreground transition.
        XCTAssertEqual(first["session_id"] as? String, second["session_id"] as? String)
    }
}
