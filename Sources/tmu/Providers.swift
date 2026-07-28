import Foundation
import TMUProviders

/// `tmu provider …`
enum ProviderCommands {

    static func run(_ args: [String]) {
        switch args.first {
        case "list", nil: list()
        case "add": add(id: args.count > 1 ? args[1] : nil)
        case "remove": remove(id: args.count > 1 ? args[1] : nil)
        case "probe": probe(id: args.count > 1 ? args[1] : nil)
        case "check": check()
        default:
            FileHandle.standardError.write(Data("unknown: provider \(args[0])\n".utf8))
            exit(1)
        }
    }

    private static let credentials = KeychainCredentials()

    private static func find(_ id: String?) -> any UsageProvider {
        guard let id, let p = ProviderRegistry.provider(id: id) else {
            die(
                "unknown provider. Known: "
                    + ProviderRegistry.all().map(\.id).joined(separator: ", "))
        }
        return p
    }

    // MARK: - list

    private static func list() {
        print("\n  provider      credential   requires")
        for p in ProviderRegistry.all() {
            let stored = ((try? credentials.secret(for: p.id)) ?? nil) != nil
            print(
                "  \(pad(p.id, 13)) \(pad(stored ? "stored" : "—", 12)) "
                    + (p.credentialSpec.required ? "a token" : "optional"))
        }
        print(
            """

              Not yet implemented: \(ProviderRegistry.pending.joined(separator: ", ")).
              Each needs its real response captured first — see `provider probe`.

            """)
    }

    // MARK: - add / remove

    private static func add(id: String?) {
        let p = find(id)
        let spec = p.credentialSpec
        print("\n  \(p.id)")
        if let url = spec.createURL { print("  create a key: \(url)") }
        print("  minimum scope: \(spec.readOnlyScope)")
        print("  \(spec.instructions)")
        if let w = spec.scopeWarning { print("  note: \(w)") }
        print("\n  paste the credential:")

        // Read from stdin rather than a flag: an argument lands in shell history and in the
        // process list, where any other user on the machine can read it.
        guard let secret = readLine(strippingNewline: true), !secret.isEmpty else {
            die("nothing entered")
        }
        do {
            try credentials.set(secret, for: p.id)
            print("  stored in the login keychain\n")
        } catch {
            die("\(error)")
        }
    }

    private static func remove(id: String?) {
        let p = find(id)
        try? credentials.set(nil, for: p.id)
        print("removed the stored credential for \(p.id)")
    }

    // MARK: - probe

    /// Fetch once and print what came back.
    ///
    /// How an adapter gets written honestly: capture what the API actually returns, save it
    /// as a fixture, then write a parser against it. Guessing a response shape produces
    /// code that looks correct and reports the wrong number.
    private static func probe(id: String?) {
        let p = find(id)
        let secret = (try? credentials.secret(for: p.id)) ?? nil
        if p.credentialSpec.required && secret == nil {
            die("no credential stored — run: tmu provider add \(p.id)")
        }

        let snapshot = runBlocking { await p.snapshot(credentials: credentials, now: Date()) }
        render(snapshot)
    }

    // MARK: - check

    private static func check() {
        let configured = ProviderRegistry.all().filter { p in
            !p.credentialSpec.required || ((try? credentials.secret(for: p.id)) ?? nil) != nil
        }
        guard !configured.isEmpty else {
            return print("no provider credentials stored — see: tmu provider list")
        }
        for p in configured {
            render(runBlocking { await p.snapshot(credentials: credentials, now: Date()) })
        }
        print("")
    }

    // MARK: - Rendering

    private static func render(_ snapshot: UsageSnapshot) {
        let account = snapshot.account.map { " (\($0))" } ?? ""
        print("\n  \(snapshot.provider)\(account)")

        switch snapshot.status {
        case .unauthorized:
            print("    no credential — tmu provider add \(snapshot.provider)")
        case .unavailable(let reason):
            // A failed provider keeps its row. Dropping it would make an outage look
            // identical to never having configured the thing.
            print("    unavailable: \(reason)")
        case .ok where snapshot.metrics.isEmpty:
            print("    reporting, but nothing to show")
        case .ok:
            for m in snapshot.metrics {
                let pct = m.utilization.map { String(format: "%5.1f%%", $0) } ?? "     —"
                let unit = m.unit.map { " \($0)" } ?? ""
                let cap = m.limit.map { " of \(Int($0))" } ?? ""
                print("    \(pct)  \(pad(m.label, 22)) \(fmt(m.value))\(unit)\(cap)")
            }
        }
    }

    private static func fmt(_ v: Double) -> String {
        v == v.rounded() && abs(v) < 1e9
            ? String(Int(v)) : String(format: "%.2f", v)
    }

    /// The CLI is synchronous; the provider API is async. One bridge, in one place.
    private static func runBlocking<T: Sendable>(
        _ work: @escaping @Sendable () async -> T
    ) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = Box<T>()
        Task {
            box.value = await work()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    private final class Box<T>: @unchecked Sendable { var value: T? }
}
