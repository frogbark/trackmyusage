//
//  Claudruple Link — deep-link broker for multiple Claude Desktop instances.
//
//  The problem it solves
//  --------------------
//  Claude Desktop calls setAsDefaultProtocolClient("claude") on every launch. With more
//  than one instance installed, whichever launched most recently owns claude:// — so a
//  sign-in or MCP OAuth callback lands in an arbitrary account. That is the single
//  biggest source of "multi-account is flaky".
//
//  Why not the built-in switch: the app has an authentication.disableDeepLinks setting
//  that makes it release the scheme instead of claiming it. But with that flag on, the
//  URL handler accepts only Login / MagicLink / SSOCallback and DECLINES everything
//  else — including claude://claude.ai/mcp-auth-callback/sdk. It also resolves from a
//  system-wide managed-settings.json, so it cannot be applied per instance. Using it
//  would trade a routing bug for a broken-MCP-auth bug.
//
//  What this does instead
//  ----------------------
//  1. Claims the default-handler role for claude:// and the MSAL scheme, and re-claims
//     it whenever an instance steals it back (instances steal only at launch, so an
//     activation-triggered re-assert is enough — no polling).
//  2. Tracks the most recently activated Claude-family app. Frontmost-at-callback-time
//     is useless here, because by then the browser is frontmost; what matters is which
//     instance the user was in when they started the sign-in.
//  3. Forwards the URL unmodified to that instance.
//
import AppKit

// MARK: - Logging

/// Logs to a file as well as the unified log. The broker runs as a background agent
/// with no UI, so a plain tailable file is the difference between debuggable and not.
enum Log {
    private static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Claudruple", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("link.log")
    }()

    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        NSLog("claudruple-link: %@", message)
        let line = "[\(df.string(from: Date()))] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Configuration

/// Bundle-identifier prefix shared by the stock app and every Claudruple clone.
private let claudeBundlePrefix = "com.anthropic.claudefordesktop"

/// Schemes Claude Desktop claims. Owning both is what stops the tug-of-war.
private let brokeredSchemes = ["claude", "msauth.com.anthropic.claudefordesktop"]

// MARK: - Instance discovery

struct ClaudeInstance {
    let bundleID: String
    let url: URL
    let displayName: String
}

enum InstanceRegistry {
    /// Every installed Claude-family app, found via LaunchServices rather than a
    /// hardcoded path, so instances created later are picked up automatically.
    static func installed() -> [ClaudeInstance] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var found: [ClaudeInstance] = []

        for id in candidateBundleIDs() {
            // Never treat the broker as a destination — that would route to itself
            // and loop. The directory scan below can otherwise surface it.
            guard id != me else { continue }
            guard id.hasPrefix(claudeBundlePrefix), !seen.contains(id) else { continue }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
            else { continue }
            // Electron's XPC helpers (Claude Helper, Helper (GPU), …) share the bundle-ID
            // prefix but are nested inside a parent .app. Only top-level apps are instances.
            guard isTopLevelApp(url) else { continue }
            seen.insert(id)
            found.append(ClaudeInstance(bundleID: id, url: url, displayName: displayName(for: url)))
        }
        return found
    }

    /// A helper lives at `…/Parent.app/Contents/Frameworks/Helper.app`; a real instance
    /// never has `.app/` anywhere in its parent path.
    private static func isTopLevelApp(_ url: URL) -> Bool {
        !url.deletingLastPathComponent().path.contains(".app/")
    }

    private static func candidateBundleIDs() -> [String] {
        // Running apps are authoritative; installed-but-not-running instances are
        // discovered from the standard Claudruple location.
        var ids = NSWorkspace.shared.runningApplications
            .compactMap(\.bundleIdentifier)
            .filter { $0.hasPrefix(claudeBundlePrefix) }

        ids.append(claudeBundlePrefix)  // the stock install

        let dir = URL(fileURLWithPath: "/Applications/Claudruple")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)
        {
            for app in entries where app.pathExtension == "app" {
                if let b = Bundle(url: app), let id = b.bundleIdentifier { ids.append(id) }
            }
        }
        return ids
    }

    private static func displayName(for url: URL) -> String {
        let b = Bundle(url: url)
        return (b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - Routing

final class Router {
    /// The Claude instance the user most recently worked in. Updated on activation,
    /// because at callback time the browser — not Claude — is frontmost.
    private(set) var lastActive: String?

    func noteActivation(of bundleID: String?) {
        guard let id = bundleID, id.hasPrefix(claudeBundlePrefix) else { return }
        lastActive = id
    }

    /// Pick the instance a callback belongs to.
    func target(among instances: [ClaudeInstance]) -> ClaudeInstance? {
        if let id = lastActive, let hit = instances.first(where: { $0.bundleID == id }) {
            return hit
        }
        // Fall back to a running instance before an installed-but-idle one: a callback
        // almost always belongs to a session already in progress.
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        return instances.first { running.contains($0.bundleID) } ?? instances.first
    }

    /// Deliver the URL unchanged. Naming the application explicitly bypasses
    /// default-handler resolution, so this cannot loop back into the broker.
    func deliver(_ url: URL, to instance: ClaudeInstance) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: instance.url, configuration: cfg) {
            _, err in
            if let err {
                Log.write("delivery to \(instance.bundleID) failed: \(err.localizedDescription)")
            } else {
                Log.write(
                    "routed \(url.scheme ?? "?")://\(url.host ?? "") -> \(instance.displayName)")
            }
        }
    }
}

// MARK: - Scheme ownership

enum SchemeOwnership {
    /// Claim the default-handler role for every brokered scheme.
    static func claim() {
        guard let me = Bundle.main.bundleIdentifier else { return }
        for scheme in brokeredSchemes {
            LSSetDefaultHandlerForURLScheme(scheme as CFString, me as CFString)
        }
    }

    /// True when this process holds every brokered scheme.
    static func isOwner() -> Bool {
        guard let me = Bundle.main.bundleIdentifier else { return false }
        return brokeredSchemes.allSatisfy { scheme in
            guard let u = URL(string: "\(scheme)://probe"),
                let app = NSWorkspace.shared.urlForApplication(toOpen: u),
                let id = Bundle(url: app)?.bundleIdentifier
            else { return false }
            return id == me
        }
    }
}

// MARK: - Application

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let router = Router()

    /// An instance claims claude:// during startup, but AppKit reports didLaunch only once
    /// the app is fully up — measured at ~17s after exec for Electron, with the steal landing
    /// somewhere inside that. A single delayed check leaves a window in which the wrong app
    /// owns the scheme, and a callback arriving then is exactly the bug being fixed. So probe
    /// a spread of offsets and stop at the first that finds the role intact. No steady-state
    /// polling: instances only ever steal at launch.
    private static let reassertOffsets: [TimeInterval] = [1, 3, 6, 10, 15, 22, 30]

    private static func reassertBurst(trigger: String) {
        for delay in reassertOffsets {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                guard !SchemeOwnership.isOwner() else { return }
                Log.write("\(trigger) took the scheme (+\(Int(delay))s); reclaiming")
                SchemeOwnership.claim()
            }
        }
    }

    /// Scheme opens can arrive before didFinishLaunching — when LaunchServices starts the
    /// broker *because* a URL needs handling, the Apple Event is already queued. Installing
    /// the handler in `will` rather than `did` is what stops that first callback being lost,
    /// and that first callback is usually the sign-in the user is waiting on.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL))
        Log.write("started; GetURL handler installed")
    }

    @objc private func handleGetURL(
        _ event: NSAppleEventDescriptor,
        withReplyEvent reply: NSAppleEventDescriptor
    ) {
        guard let s = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
            let url = URL(string: s)
        else {
            Log.write("GetURL event carried no usable URL")
            return
        }
        route([url])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        SchemeOwnership.claim()

        let ws = NSWorkspace.shared.notificationCenter

        // Instances claim the scheme only at launch, so re-asserting on launch and
        // activation is sufficient. Polling would be wasted work.
        ws.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            guard
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                let id = app.bundleIdentifier, id.hasPrefix(claudeBundlePrefix)
            else { return }
            Self.reassertBurst(trigger: id)
        }

        ws.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [router] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            router.noteActivation(of: app?.bundleIdentifier)
        }

        // Seed from whatever is already frontmost at startup.
        router.noteActivation(of: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        route(urls)
    }

    private func route(_ urls: [URL]) {
        let instances = InstanceRegistry.installed()
        Log.write(
            "routing \(urls.count) url(s); \(instances.count) instance(s) known: "
                + instances.map(\.displayName).joined(separator: ", "))
        guard let target = router.target(among: instances) else {
            Log.write(
                "no target instance; dropping \(urls.map(\.absoluteString).joined(separator: " "))")
            return
        }
        for url in urls { router.deliver(url, to: target) }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // background agent: no Dock icon, no menu bar
app.run()
