import AppKit
import SwiftUI
import TMUDesign
import TMUProviders

/// One place to connect every metered service.
///
/// The screen exists because the alternative was `tmu provider add <id>` per provider, and
/// a stack you are trying to see the cost of is exactly the stack you have too many keys
/// for to enjoy doing that.
///
/// Every field `CredentialSpec` carries is shown at the moment of pasting rather than in
/// documentation — the scope to ask for, what a broader token would allow, and a link
/// straight to the page that mints one. The spec's own comment asks for this: a trade-off is
/// only a real choice if the cost of the easy option is visible while you are choosing.
public struct ProvidersWindow: View {

    @StateObject private var store = ProviderKeysStore()
    /// Which row has its editor open. One at a time, so a pasted token cannot land in a
    /// field the user is no longer looking at.
    @State private var editing: String?

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header

                    if let error = store.lastError {
                        ErrorBanner(text: error) { store.dismissError() }
                    }

                    Group3(
                        title: "Reporting",
                        caption: "Usage is being read for these now.",
                        rows: store.rows.filter { $0.group == .reporting },
                        editing: $editing, store: store)

                    Group3(
                        title: "Ready to connect",
                        caption: "An adapter exists. Each takes a read-only key — some "
                            + "report a little without one.",
                        rows: store.rows.filter { $0.group == .connectable },
                        editing: $editing, store: store)

                    Group3(
                        title: "Not available yet",
                        caption:
                            "Absent rather than stubbed — a parser written from a remembered "
                            + "API shape reports the wrong number rather than failing.",
                        rows: store.rows.filter { $0.group == .unavailable },
                        editing: $editing, store: store)
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(minWidth: 620, minHeight: 480)
        .onAppear { store.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Providers").font(.system(size: 20, weight: .semibold))
            Text(
                "Keys are written to your login keychain and never leave this Mac. "
                    + "Nothing is uploaded, and the daemon never phones home with your usage."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").font(.system(size: 10))
            // Specific rather than reassuring. "Securely stored" tells someone nothing they
            // can check; the accessibility class and the iCloud answer are facts they can.
            Text(
                "Login keychain, this device only — never synced to iCloud. "
                    + "Requests are GET-only: the HTTP client has no other verb."
            )
            .font(.system(size: 10))
            Spacer()
            Button("Reload") { store.reload() }.controlSize(.small)
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

// MARK: - Groups

private struct Group3: View {
    let title: String
    let caption: String
    let rows: [ProviderKeyRow]
    @Binding var editing: String?
    let store: ProviderKeysStore

    var body: some View {
        // An empty group is omitted entirely rather than shown with a "none" placeholder:
        // once everything is connected, "Ready to connect (0)" is a heading that only ever
        // states an absence.
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title.uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(.secondary)
                    Text(caption)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(rows) { row in
                    ProviderKeyCard(row: row, editing: $editing, store: store)
                }
            }
        }
    }
}

private struct ProviderKeyCard: View {
    let row: ProviderKeyRow
    @Binding var editing: String?
    let store: ProviderKeysStore

    /// The pasted token, for as long as it takes to save it.
    ///
    /// Cleared the instant it reaches the keychain, and again whenever the editor closes.
    /// SwiftUI keeps this string alive for the lifetime of the view otherwise, which for a
    /// window someone leaves open is the rest of the session.
    @State private var entry: String = ""

    private var isEditing: Bool { editing == row.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(dotInk))
                    .frame(width: 7, height: 7)
                Text(row.id)
                    .font(.system(size: 13, design: .monospaced))
                Spacer()
                trailing
            }

            if case .blocked(let reason) = row.availability {
                Text(reason).font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            if isEditing { editor }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(.white.opacity(isEditing ? 0.16 : 0.07), lineWidth: 1)))
    }

    private var dotInk: Hex {
        if row.isConnected { return Ink.ok }
        switch row.availability {
        case .blocked: return Ink.warn
        // An optional-credential provider already reports something without a key, so it is
        // not drawn as inert — it is working, just at the anonymous ceiling.
        case .built: return row.credential == .required ? Ink.muted : Ink.ok
        case .planned: return Ink.absent
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if row.isConnected {
            HStack(spacing: 8) {
                Text("connected").font(.system(size: 11)).foregroundStyle(.secondary)
                Button(isEditing ? "Cancel" : "Replace") { toggle() }.controlSize(.small)
                Button("Remove") { store.disconnect(row.id) }.controlSize(.small)
            }
        } else if row.isActionable {
            HStack(spacing: 8) {
                if row.credential == .optional {
                    // Said plainly, because it changes whether pasting a token is worth the
                    // trouble: without one this provider still reports, just less.
                    Text("optional — unlocks more")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                Button(isEditing ? "Cancel" : "Connect…") { toggle() }.controlSize(.small)
            }
        } else if case .built = row.availability, row.credential == .none {
            Text("local — no key needed").font(.system(size: 11)).foregroundStyle(.secondary)
        } else if case .planned = row.availability {
            Text("planned").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()

            if let scope = row.readOnlyScope {
                LabelledLine(label: "Scope", value: scope)
            }
            if let instructions = row.instructions {
                Text(instructions)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let warning = row.scopeWarning {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color(Ink.warn))
                    Text(warning)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                // SecureField, so the token is not painted onto the screen of someone who is
                // very likely screen-sharing while setting this up.
                SecureField("Paste the key", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(save)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(entry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if let create = row.createURL, let url = URL(string: create) {
                Link("Create a key ↗", destination: url).font(.system(size: 11))
            }
        }
    }

    private func toggle() {
        // Clearing on both open and close. A token pasted, left unsaved and abandoned would
        // otherwise still be in memory when the row is reopened days later.
        entry = ""
        editing = isEditing ? nil : row.id
    }

    private func save() {
        guard store.connect(entry, to: row.id) else { return }
        entry = ""
        editing = nil
    }
}

// MARK: - Small parts

private struct LabelledLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 46, alignment: .leading)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color(Ink.over))
            Text(text).font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Dismiss", action: dismiss).controlSize(.small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10).fill(Color(Ink.over).opacity(0.12)))
    }
}
