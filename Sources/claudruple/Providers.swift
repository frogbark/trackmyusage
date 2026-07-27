import ClaudrupleKit
import ClaudrupleUsage
import Foundation

/// `claudruple provider …`
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

    private static func store() -> KeychainCredentialStore { KeychainCredentialStore() }

    // MARK: - list

    private static func list() {
        let s = store()
        print("\n  provider      credential   reports")
        for p in ProviderRegistry.all {
            let has = ((try? s.get(p.credentialSpec.keychainService)) ?? nil) != nil
            print("  \(pad(p.id, 13)) \(pad(has ? "stored" : "—", 12)) "
                + p.capabilities.summary)
        }
        print("""

          Not yet implemented: \(ProviderRegistry.pending.joined(separator: ", ")).
          Each needs its real response captured first — see `provider probe`.

        """)
    }

    // MARK: - add / remove

    private static func add(id: String?) {
        guard let id, let p = ProviderRegistry.adapter(id: id) else {
            die("usage: claudruple provider add <id>")
        }
        let spec = p.credentialSpec
        print("\n  \(p.displayName)")
        print("  create a key: \(spec.createURL)")
        print("  minimum scope: \(spec.minimumScope)")
        if let w = spec.scopeWarning { print("  note: \(w)") }
        print("\n  paste the key (input is not echoed to history):")

        // Read from stdin rather than a flag: an argument lands in shell history and in the
        // process list, where any other user on the machine can read it.
        guard let key = readLine(strippingNewline: true), !key.isEmpty else {
            die("no key entered")
        }
        var s = store()
        do {
            try s.set(key, for: spec.keychainService)
            print("  stored in keychain as \(spec.keychainService)\n")
        } catch {
            die("\(error)")
        }
    }

    private static func remove(id: String?) {
        guard let id, let p = ProviderRegistry.adapter(id: id) else {
            die("usage: claudruple provider remove <id>")
        }
        var s = store()
        try? s.delete(p.credentialSpec.keychainService)
        print("removed \(p.credentialSpec.keychainService)")
    }

    // MARK: - probe

    /// Fetch once and print the raw body.
    ///
    /// This is how an adapter gets written honestly: capture what the API actually returns,
    /// save it as a fixture, then write a parser against it. Guessing a response shape
    /// produces code that looks correct and reports the wrong number.
    private static func probe(id: String?) {
        guard let id, let p = ProviderRegistry.adapter(id: id) else {
            die("usage: claudruple provider probe <id>")
        }
        guard let key = ((try? store().get(p.credentialSpec.keychainService)) ?? nil) else {
            die("no credential stored — run: claudruple provider add \(id)")
        }
        guard let request = try? p.request(credential: key) else {
            die("could not build request")
        }

        let sema = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sema.signal() }
            if let error { return print("  request failed: \(error.localizedDescription)") }
            if let http = response as? HTTPURLResponse { print("  HTTP \(http.statusCode)") }
            guard let data else { return print("  empty body") }
            print(String(data: data, encoding: .utf8) ?? "  <\(data.count) bytes, not UTF-8>")
        }.resume()
        _ = sema.wait(timeout: .now() + 30)
    }

    // MARK: - check

    private static func check() {
        let s = store()
        var any = false

        for p in ProviderRegistry.all {
            guard let key = ((try? s.get(p.credentialSpec.keychainService)) ?? nil) else { continue }
            any = true
            guard let request = try? p.request(credential: key) else { continue }

            let sema = DispatchSemaphore(value: 0)
            URLSession.shared.dataTask(with: request) { data, _, error in
                defer { sema.signal() }
                if let error { return print("  \(p.id): \(error.localizedDescription)") }
                guard let data else { return print("  \(p.id): empty response") }
                do {
                    let snap = try p.parse(data, now: Date())
                    print("\n  \(p.displayName)\(snap.accountLabel.map { " (\($0))" } ?? "")")
                    for m in snap.metrics {
                        let pct = m.utilization.map { String(format: "%5.1f%%", $0) } ?? "     —"
                        print("    \(pct)  \(m.label): \(m.formattedValue)"
                            + (m.limit.map { " of \(Int($0))" } ?? ""))
                    }
                } catch {
                    print("  \(p.id): \(error)")
                }
            }.resume()
            _ = sema.wait(timeout: .now() + 30)
        }
        if !any { print("no provider credentials stored — see: claudruple provider list") }
        print("")
    }
}
