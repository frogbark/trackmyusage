import Foundation

/// The one path the app writes and the widget reads.
///
/// The widget extension is sandboxed — that is not a choice, macOS requires it of widget
/// extensions — so it cannot read the caches directory the app keeps its snapshots in. An App
/// Group container is the only shared filesystem the two are permitted, which is why this
/// exists rather than a path constant somewhere.
///
/// The identifier is read from Info.plist rather than compiled in because it must contain the
/// signing team's ID, which differs per developer and has no business in a public repository.
/// `build-app.sh` derives it and writes it into both bundles at assembly time, so a
/// contributor with a different team builds a working app without editing a source file.
///
/// Every accessor returns nil rather than throwing when the key or the container is absent.
/// That is the ad-hoc build: `IDENTITY=-` cannot carry an App Group entitlement, so the app
/// still runs and the widget is simply not there. It is a supported configuration and must
/// not read as a failure — see `Diagnostics`, which distinguishes it from a broken install.
public enum SharedContainer {

    /// Info.plist key holding the App Group identifier, written at bundle-assembly time.
    public static let infoKey = "TMUAppGroupIdentifier"

    /// The published telemetry, inside the container.
    public static let modelFilename = "telemetry.json"

    /// The widget kind, shared so the publisher and the extension cannot drift apart. A
    /// mismatch here reloads nothing and reports no error.
    public static let widgetKind = "usage"

    public static func groupIdentifier(bundle: Bundle = .main) -> String? {
        guard let value = bundle.object(forInfoDictionaryKey: infoKey) as? String,
            !value.isEmpty
        else { return nil }
        return value
    }

    /// The container directory, or nil when this build has no App Group.
    public static func url(bundle: Bundle = .main) -> URL? {
        guard let group = groupIdentifier(bundle: bundle) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    public static func modelURL(bundle: Bundle = .main) -> URL? {
        url(bundle: bundle)?.appendingPathComponent(modelFilename)
    }
}
