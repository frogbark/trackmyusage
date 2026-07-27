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
    /// A credential the provider actively rejected, as opposed to one that is simply absent.
    public var isRejected: Bool { status == 401 || status == 403 }
}

/// Sends a request an adapter built.
///
/// Adapters produce a `URLRequest` and never send it themselves, which is what lets every
/// one of them be exercised against a recorded response.
public protocol RequestExecutor: Sendable {
    func execute(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionExecutor: RequestExecutor {

    private let session: URLSession

    /// A short timeout on purpose: this runs on a timer, and a provider that hangs should
    /// cost one slow render rather than block the others behind it.
    public init(timeout: TimeInterval = 15) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.httpAdditionalHeaders = ["User-Agent": "Claudruple/0.1"]
        self.session = URLSession(configuration: configuration)
    }

    public func execute(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        return HTTPResponse(
            status: (response as? HTTPURLResponse)?.statusCode ?? 0, body: data)
    }
}

/// Replays recorded responses, keyed by absolute URL.
///
/// What makes seventeen adapters maintainable by people who do not hold seventeen paid
/// accounts: the fixture is the contract, so a contributor can change an adapter and learn
/// whether they broke it without spending a penny or waiting out a rate limit.
public struct FixtureExecutor: RequestExecutor {

    private let responses: [String: HTTPResponse]
    public let recorded: Log

    public final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [URLRequest] = []

        public var all: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        func record(_ request: URLRequest) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }
    }

    public init(responses: [String: HTTPResponse]) {
        self.responses = responses
        self.recorded = Log()
    }

    /// The common case: one 200 with a JSON body.
    public init(json: [String: String]) {
        self.init(
            responses: json.mapValues { HTTPResponse(status: 200, body: Data($0.utf8)) })
    }

    public func execute(_ request: URLRequest) async throws -> HTTPResponse {
        recorded.record(request)
        // An unrecorded URL fails rather than returning an empty success. A silently empty
        // response would let an adapter that calls the wrong endpoint pass its own tests.
        guard let url = request.url?.absoluteString, let response = responses[url] else {
            throw ProviderError.unexpectedResponse(
                provider: "fixture",
                detail: "no recorded response for \(request.url?.absoluteString ?? "nil")")
        }
        return response
    }
}
