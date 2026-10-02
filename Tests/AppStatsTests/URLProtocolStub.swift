// URLProtocolStub.swift - A scriptable URLProtocol for exercising NetworkManager without
// touching the network.
//
// NetworkManager takes `testProtocolClasses` for exactly this; in production it is nil and
// the session is configured the same way it always was.
//
// Copyright © 2026 One Thum Software

import Foundation
import XCTest

/// What the stub should do for one request.
enum StubOutcome: Sendable {
    case status(Int)
    case failure(URLError.Code)
}

/// A request as the stub saw it, with the body already drained.
struct CapturedRequest: Sendable {
    let url: URL?
    let headers: [String: String]
    let body: Data?

    func header(_ name: String) -> String? {
        // URLSession may normalise header case, so match the way HTTP does.
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Holds the script and the recording. A class with a lock rather than an actor: `URLProtocol`
/// callbacks are synchronous and cannot await.
final class StubBox: @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [StubOutcome] = []
    private var fallback: StubOutcome = .status(202)
    private var captured: [CapturedRequest] = []

    /// Outcomes are consumed in order; once exhausted, `fallback` applies to the rest.
    func script(_ outcomes: [StubOutcome], fallback: StubOutcome = .status(202)) {
        lock.lock(); defer { lock.unlock() }
        self.outcomes = outcomes
        self.fallback = fallback
        self.captured = []
    }

    func nextOutcome(recording request: CapturedRequest) -> StubOutcome {
        lock.lock(); defer { lock.unlock() }
        captured.append(request)
        return outcomes.isEmpty ? fallback : outcomes.removeFirst()
    }

    var requests: [CapturedRequest] {
        lock.lock(); defer { lock.unlock() }
        return captured
    }

    var requestCount: Int { requests.count }
}

final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    static let box = StubBox()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = CapturedRequest(
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.drainBody(of: request)
        )

        switch Self.box.nextOutcome(recording: captured) {
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))

        case .status(let statusCode):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data())
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    /// `httpBody` is nil by the time a request reaches a `URLProtocol` -- URLSession hands the
    /// body over as a stream -- so a stub that only reads `httpBody` silently sees nothing.
    private static func drainBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
