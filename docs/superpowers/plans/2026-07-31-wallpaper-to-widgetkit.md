# Wallpaper → WidgetKit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`)
> syntax for tracking.

**Goal:** Replace the desktop-wallpaper usage gauge with WidgetKit desktop widgets, removing
the wallpaper stack from the codebase and from machines that already have it.

**Architecture:** The menu bar app writes a `TelemetryModel` to an App Group container on its
existing 300s poll and calls `WidgetCenter.reloadTimelines`. A sandboxed widget extension reads
that file and nothing else. A pure `WidgetViewModel` sits between the model and SwiftUI so the
golden tests stay text diffs.

**Tech Stack:** Swift 6.3, SwiftUI, WidgetKit, SPM (no Xcode project), hand-assembled bundles.

**Spec:** `docs/superpowers/specs/2026-07-31-wallpaper-to-widgetkit-design.md`

## Global Constraints

Every one of these was verified empirically on 2026-07-31 against Swift 6.3.3 / macOS 26.5 /
Xcode 26.6. They are facts, not assumptions.

- **Platform floor is `.macOS(.v14)`** in `Package.swift`; `LSMinimumSystemVersion` is `14.0`.
- **`@main WidgetBundle` must NOT live in a file named `main.swift`** — top-level-code conflict.
  Use `WidgetBundle.swift`.
- **`.appex` `Info.plist` requires all of:** `CFBundlePackageType=XPC!`,
  `CFBundleInfoDictionaryVersion=6.0`, `CFBundleSupportedPlatforms=[MacOSX]`, and
  `NSExtension.NSExtensionPointIdentifier=com.apple.widgetkit-extension`. Omitting either of
  the middle two registers nothing, with no error anywhere.
- **Extension entitlements:** `com.apple.security.app-sandbox` **and**
  `com.apple.security.application-groups`. Works with an Apple Development certificate and
  **no provisioning profile**.
- **Host app entitlements:** `com.apple.security.application-groups` **only**. The app must
  stay **unsandboxed** — sandboxing it would break `/Applications` instance discovery and the
  keychain. An unsandboxed process shares the group container fine.
- **A bare Mach-O executable cannot be sandboxed** — the kernel SIGTRAPs it. Sandbox
  entitlements only work inside a bundle. Failures look like entitlement problems and are not.
- **Sign inside-out:** `.appex` first, then the host app.
- **Registration requires a LaunchServices-scanned location** (`/Applications` or
  `~/Applications`). From `/tmp` it silently fails. `lsregister -f` then `pluginkit -a`.
- **App Group ID:** `<TeamID>.com.trackmyusage.shared`. Team ID is **never committed** — it
  comes from `$TEAM_ID` or the signing identity's OU, and is written into both `Info.plist`
  files under `TMUAppGroupIdentifier`.
- **Extension bundle ID:** `com.trackmyusage.app.widgets` (must be prefixed by the host's).
- **`TMUWidgets` must not depend on `TMUKit` or `TMUProviders`** — the extension has no
  business reaching the keychain, the network, or `/Applications`.
- **Frozen names still apply.** `scripts/check-frozen-names.sh` runs in CI; the
  `com.claudruple.wallpaper` label in migration code is an allowed form and must stay.
- **The gate must pass at every commit:**
  `swift build && swift test && swift build -c release && swift format lint --strict --recursive Sources Tests`

---

## File Structure

**Created**

| Path | Responsibility |
|---|---|
| `Sources/TMUWidgets/WidgetViewModel.swift` | pure `TelemetryModel` → drawable strings |
| `Sources/TMUWidgets/UsageWidgetView.swift` | family-dispatching root view |
| `Sources/TMUWidgets/Views/SmallView.swift` | `systemSmall` layout |
| `Sources/TMUWidgets/Views/MediumView.swift` | `systemMedium` layout |
| `Sources/TMUWidgets/Views/LargeView.swift` | `systemLarge` layout |
| `Sources/TMUWidgets/SharedContainer.swift` | group-container URL + atomic read/write |
| `Sources/TMUWidgetExtension/WidgetBundle.swift` | `@main`, `StaticConfiguration`, provider |
| `scripts/build-widget.sh` | assemble + sign the `.appex` |
| `scripts/check-widget.sh` | structural gate |
| `Tests/TMUWidgetsTests/WidgetViewModelTests.swift` | goldens |
| `Tests/TMUWidgetsTests/SharedContainerTests.swift` | round-trip + staleness |

**Modified**

| Path | Change |
|---|---|
| `Package.swift` | v14 floor; add 2 targets + test target; drop 3 targets |
| `scripts/build-app.sh` | Team ID derivation, entitlements, embed `.appex`, inside-out sign |
| `Sources/TMUAppCore/TelemetryStore.swift` | write container + `reloadTimelines` |
| `Sources/TMUKit/Migration/*` | `wallpaperTeardown` step |
| `Sources/TMUKit/Diagnostics.swift` | widget check replaces agent check |
| `Sources/tmu/Doctor.swift` | feed the widget check |
| `Sources/tmu/Assets.swift` | `assets widget` / `widget-model` |
| `scripts/generate-web.sh`, `scripts/check-generated.sh` | new artifacts |
| `.github/workflows/ci.yml` | widget gate step |
| `CLAUDE.md`, `README.md`, `docs/roadmap.md`, `web/*.html` | prose |

**Deleted:** `Sources/TMUDesktop/`, `Sources/TMURender/`, `Sources/tmud/`,
`Tests/TMUDesktopTests/`, `Tests/TMURenderTests/`, `scripts/{install,uninstall}-wallpaper-agent.sh`,
`web/wallpaper-*.svg`.

**Rehomed before deletion:** `InstanceIcon.swift` → `TMUKit`; `DemoSnapshots.swift` →
`TMUTelemetry`.

---

## Task 1: Walking skeleton — prove the bundle in-repo

Nothing is deleted in this task. If it fails, the wallpaper is still intact.

**Files:**
- Create: `Sources/TMUWidgets/SharedContainer.swift`, `Sources/TMUWidgetExtension/WidgetBundle.swift`,
  `scripts/build-widget.sh`, `scripts/check-widget.sh`
- Modify: `Package.swift`, `scripts/build-app.sh`

**Interfaces produced:**
- `SharedContainer.groupIdentifier() -> String?` — from `TMUAppGroupIdentifier`
- `SharedContainer.url() -> URL?` — container dir
- `SharedContainer.modelURL() -> URL?` — `telemetry.json` inside it

- [ ] **Step 1: Bump the platform floor and add targets in `Package.swift`**

`.macOS(.v13)` → `.macOS(.v14)`. Add:

```swift
.library(name: "TMUWidgets", targets: ["TMUWidgets"]),
.executable(name: "TMUWidgetExtension", targets: ["TMUWidgetExtension"]),
```

```swift
// The widget's views and its view model. A library rather than code inside the extension
// because three consumers import it: the extension, `tmu assets` for the website images,
// and the tests. Views inside the executable would put the website's real source out of
// the CLI's reach.
//
// Deliberately no TMUKit or TMUProviders: the extension is sandboxed and has no business
// reaching the keychain, the network or /Applications.
.target(name: "TMUWidgets", dependencies: ["TMUTelemetry", "TMUDesign"]),
.executableTarget(name: "TMUWidgetExtension", dependencies: ["TMUWidgets"]),
```

- [ ] **Step 2: Write `SharedContainer.swift`**

```swift
import Foundation

/// The one path the app and the widget agree on.
///
/// The identifier is read from Info.plist rather than compiled in because it contains the
/// signing team's ID, which differs per developer and must not be committed. `build-app.sh`
/// writes it into both bundles at assembly time.
public enum SharedContainer {
    public static let infoKey = "TMUAppGroupIdentifier"
    public static let modelFilename = "telemetry.json"

    public static func groupIdentifier(bundle: Bundle = .main) -> String? {
        bundle.object(forInfoDictionaryKey: infoKey) as? String
    }

    public static func url(bundle: Bundle = .main) -> URL? {
        guard let group = groupIdentifier(bundle: bundle) else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    }

    public static func modelURL(bundle: Bundle = .main) -> URL? {
        url(bundle: bundle)?.appendingPathComponent(modelFilename)
    }
}
```

- [ ] **Step 3: Write the skeleton `WidgetBundle.swift`**

The file must not be named `main.swift` — `@main` and top-level code cannot coexist.

```swift
import SwiftUI
import TMUWidgets
import WidgetKit

struct SkeletonEntry: TimelineEntry { let date: Date; let text: String }

struct SkeletonProvider: TimelineProvider {
    func placeholder(in context: Context) -> SkeletonEntry {
        SkeletonEntry(date: .now, text: "—")
    }
    func getSnapshot(in context: Context, completion: @escaping (SkeletonEntry) -> Void) {
        completion(placeholder(in: context))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<SkeletonEntry>) -> Void) {
        let path = SharedContainer.url()?.lastPathComponent ?? "no container"
        completion(Timeline(entries: [SkeletonEntry(date: .now, text: path)], policy: .never))
    }
}

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "usage", provider: SkeletonProvider()) { entry in
            Text(entry.text).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage")
        .description("Your provider usage at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

@main struct TMUWidgetBundle: WidgetBundle {
    var body: some Widget { UsageWidget() }
}
```

- [ ] **Step 4: Write `scripts/build-widget.sh`**

Derives the Team ID, writes both `Info.plist` files, signs the `.appex`. Every non-obvious
key carries a comment naming the failure it prevents (see Global Constraints).

- [ ] **Step 5: Extend `build-app.sh` to embed and sign inside-out**

App entitlements are `application-groups` only — **not** `app-sandbox`. Sign `.appex` first.
Ad-hoc (`IDENTITY=-`) must still produce a working app with the widget simply absent.

- [ ] **Step 6: Write `scripts/check-widget.sh`**

All checks pass under ad-hoc signing so CI runs them: appex present; the four required plist
keys; bundle-ID prefix; entitlements contain sandbox + group; `codesign --verify --deep
--strict`; extension links WidgetKit.

- [ ] **Step 7: Build, install, verify registration**

```bash
swift build && ./scripts/build-app.sh && ./scripts/check-widget.sh
```
Expected: `check-widget.sh` reports all checks pass.

- [ ] **Step 8: Commit**

```bash
git add -A && git commit -m "Widgets: a bundle the system will load"
```

---

## Task 2: `WidgetViewModel` — the text artifact

**Files:** Create `Sources/TMUWidgets/WidgetViewModel.swift`,
`Tests/TMUWidgetsTests/WidgetViewModelTests.swift`. Modify `Package.swift`.

**Interfaces produced:**
- `WidgetViewModel.make(from: TelemetryModel, family: WidgetFamilyID, at: Date) -> WidgetViewModel`
- `enum WidgetFamilyID: String, CaseIterable { case small, medium, large }`

- [ ] **Step 1: Write failing golden tests**

Test names are full sentences, each with a comment naming the failure it prevents — the
existing suite's convention.

- [ ] **Step 2: Run, verify failure** — `swift test --filter WidgetViewModelTests`

- [ ] **Step 3: Implement**

`Codable`, `Equatable`, `Sendable`. Holds every string, number and state the widget draws,
already formatted via `TMUTelemetry.Format` and classified via `TMUDesign`. Carries
`isStale`, computed from `generatedAt` vs the render date using the existing `Freshness` rule
— this is what makes the precomputed stale timeline entry possible.

**No formatting, threshold comparison or date arithmetic may live in a SwiftUI view.**

- [ ] **Step 4: Run tests, verify pass**

- [ ] **Step 5: Commit** — `git commit -m "Widgets: the model the views are allowed to draw"`

---

## Task 3: SwiftUI views for the three families

**Files:** Create `Sources/TMUWidgets/UsageWidgetView.swift`, `Views/{Small,Medium,Large}View.swift`.

- [ ] **Step 1: Write the views** — layout only, consuming `WidgetViewModel`.
  `containerBackground(for: .widget)` is required on macOS 14+ or the widget renders unpadded.
- [ ] **Step 2: Snapshot smoke test** — render each family via `ImageRenderer`, assert non-nil
  and correct pixel dimensions. Catches a view that crashes or collapses to zero size.
- [ ] **Step 3: Run tests** — `swift test --filter TMUWidgetsTests`
- [ ] **Step 4: Commit** — `git commit -m "Widgets: three families, one model"`

---

## Task 4: The app writes the container

**Files:** Modify `Sources/TMUAppCore/TelemetryStore.swift`; add
`Sources/TMUAppCore/WidgetPublisher.swift`; test in `Tests/TMUAppCoreTests/`.

- [ ] **Step 1: Failing test** — publishing writes decodable JSON; a write with no container
  configured is a no-op, not a crash (the ad-hoc build case).
- [ ] **Step 2: Run, verify failure**
- [ ] **Step 3: Implement `WidgetPublisher`** — atomic write (matching `SnapshotCache.save`),
  then `WidgetCenter.shared.reloadTimelines(ofKind: "usage")`. Called from `refreshProviders`.
- [ ] **Step 4: Run tests**
- [ ] **Step 5: Commit** — `git commit -m "App: publish telemetry where the widget can see it"`

---

## Task 5: Real timeline — ageing precomputed

**Files:** Modify `Sources/TMUWidgetExtension/WidgetBundle.swift`; add
`Sources/TMUWidgets/UsageTimeline.swift`; test in `Tests/TMUWidgetsTests/`.

- [ ] **Step 1: Failing test**

```
testATimelineCarriesAStaleEntrySoAFrozenWidgetStopsClaimingToBeCurrent()
```
One container read must produce ≥2 entries: fresh now, stale at the `Freshness` boundary.
A single `.never` entry would leave a frozen widget presenting old numbers as current.

- [ ] **Step 2: Run, verify failure**
- [ ] **Step 3: Implement `UsageTimeline.entries(from:family:now:) -> [UsageEntry]`** — pure,
  testable without WidgetKit. The provider is a thin adapter over it.
- [ ] **Step 4: Run tests**
- [ ] **Step 5: Rebuild bundle, verify on the desktop** — `./scripts/build-app.sh` and place
  the widget.
- [ ] **Step 6: Commit** — `git commit -m "Widgets: a number that admits when it went stale"`

---

## Task 6: Teardown on upgrade — before anything is deleted

This runs before the wallpaper code is removed so no commit strands an upgrading user.

**Files:** Modify `Sources/TMUKit/Migration/{MigrationPlan,MigrationRunner,LegacyPaths}.swift`;
test in `Tests/TMUKitTests/MigrationTests.swift`.

- [ ] **Step 1: Failing tests** — the step boots out **both** `com.claudruple.wallpaper` and
  `com.trackmyusage.wallpaper`; restores from `original-wallpaper.txt` when the file still
  exists; is idempotent; reports `.skipped` with a reason when there is nothing to do.
- [ ] **Step 2: Run, verify failure**
- [ ] **Step 3: Implement `MigrationStep.wallpaperTeardown`**

Moves the minimum `NSWorkspace.setDesktopImageURL` call into the runner as the last user of
it, with a comment stating it exists solely to undo something this project did. Replaces
`.wallpaperState`, whose scrubbing is subsumed.

- [ ] **Step 4: Run tests** — `swift test --filter Migration`
- [ ] **Step 5: Commit** — `git commit -m "Migration: a way back off the wallpaper"`

---

## Task 7: Diagnostics

**Files:** Modify `Sources/TMUKit/Diagnostics.swift`, `Sources/tmu/Doctor.swift`;
`Tests/TMUKitTests/DiagnosticsTests.swift`.

- [ ] **Step 1: Failing tests** — four distinguishable outcomes per spec §9. The ad-hoc case
  must **not** report as damaged; it is a supported build.
- [ ] **Step 2: Run, verify failure**
- [ ] **Step 3: Implement** — replace `wallpaperAgentLoaded` with
  `widget: WidgetInstallState { ok, frozen, unsignedBuild, missing }`.
- [ ] **Step 4: Run tests**
- [ ] **Step 5: Commit** — `git commit -m "Doctor: ask the widget whether it is working"`

---

## Task 8: Assets CLI and the generated-file guarantee

**Files:** Modify `Sources/tmu/Assets.swift`, `scripts/generate-web.sh`,
`scripts/check-generated.sh`. Rehome `DemoSnapshots.swift` → `TMUTelemetry`.

- [ ] **Step 1: Move `DemoSnapshots` into `TMUTelemetry`** and make tests pass again.
- [ ] **Step 2: Add `tmu assets widget <family> <case>` (PNG) and `widget-model <family> <case>` (JSON)**;
  remove `assets wallpaper`; repoint `assets social` at `systemMedium` centred on 1200×630.
- [ ] **Step 3: Update `generate-web.sh`** to emit `web/widgets.json` and
  `web/widget-{small,medium,large}-*.png`; delete `web/wallpaper-*.svg`.
- [ ] **Step 4: Update `check-generated.sh`** — exclude the new PNGs alongside `og.png`, and
  **rewrite the comment** so it cites `widgets.json` as the text proxy that keeps the rasters
  safe. The comment is the reason the exclusion is defensible; leaving it citing deleted SVGs
  would make the check look unjustified.
- [ ] **Step 5: Run `./scripts/generate-web.sh && ./scripts/check-generated.sh`**
- [ ] **Step 6: Commit** — `git commit -m "Assets: the site's images come from the widget"`

---

## Task 9: Delete the wallpaper stack

Only now, with the replacement working and the teardown shipped.

- [ ] **Step 1: Rehome `InstanceIcon.swift` → `TMUKit`**; verify `tmu assets instance-icon`.
- [ ] **Step 2: Delete** `Sources/{TMUDesktop,TMURender,tmud}`, `Tests/{TMUDesktopTests,TMURenderTests}`,
  `scripts/{install,uninstall}-wallpaper-agent.sh`, `web/wallpaper-*.svg`.
- [ ] **Step 3: Drop the targets from `Package.swift`.**
- [ ] **Step 4: Run the full gate** — expect compile errors only where prose or dead references remain.
- [ ] **Step 5: Commit** — `git commit -m "Wallpaper: remove the feature the widget replaces"`

---

## Task 10: Prose sweep

Per spec §11. These comments are load-bearing documentation in this codebase; this is not a
`sed` pass.

- [ ] **Step 1: Repoint dangling `WallpaperState.load` citations** — `Settings.swift:119`,
  `RenderHistory.swift:53`, `MigrationReceipt.swift:7` → `SnapshotCache.load`.
- [ ] **Step 2: Rewrite `Ink.swift:71`** — raw values stay load-bearing; the reason becomes
  `widgets.json`, not SVG CSS classes. Rewrite, don't delete.
- [ ] **Step 3: Reword comment-only mentions** in `Freshness`, `Format`, `TelemetryModel`,
  `UsageProvider`, `ClaudeUsage`, `InstanceFreshness`, `Steering`, `Sources`, `TelemetryStore`.
- [ ] **Step 4: `CLAUDE.md`** — layout table; delete the SVG-presentation-attributes invariant;
  rewrite the purity invariant to cite `WidgetViewModel`; add an invariant for the widget's
  read-only boundary; update the gate block.
- [ ] **Step 5: `README.md`, `docs/roadmap.md`, `web/index.html`, `web/pricing.html`.**
- [ ] **Step 6: Verify no dangling references** — `grep -ri wallpaper Sources Tests` should
  return only migration-teardown hits.
- [ ] **Step 7: Commit** — `git commit -m "Docs: the wallpaper is gone, and says so"`

---

## Task 11: Gate and CI

- [ ] **Step 1: Add the widget step to `.github/workflows/ci.yml`** after the release build.
- [ ] **Step 2: Extend `scripts/test-scripts.sh`** with Team-ID derivation and plist-injection
  coverage, matching how it already covers instance identity.
- [ ] **Step 3: Run the whole gate.**
- [ ] **Step 4: Commit and open a draft PR.**

---

## Self-Review

**Spec coverage:** §1 → T1S1. §2 → T1, T9. §3 → T3. §4 → T4, T5. §5 → T1S4–6. §6 → T2.
§7 → T8. §8 → T6. §9 → T7. §10 → T11. §11 → T10. §12 → task order (T1 skeleton first,
T6 teardown before T9 deletion). §13 out of scope, untouched.

**Placeholders:** none — every step names files, commands and the failure it prevents.

**Type consistency:** `WidgetViewModel.make(from:family:at:)`, `WidgetFamilyID`,
`SharedContainer.{groupIdentifier,url,modelURL}`, `UsageTimeline.entries(from:family:now:)`,
`WidgetInstallState` are each defined once and referenced consistently. Widget kind is
`"usage"` in T1, T4 and T5.
