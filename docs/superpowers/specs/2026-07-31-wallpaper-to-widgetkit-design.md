# Replacing the usage wallpaper with WidgetKit

**Date:** 2026-07-31
**Status:** approved design, not yet implemented

## Why

The wallpaper feature composites usage onto the desktop background because, when it was
built, that was the only way to keep a number permanently visible without a window. macOS has
a surface designed for exactly that: WidgetKit desktop widgets, available since macOS 14.

Using the designed-for surface buys things the wallpaper cannot have at any price: placement
and sizing owned by the user, Dynamic Type, dark mode, the accessibility tree, VoiceOver, and
no need to overwrite a system setting that keeps no history. It costs a minimum-OS bump and a
real code-signing requirement.

Note that "Live Activities" do not exist on macOS — they are iOS-only. The macOS analogue of
a wallpaper gauge is a WidgetKit widget placed on the desktop.

## Scope

### Removed

| Path | Notes |
|---|---|
| `Sources/TMUDesktop/` | whole target — `Desktop`, `AppKitDesktop`, `WallpaperState` |
| `Sources/TMURender/` | whole target — see rehoming below |
| `Sources/tmud/` | whole target |
| `scripts/install-wallpaper-agent.sh` | |
| `scripts/uninstall-wallpaper-agent.sh` | superseded by the teardown in §8 |
| `Tests/TMUDesktopTests/`, `Tests/TMURenderTests/` | |
| `web/wallpaper-*.svg` | replaced per §7 |

**Rehomed before `TMURender` is deleted** — these are not wallpaper code and must not be lost:

- `InstanceIcon.swift` → `TMUKit` (used by `tmu assets instance-icon`, which stays).
- `AppKitRasterizer` / `Rasterizer` → deleted; `ImageRenderer` replaces them for `og.png`.
- `DemoSnapshots.swift` → `TMUTelemetry`, since the widget goldens and the website images
  both still need fixtures with a frozen clock.

### Added

| Target | Kind | Contents |
|---|---|---|
| `TMUWidgets` | library | `WidgetViewModel` (pure) + SwiftUI views |
| `TMUWidgetExtension` | executable | `@main` `WidgetBundle`, `TimelineProvider` |
| `Tests/TMUWidgetsTests` | test | view-model goldens, inheriting `TMURenderTests`' role |

| Script | Purpose |
|---|---|
| `scripts/build-widget.sh` | assemble and sign the `.appex` |
| `scripts/check-widget.sh` | structural gate, §10 |

### Untouched

`TMUDesign`, `TMUProviders`, `TMUTelemetry`, `TMUClaude`, `TMULink`. The Linux portability
job builds only `TMUProviders` and `TMUDesign`; `TMUWidgets` imports SwiftUI and is correctly
outside it.

## 1. Platform floor

`Package.swift` moves `.macOS(.v13)` → `.macOS(.v14)`. `LSMinimumSystemVersion` in
`build-app.sh` and `build-link.sh` moves `13.0` → `14.0`.

macOS 14 is the floor for *desktop* widget placement. Notification Center widgets would work
at 11, but desktop placement is the property that makes this a replacement for a wallpaper
rather than a lesser substitute.

## 2. Module layout

`TMUWidgets` is a library, not code inside the extension, because three consumers import it:

1. `TMUWidgetExtension` — renders the placed widget.
2. `tmu assets widget` — generates the website images.
3. `swift test` — golden-tests the view models.

If the views lived inside the extension executable, the CLI could not reach them and the
website would lose its real source, which is the property `generate-web.sh` exists to
protect.

```
TMUWidgets      →  TMUTelemetry, TMUDesign
TMUWidgetExtension → TMUWidgets
```

`TMUWidgets` must not depend on `TMUKit` or `TMUProviders`. The extension is sandboxed and
has no business reaching the keychain, the network, or `/Applications`.

## 3. Widget families

One widget kind, `"usage"`, with three families. Nominal macOS sizes in points:

| Family | Size | Content |
|---|---|---|
| `systemSmall` | 170×170 | the single most-urgent metric, its state colour, `?` if stale |
| `systemMedium` | 364×170 | the account ledger — name, utilisation, window label |
| `systemLarge` | 364×364 | accounts, services, sparklines and the renewal axis |

Per-account configuration via `AppIntentConfiguration` is explicitly **out of scope** for this
change and is the natural follow-up once the data path is proven.

## 4. Data path

```
TelemetryStore (in the menu bar app, 300s poll)
  ├─ builds TelemetryModel                      (unchanged)
  ├─ writes TelemetryModel JSON → App Group container   (new)
  └─ WidgetCenter.shared.reloadTimelines(ofKind: "usage")  (new)

TimelineProvider (in the sandboxed .appex)
  ├─ reads the container JSON  (once)
  ├─ WidgetViewModel.make(from:at:) for each entry date
  └─ [fresh entry now, stale entry at the freshness boundary], policy .never
```

The widget reads a file and nothing else. No network, no keychain, no provider polling.

**The app owns refresh, not the timeline.** WidgetKit budgets placed widgets to roughly 40–70
system-initiated reloads per day; a 300s self-refresh (288/day) would be throttled to nothing
and would make freshness unpredictable. The app already polls on a timer, so it is the only
thing that should decide when the widget's *content* changed. `reloadTimelines` from a running
app is not subject to the same budget.

**Ageing is precomputed, not refreshed.** A single entry with `.never` would be wrong: if the
app quits, the widget keeps displaying the render made while data was fresh, and the `?`
marker never appears — because appearing would require a re-render that never comes. A frozen
number would be presented as current, which is precisely what *absence is stated, never drawn
as zero* forbids.

So one container read produces **several** entries: the reading as of now, and a further entry
dated at the `Freshness` boundary rendering the same numbers already marked stale. WidgetKit
advances between them on its own clock with no reload and no budget spend. The widget does not
need to be told the data got old; it works that out when it is read, and says so on schedule.

`WidgetViewModel.make(from:at:)` takes the render date for exactly this reason — the same
model rendered at two instants is what produces the two entries, and it keeps the staleness
rule a pure function rather than a side effect of when the process happened to wake.

**Container write is atomic** (`.atomic`), matching `SnapshotCache.save`, so a widget reading
mid-write sees the previous complete file rather than a truncated one.

## 5. Signing and the App Group

Widget extensions on macOS are mandatorily sandboxed. The shared container therefore requires
`com.apple.security.application-groups`, which is Team-ID-bound. The current
`IDENTITY="${IDENTITY:--}"` ad-hoc default cannot carry it — `probe-codex.sh` already records
this conclusion for Codex Desktop.

- **Group ID:** `<TeamID>.com.trackmyusage.shared`. macOS requires the Team ID prefix for
  apps outside the Mac App Store, where the Mac App Store form is `group.<name>`.
- **Extension bundle ID:** `com.trackmyusage.app.widgets`. Apple requires an app extension's
  identifier to be prefixed by its host app's.
- **The Team ID is never committed.** `build-app.sh` uses `$TEAM_ID` when set, and otherwise
  derives it from the signing identity's OU field; it writes the result into both
  `Info.plist` files under a custom key,
  `TMUAppGroupIdentifier`. Both sides read it with
  `Bundle.object(forInfoDictionaryKey: "TMUAppGroupIdentifier")`. A contributor with a
  different team builds a working app without editing a source file.
- **Signing is inside-out:** the `.appex` is signed first, then the host app — the same rule
  `sign-clone.sh` already states for nested code.
- **Ad-hoc builds still produce a working menu bar app.** The widget is simply absent. This is
  a supported configuration, not a broken one, and §9's diagnostics must say which case
  applies rather than fail silently.

## 6. `WidgetViewModel` and the purity invariant

Today the pure, testable, byte-comparable artifact is the SVG string produced by
`WallpaperSVG`. `ImageRenderer` has no SVG output, so a SwiftUI widget cannot produce a text
artifact directly. Rather than lose the guarantee, the text artifact moves.

```
TelemetryModel  ──pure──▶  WidgetViewModel  ──SwiftUI──▶  pixels
                (golden-tested, Codable)      (thin, dumb)
```

`WidgetViewModel` is a `Codable`, `Equatable`, `Sendable` struct holding every string, number,
state and flag the widget draws — already formatted, already classified. The SwiftUI views
contain layout and no logic: no formatting, no threshold comparison, no date arithmetic.

This preserves *rendering is a pure function of its inputs* literally rather than
approximately. `WidgetViewModel.make` occupies the role `WallpaperSVG.render` occupied;
the SwiftUI view occupies the role `AppKitRasterizer` occupied — the impure edge, deliberately
thin. A layout regression fails in `swift test` as a text diff, on Linux as well as macOS.

## 7. Generated files and the website

`check-generated.sh` currently excludes `og.png` from byte-comparison and explains why it is
still safe: *"og.png is rendered from the same DemoSnapshots as the SVGs, and those are pure
text and are compared, so a layout change still fails this check."* The SVGs are the proxy
that makes the raster safe. Replacing them with rasters would remove that proxy, and CI would
lose the ability to detect a layout regression at all.

`web/widgets.json` restores it — the serialised `WidgetViewModel` for each fixture and family,
pure text, byte-compared.

| Artifact | Source | CI |
|---|---|---|
| `web/providers.json` | `ProviderRegistry` | exact compare, unchanged |
| `web/mark.svg`, `web/icon.svg` | `BrandMark` | exact compare, unchanged |
| `web/widgets.json` | `WidgetViewModel` × `DemoSnapshots` | **exact compare, new** |
| `web/widget-{small,medium,large}-*.png` | `ImageRenderer` | excluded, like `og.png` |
| `web/og.png` | `ImageRenderer` | excluded, unchanged |

CLI change: `tmu assets wallpaper <case>` → `tmu assets widget <family> <case>`, plus
`tmu assets widget-model <family> <case>` emitting the JSON. `tmu assets social` keeps its
name and renders the `systemMedium` view through `ImageRenderer`, centred on a 1200×630
canvas — the widget's aspect ratio is not the unfurler's, so it is placed on the canvas
rather than stretched to it.

`generate-web.sh` and the `GENERATED_SCOPE` exclusion list in `check-generated.sh` update to
match, and the comment in `check-generated.sh` explaining *why* the rasters are safe must be
rewritten to cite `widgets.json` rather than the SVGs.

## 8. Teardown on upgrade — required, not optional

An existing install has a LaunchAgent on a 300s timer and a rendered PNG set as the desktop
background. Deleting the feature's code without removing its footprint leaves that agent
invoking a `tmud` binary that no longer exists — failing silently every five minutes, the
exact failure `install-wallpaper-agent.sh` warns about — and a desktop permanently stuck on a
render, because macOS keeps no wallpaper history.

The migration steps therefore **grow**; they are not deleted with the feature. A new
`MigrationStep.wallpaperTeardown` runs on first launch after upgrade and:

1. `launchctl bootout` both `com.claudruple.wallpaper` and `com.trackmyusage.wallpaper`, and
   removes both `~/Library/LaunchAgents/*.plist` files.
2. Reads `original-wallpaper.txt`; if it names a file that still exists, restores it as the
   desktop background.
3. Deletes the rendered-wallpaper cache directories under both the old and new caches paths.
4. Is idempotent and reports `.skipped` with a reason when there is nothing to do, matching
   every existing step's contract.

This needs the AppKit wallpaper-setting call that `TMUDesktop` currently owns. The minimum
— `NSWorkspace.setDesktopImageURL` — moves into the migration runner as the last user of it,
with a comment saying it exists solely to undo something this project did. `TMUDesktop` is
still deleted.

`LegacyPaths` keeps its `original-wallpaper.txt` and agent-label constants for exactly as long
as this step exists; they are removal inputs now rather than migration inputs.

## 9. Diagnostics

`Diagnostics.Input.wallpaperAgentLoaded` and its check are replaced by a widget check with
four distinguishable outcomes, not two:

| Condition | Level | Message |
|---|---|---|
| `.appex` present, group container readable and fresh | ok | widget installed |
| `.appex` present, container missing or stale | warn | app not running, widget is frozen |
| `.appex` absent, app is ad-hoc signed | warn | built without a signing identity, widget unavailable — not a fault |
| `.appex` absent, app is properly signed | warn | widget missing, reinstall |

`Doctor.swift:97`'s `agentLoaded("com.trackmyusage.wallpaper")` is removed. The ad-hoc case
must be distinguishable from the broken case, because conflating them would report a supported
build as damaged.

## 10. The gate

```bash
swift build && swift test && swift build -c release \
  && ./scripts/build-app.sh && ./scripts/check-widget.sh \
  && swift format lint --strict --recursive Sources Tests
```

`swift build`/`swift test` cannot see the `.appex` — it exists only once `build-app.sh`
assembles it — so the gate gains a bundle-level step. `check-widget.sh` verifies, all of
which pass under an ad-hoc signature and therefore run on every CI push:

- the `.appex` exists at `TrackMyUsage.app/Contents/PlugIns/`;
- its `Info.plist` carries `NSExtensionPointIdentifier` = `com.apple.widgetkit-extension` and
  a `TMUAppGroupIdentifier`;
- its bundle ID is prefixed by the host app's;
- the embedded entitlements contain `app-sandbox` and `application-groups`, and the group
  matches the host app's;
- `codesign --verify --deep --strict` passes on the host app;
- the extension binary links `WidgetKit`.

The live container round-trip requires a real identity and runs only when `IDENTITY` is set
to something other than `-`. `test-scripts.sh` gains coverage of the Team-ID derivation and
the `Info.plist` injection, matching how it already covers instance identity.

## 11. Prose to update

The wallpaper is cited across roughly fifteen files as the canonical example of a principle.
These citations orphan when the files they name are deleted, and this codebase treats its
comments as load-bearing.

- **Dangling `WallpaperState.load` citations** — `Settings.swift:119`,
  `RenderHistory.swift:53`, `MigrationReceipt.swift:7`. Each cites it for the same stance: an
  unreadable file is an absent file. Repoint at whichever surviving implementation holds it;
  `SnapshotCache.load` states it too.
- **`Ink.swift:71`** — "the raw values are load-bearing: the wallpaper emits them as CSS
  classes" needs rewriting, not deleting. The raw values remain load-bearing because
  `widgets.json` keys on them; the justification changes and the constraint does not.
- **`TelemetryModel.swift:7`** — the "one model every surface renders" note lists the
  wallpaper first. The list becomes widget, menu bar pill, popover, instances window.
- **Comment-only mentions** in `Freshness.swift`, `Format.swift`, `UsageProvider.swift`,
  `ClaudeUsage.swift`, `InstanceFreshness.swift`, `Steering.swift`, `Sources.swift`,
  `TelemetryStore.swift` — reword to name the widget.
- **`CLAUDE.md`** — the layout table drops `TMURender`/`TMUDesktop` and gains `TMUWidgets`;
  the "SVG colours are presentation attributes" invariant is deleted with the renderer; the
  "rendering is a pure function" invariant is rewritten to cite `WidgetViewModel`; the gate
  block gains the widget step; a new invariant records why the widget only ever reads a file.
- **`README.md`** — the headline feature list, the `tmud` usage section, the wallpaper-agent
  install instructions, and the script table all change. The install path now ends at
  "place the widget from the desktop widget picker," and the signing requirement is stated
  plainly.
- **`docs/roadmap.md`** — "Usage wallpaper ✅" and "Wallpaper layouts" become widget rows.
- **`web/index.html`, `web/pricing.html`** — hero images and feature copy.

## 12. Build order

§5 is the only genuinely unproven part: whether `@main WidgetBundle` in an SPM
`executableTarget`, assembled into an `.appex` by hand and signed outside Xcode, is accepted
by macOS — and whether the App Group handshake works with an Apple Development certificate
without an Xcode-managed provisioning profile.

The plan front-loads it. **Step one is a walking skeleton**: an extension that renders one
hardcoded string, reading one key from the group container, placed on the desktop and
verified visually. No `WidgetViewModel`, no layouts, no deletions. If the toolchain does not
support this, it is discovered before any working code is removed.

Deletion happens only after the skeleton is proven, and the teardown step in §8 is built
before the wallpaper code is removed, so there is never a commit where an upgrading user
would be stranded.

## 13. Out of scope

- `AppIntentConfiguration` per-account widgets.
- Control Center controls (`ControlWidget`, macOS 15+).
- iOS or a companion app of any kind.
- Notification Center-only support for macOS 13, which the floor bump forecloses.
- The Linux and Windows desktop backends `DesktopFactory` mentions as "still to come" —
  they were wallpaper-only and are abandoned with it. `TMUProviders` and `TMUDesign` remain
  platform-neutral and the portability job is unchanged.
