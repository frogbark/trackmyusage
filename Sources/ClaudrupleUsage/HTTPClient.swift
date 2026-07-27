import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct HTTPResponse: Sendable, Equatable {
    public let status: Int
    public let body: Data

    public init(status: Int, body: Data) {
        self.status = status
        self.body = body
    }

    public var isOK: Bool { (200..<300).contains(status) }
}

/// The one call every adapter needs.
///
/// Narrow on purpose. Usage endpoints are reads, so an adapter that could POST would be an
/// adapter that could be made to change something — and the whole credential story here is
/// that a leaked token cannot.
public protocol HTTPClient: Sendable {
    func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse
}

public enum HTTPError: Error, Equatable, CustomStringConvertible {
    case status(Int)
    case noFixture(String)
    case malformedResponse(String)

    public var description: String {
        switch self {
        case .status(let code): return "HTTP \(code)"
        case .noFixture(let url): return "no recorded response for \(url)"
        case .malformedResponse(let detail): return "unexpected response shape: \(detail)"
        }
    }
}

public struct URLSessionHTTPClient: HTTPClient {

    private let session: URLSession

    /// A short timeout on purpose: this runs on a timer, and a provider that hangs should
    /// cost one slow render rather than block the other sixteen behind it.
    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "Claudruple/0.1"]
        self.session = URLSession(configuration: configuration)
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return HTTPResponse(status: status, body: data)
    }
}

/// Replays recorded responses.
///
/// What makes seventeen adapters maintainable by people who do not hold seventeen paid
/// accounts: the fixture is the contract, so a contributor can change an adapter and know
/// whether they broke it without spending a penny or waiting on a rate limit.
public struct FixtureHTTPClient: HTTPClient {

    private let responses: [String: HTTPResponse]
    public let recordedRequests: RequestLog

    public struct Request: Sendable, Equatable {
        public let url: URL
        public let headers: [String: String]
    }

    public final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [Request] = []

        public var all: [Request] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func record(_ request: Request) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }
    }

    public init(responses: [String: HTTPResponse]) {
        self.responses = responses
        self.recordedRequests = RequestLog()
    }

    /// Convenience for the common case of a single 200 with a JSON body.
    public init(json: [String: String]) {
        self.init(
            responses: json.mapValues { HTTPResponse(status: 200, body: Data($0.utf8)) })
    }

    public func get(_ url: URL, headers: [String: String]) async throws -> HTTPResponse {
        recordedRequests.record(Request(url: url, headers: headers))
        // An unrecorded URL is a failure rather than an empty success. A silently empty
        // response would let an adapter that calls the wrong endpoint pass its tests.
        guard let response = responses[url.absoluteString] else {
            throw HTTPError.noFixture(url.absoluteString)
        }
        return response
    }
}
