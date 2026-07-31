import SwiftUI
import TMUTelemetry
import TMUWidgets
import WidgetKit

// Not named main.swift, deliberately: `@main` and a file called main.swift are top-level-code
// conflicts, and the compiler error names neither cause.
//
// This file is the whole extension. Everything with a decision in it lives in TMUWidgets,
// where the CLI and the tests can reach it — an extension is a difficult place to debug and a
// worse one to test, so the only things here are the ones that genuinely need WidgetKit.

struct UsageEntry: TimelineEntry {
    let date: Date
    let model: WidgetViewModel
}

struct UsageProvider: TimelineProvider {

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), model: .placeholder(family: family(for: context)))
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(read(for: context, at: Date()).first ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entries = read(for: context, at: Date())
        // .never, because nothing this process can compute will be newer. Fresh content
        // arrives when the app publishes and reloads us; the staleness transition is already
        // in `entries`. Asking to be woken on a timer would spend a budget of roughly 40-70
        // reloads a day to re-read a file that has not changed.
        completion(Timeline(entries: entries, policy: .never))
    }

    /// The container, read once, turned into every entry the widget needs.
    private func read(for context: Context, at now: Date) -> [UsageEntry] {
        let family = family(for: context)
        guard let url = SharedContainer.modelURL(),
            let data = try? Data(contentsOf: url),
            let model = try? JSONDecoder().decode(TelemetryModel.self, from: data)
        else {
            // No container, or nothing published yet. Says so rather than drawing an empty
            // panel, which reads as a broken app.
            return [UsageEntry(date: now, model: .placeholder(family: family))]
        }

        return UsageTimeline.entries(from: model, family: family, now: now)
            .map { UsageEntry(date: $0.date, model: $0.model) }
    }

    private func family(for context: Context) -> WidgetFamilyID {
        switch context.family {
        case .systemSmall: return .small
        case .systemLarge: return .large
        default: return .medium
        }
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: SharedContainer.widgetKind, provider: UsageProvider()) { entry in
            UsageWidgetView(entry.model)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("How much of each provider's limit you have used.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main struct TMUWidgetBundle: WidgetBundle {
    var body: some Widget { UsageWidget() }
}
