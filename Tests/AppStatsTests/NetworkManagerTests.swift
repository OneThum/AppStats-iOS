// NetworkManagerTests.swift - What actually goes over the wire, and what happens when it
// fails.
//
// The headers and constants here are also asserted from the repository's JS test suite by
// reading this source, which catches a rename. These run the code, which catches the rest:
// that the compressed body is the format the Content-Encoding claims, that a retry really
// stops after two attempts, and that the circuit breaker stops making requests at all.
//
// Copyright © 2026 One Thum Software

import XCTest
#if canImport(Compression)
import Compression
#endif
@testable import AppStats

final class NetworkManagerTests: XCTestCase {

    private let sessionID = UUID()

    private func makeNetwork() -> NetworkManager {
        NetworkManager(
            apiKey: "as_test_00000000000000000042",
            baseURL: URL(string: "https://ingest.example.invalid")!,
            testProtocolClasses: [URLProtocolStub.self]
        )
    }

    private func event(_ name: String = "wire_test") -> Event {
        Event(type: .custom, name: name, sessionID: sessionID)
    }

    // MARK: - Request shape

    func testPostsToV1IngestWithTheCanonicalHeaders() async throws {
        URLProtocolStub.box.script([.status(202)])

        try await makeNetwork().sendEvents([event()])

        let request = try XCTUnwrap(URLProtocolStub.box.requests.first)
        XCTAssertEqual(request.url?.path, "/v1/ingest")
        XCTAssertEqual(request.header("X-AS-Key"), "as_test_00000000000000000042")
        XCTAssertEqual(request.header("X-AS-SDK-Version"), SDKInfo.version)
        XCTAssertEqual(request.header("X-AS-SDK-Platform"), "swift")
        XCTAssertEqual(request.header("Content-Type"), "application/json")

        // X-API-Key is a legacy alias the server still accepts. The SDK must not revive it.
        XCTAssertNil(request.header("X-API-Key"))
    }

    func testCompressedBodyIsTheFormatTheContentEncodingClaims() async throws {
        URLProtocolStub.box.script([.status(202)])
        let sent = [event("first"), event("second")]

        try await makeNetwork().sendEvents(sent)

        let request = try XCTUnwrap(URLProtocolStub.box.requests.first)
        XCTAssertEqual(request.header("Content-Encoding"), "deflate")

        let body = try XCTUnwrap(request.body)
        XCTAssertFalse(body.isEmpty)

        // Apple's COMPRESSION_ZLIB emits raw DEFLATE (RFC 1951), not zlib-wrapped (RFC 1950),
        // so the body carries no 0x78 header. The ingestion service sniffs these two bytes to
        // choose inflateRawSync over unzipSync; this asserts which branch it will take, and
        // that the body is not secretly gzip -- the SDK once declared gzip while sending
        // zlib, and the server refused every event.
        XCTAssertNotEqual(body[body.startIndex], 0x78, "unexpected zlib header")
        XCTAssertFalse(body.starts(with: [0x1f, 0x8b]), "body is gzip, but we said deflate")

        let decoded = try XCTUnwrap(Self.inflateRaw(body))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .appStatsISO8601
        let received = try decoder.decode([Event].self, from: decoded)

        XCTAssertEqual(received.map(\.id), sent.map(\.id))
        XCTAssertEqual(received.map(\.name), ["first", "second"])
    }

    func testCompressionActuallyShrinksARealisticBatch() async throws {
        URLProtocolStub.box.script([.status(202)])
        // 50 similar events: the shape a flush actually sends, and highly compressible.
        let batch = (0..<50).map { _ in event("repeated_event_name") }

        try await makeNetwork().sendEvents(batch)

        let body = try XCTUnwrap(URLProtocolStub.box.requests.first?.body)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .appStatsISO8601
        let raw = try encoder.encode(batch)

        XCTAssertLessThan(body.count, raw.count / 2, "compression is not doing anything useful")
    }

    // MARK: - Retries

    func testRetriesATransientFailureTwiceThenGivesUp() async throws {
        // Three attempts in total: the first plus two retries (retryCount < 2).
        URLProtocolStub.box.script(
            [.failure(.timedOut), .failure(.timedOut), .failure(.timedOut)],
            fallback: .failure(.timedOut)
        )

        do {
            try await makeNetwork().sendEvents([event()])
            XCTFail("expected the send to throw once retries were exhausted")
        } catch {
            // Expected.
        }

        XCTAssertEqual(URLProtocolStub.box.requestCount, 3)
    }

    func testASucceedingRetryStopsRetrying() async throws {
        URLProtocolStub.box.script([.failure(.timedOut), .status(202)])

        try await makeNetwork().sendEvents([event()])

        XCTAssertEqual(URLProtocolStub.box.requestCount, 2)
    }

    func testDoesNotRetryAnErrorThatWillNotFixItself() async throws {
        // .badServerResponse is not in shouldRetryError, so there is no second attempt.
        URLProtocolStub.box.script([.failure(.badServerResponse)], fallback: .status(202))

        do {
            try await makeNetwork().sendEvents([event()])
            XCTFail("expected the send to throw")
        } catch {
            // Expected.
        }

        XCTAssertEqual(URLProtocolStub.box.requestCount, 1)
    }

    func testDoesNotRetryAClientError() async throws {
        // A 401 means the key is wrong; sending it again cannot help, and a retry would
        // multiply the load for every misconfigured app in the field.
        URLProtocolStub.box.script([.status(401)], fallback: .status(202))

        do {
            try await makeNetwork().sendEvents([event()])
            XCTFail("expected a client error")
        } catch NetworkError.clientError(let code) {
            XCTAssertEqual(code, 401)
        }

        XCTAssertEqual(URLProtocolStub.box.requestCount, 1)
    }

    func testRetriesAServerError() async throws {
        // A 5xx is the server's problem and may well be gone next time, but it is not a
        // URLError, so it surfaces rather than being retried in place.
        URLProtocolStub.box.script([.status(503)], fallback: .status(202))

        do {
            try await makeNetwork().sendEvents([event()])
            XCTFail("expected a server error")
        } catch NetworkError.serverError(let code) {
            XCTAssertEqual(code, 503)
        }

        XCTAssertEqual(URLProtocolStub.box.requestCount, 1)
    }

    // MARK: - Circuit breaker

    func testStopsMakingRequestsOnceTheCircuitOpens() async throws {
        // maxConsecutiveFailures is 10. Each 503 counts once, so the tenth opens the circuit
        // and the eleventh send must not reach the network at all.
        URLProtocolStub.box.script([], fallback: .status(503))
        let network = makeNetwork()

        for _ in 0..<10 {
            do { try await network.sendEvents([event()]) } catch { /* counted */ }
        }
        XCTAssertEqual(URLProtocolStub.box.requestCount, 10)

        do {
            try await network.sendEvents([event()])
            XCTFail("expected the open circuit to refuse the send")
        } catch NetworkError.inBackoff {
            // Expected.
        }

        XCTAssertEqual(
            URLProtocolStub.box.requestCount, 10,
            "an open circuit must not put another request on the wire"
        )
    }

    func testASuccessClearsTheFailureCountSoTheCircuitStaysClosed() async throws {
        // Nine failures then a success: the counter resets, so nine more must not open it.
        var script: [StubOutcome] = Array(repeating: .status(503), count: 9)
        script.append(.status(202))
        script.append(contentsOf: Array(repeating: .status(503), count: 9))
        URLProtocolStub.box.script(script, fallback: .status(503))

        let network = makeNetwork()
        for _ in 0..<19 {
            do { try await network.sendEvents([event()]) } catch { /* counted */ }
        }

        XCTAssertEqual(
            URLProtocolStub.box.requestCount, 19,
            "the circuit should still be closed after a success reset the count"
        )
    }

    // MARK: - Helpers

    /// Inflate raw DEFLATE, the format Apple's COMPRESSION_ZLIB produces.
    private static func inflateRaw(_ data: Data) -> Data? {
        #if canImport(Compression)
        // Generous destination: these payloads are small and highly compressible.
        let capacity = max(data.count * 50, 64 * 1024)
        var destination = Data(count: capacity)

        let written = destination.withUnsafeMutableBytes { destinationPointer -> Int in
            data.withUnsafeBytes { sourcePointer -> Int in
                compression_decode_buffer(
                    destinationPointer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    capacity,
                    sourcePointer.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0 else { return nil }
        return destination.prefix(written)
        #else
        return data
        #endif
    }
}
