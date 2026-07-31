import Foundation
import TMUTelemetry
import TMUWidgets
import WidgetKit

/// Puts the current model where the widget can read it, and tells the widget to look.
///
/// The widget extension is sandboxed and cannot reach the caches directory this app keeps its
/// snapshots in, so the App Group container is the only channel between them. It is also a
/// one-way channel by design: the app writes, the extension reads, and the extension never
/// gets the network, the keychain, or a reason to want them.
///
/// This is also the widget's entire refresh mechanism. WidgetKit budgets a placed widget to
/// roughly 40–70 system-initiated reloads a day, so a timeline asking to wake every 300s
/// would be throttled to something unpredictable and mostly wrong. The app already polls on a
/// timer; it is the only thing that knows when the content actually changed, so it is the
/// thing that says so.
public struct WidgetPublisher: Sendable {

    private let url: URL?
    private let reload: @Sendable () -> Void

    /// `url` is nil on a build with no App Group — an ad-hoc signature cannot carry the
    /// entitlement. Publishing then does nothing at all, which is correct: there is no widget
    /// to publish to, and the app is otherwise complete.
    public init(
        url: URL? = SharedContainer.modelURL(),
        reload: (@Sendable () -> Void)? = nil
    ) {
        self.url = url
        self.reload =
            reload ?? { WidgetCenter.shared.reloadTimelines(ofKind: SharedContainer.widgetKind) }
    }

    /// Writes the model and reloads the widget, unless nothing changed.
    ///
    /// Returns whether it published, which is what makes the no-op testable.
    ///
    /// Skipping an unchanged write matters more than it looks: `rebuild()` runs on the 30s
    /// instance cadence as well as the 300s provider one, so most calls carry the same bytes
    /// as the last. Waking the extension to redraw an identical widget spends its budget and
    /// the user's battery to change nothing.
    @discardableResult
    public func publish(_ model: TelemetryModel) -> Bool {
        guard let url else { return false }
        guard let data = try? CanonicalJSON.encode(model) else { return false }

        // Byte comparison is only meaningful because CanonicalJSON sorts keys — a plain
        // JSONEncoder emits the same value in a different order each call, and this check
        // would never once find a match.
        if let existing = try? Data(contentsOf: url), existing == data { return false }

        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic, matching SnapshotCache.save. A widget reading mid-write must see the
            // previous complete file rather than a truncated one — it has no way to ask again
            // and would render an error state over good data.
            try data.write(to: url, options: .atomic)
        } catch {
            // A failed publish is a stale widget, which already says it is stale. Refusing to
            // continue the poll over it would trade a marked number for no number.
            return false
        }

        reload()
        return true
    }
}
