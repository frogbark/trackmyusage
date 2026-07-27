import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Drives an adapter end to end and never throws.
///
/// Adapters implement `request` and `parse`; every way those can go wrong is turned into a
/// status here, once, so seventeen integrations cannot disagree about what an outage looks
/// like. At any moment at least one provider is down, rate-limited or simply not connected —
/// that is the steady state, not an exception, and propagating it would let a single timeout
/// take out the render for everything else.
public struct ProviderRunner: Sendable {

    private let executor: RequestExecutor

    public init(executor: RequestExecutor = URLSessionExecutor()) {
        self.executor = executor
    }

    /// Reads the credential, then runs. The read happens before any suspension so a
    /// non-Sendable store never crosses an await.
    public func snapshot(
        of adapter: any UsageProviderAdapter, credentials: any CredentialStore, now: Date
    ) async -> ProviderSnapshot {
        let credential: String?
        do {
            credential = try credentials.get(adapter.credentialSpec.keychainService)
        } catch {
            return failed(adapter, .unavailable("could not read the credential: \(error)"), now)
        }
        return await snapshot(of: adapter, credential: credential, now: now)
    }

    public func snapshot(
        of adapter: any UsageProviderAdapter, credential: String?, now: Date
    ) async -> ProviderSnapshot {
        guard let credential, !credential.isEmpty else {
            // Nothing is sent. A provider nobody has connected should cost no network call
            // and no rate-limit budget.
            return failed(adapter, .unauthorized, now)
        }

        let request: URLRequest
        do {
            request = try adapter.request(credential: credential)
        } catch {
            return failed(adapter, .unavailable(reason(error)), now)
        }

        let response: HTTPResponse
        do {
            response = try await executor.execute(request)
        } catch {
            return failed(adapter, .unavailable(reason(error)), now)
        }

        // A rejected token is a different problem from a provider being down: one needs a
        // new credential, the other needs waiting. Collapsing them would send people to
        // re-paste a token that was fine.
        guard !response.isRejected else { return failed(adapter, .unauthorized, now) }
        guard response.isOK else {
            return failed(adapter, .unavailable("HTTP \(response.status)"), now)
        }

        do {
            return try adapter.parse(response.body, now: now)
        } catch {
            // Providers reshape their responses without warning. That should cost one blank
            // row rather than the whole render.
            return failed(adapter, .unavailable(reason(error)), now)
        }
    }

    /// A failed provider keeps its identity and still occupies its row — dropping it would
    /// make an outage look identical to never having configured the thing at all.
    private func failed(
        _ adapter: any UsageProviderAdapter, _ status: ProviderSnapshot.Status, _ now: Date
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: adapter.id, accountLabel: nil, capturedAt: now, status: status,
            metrics: [])
    }

    private func reason(_ error: Error) -> String {
        if let provider = error as? ProviderError { return provider.description }
        if let url = error as? URLError { return url.localizedDescription }
        return "\(error)"
    }
}
