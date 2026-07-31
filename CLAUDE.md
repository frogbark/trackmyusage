# TrackMyUsage

Multi-account Claude Desktop management plus usage telemetry across your dev stack, on the
menu bar and in a desktop widget.

The project was called **Claudruple** until mid-2026. That name still appears in four places
on disk and always will — read the frozen-names section before changing any string that
reaches a file, a bundle id or the keychain.

## The gate

Run this before every commit. All of it.

```bash
swift build && swift test && swift build -c release \
  && ./scripts/build-app.sh && ./scripts/check-widget.sh \
  && swift format lint --strict --recursive Sources Tests
```

`swift build` and `swift test` cannot see the widget: the `.appex` exists only once
`build-app.sh` has assembled it, and every way it can be wrong is silent — a missing
`Info.plist` key registers nothing and logs nothing. `check-widget.sh` passes under an ad-hoc
signature, so CI runs it without a certificate.

`swift format` is a toolchain subcommand as of Swift 6 — there is nothing to install.

## Workflow

Branch per task, never commit to `main`, one logical change per PR, open it as a **draft**.
CI must be green before marking it ready.

`git blame` is configured to skip mechanical commits:

```bash
git config blame.ignoreRevsFile .git-blame-ignore-revs
```

GitHub honours that file automatically. Add wholesale reformats and pure renames to it —
never a commit that changed behaviour.

## Layout

```
TMUDesign               the palette, ok/warn/over, thresholds, the brand mark
TMUProviders            the provider SDK: HTTP seam, snapshots, credentials, adapters
TMUTelemetry            raw snapshots → the one model every surface renders · demo fixtures
TMUKit                  instances · sync · Claude's local usage · steering · migration
TMUClaude               Claude's local history as provider snapshots
TMUWidgets              the model → WidgetViewModel → SwiftUI · the shared container
TMUAppCore              the app's stores and views, as a library

tmu                     CLI: instances, sync, usage, steer, providers, assets
TMUWidgetExtension      the widget itself; built into the app as an .appex
TrackMyUsage.app        menu bar gauge, instances window, and the widget
TrackMyUsage Link.app   deep-link broker
```

`TMUDesign` and `TMUProviders` depend on **nothing**, deliberately, and CI has a Linux job
that proves it. `TMUTelemetry` is the choke point where snapshots become drawable — the
widget, the pill, the popover and the instances window all render the same `TelemetryModel`,
which is the only structural guarantee they agree.

`TMUWidgets` deliberately depends on neither `TMUKit` nor `TMUProviders`: the extension is
sandboxed and has no business reaching the keychain, the network or `/Applications`. It also
does not import WidgetKit — only the extension does — so the same views render identically in
the CLI, the tests and the widget.

Modules are TMU-prefixed rather than spelling the brand out — `TrackMyUsageUsage` is
indefensible, and the brand already contains the word. The full name lives where people
actually meet it: the binaries, the bundles, the domain.

Pure SPM — there is **no Xcode project**. Both `.app` bundles and the `.appex` are assembled
by hand in `scripts/build-app.sh`, `scripts/build-link.sh` and `scripts/build-widget.sh`, so a
new Info.plist key, entitlement, icon or resource is a change to a bash heredoc, not to a
project file.

**The widget needs real signing.** A widget extension is mandatorily sandboxed, so it reads
the app's telemetry through an App Group, and `com.apple.security.application-groups` is
Team-ID-bound — an ad-hoc signature cannot carry it. `IDENTITY=-` therefore produces a
complete, working app with no widget, which is a supported configuration and not a fault;
`tmu doctor` distinguishes it from a broken install. Set `IDENTITY` to a Developer certificate
to get the widget. The Team ID is never committed: `build-app.sh` derives it and writes it
into both bundles under `TMUAppGroupIdentifier`.

## Names that are frozen, and why

These strings are load-bearing. They look like leftovers from the old brand. They are not.
Changing any of them breaks a working install in a way that produces no error message.

| String | Why it cannot change |
|---|---|
| `com.anthropic.claudefordesktop.claudruple.<slug>` | Each instance is registered with LaunchServices under this id and **signed** with it. Renaming orphans the registration and invalidates the signature. |
| `/Applications/Claudruple` | Where the clones live. Registered with LaunchServices, and named absolutely in the broker's LaunchAgent plist. |
| `~/Library/Application Support/Claudruple/<Name>` | **Compiled into each clone's launcher shim** — `create-instance.sh` passes it as `-DUSER_DATA_DIR` to `clang`. `InstanceLocator.profileURL` must stay in lockstep. Move this directory and every instance boots a fresh, signed-out profile. |
| `com.claudruple.usage` (keychain service) | Kept **readable** forever as a fallback so an existing install's provider tokens still resolve after the rename. New writes go to the new service. |

The first three live in `Sources/TMUKit/LegacyNames.swift`; the keychain service is
`KeychainCredentials.legacyService`, kept in `TMUProviders` because that target depends on
nothing and importing TMUKit for a string would trade that away.

If you are renaming things and one of these is in your way: stop, and route it through those
constants. `scripts/check-frozen-names.sh` runs in CI and fails on any occurrence that is not
a known frozen form — so a new one has to be justified rather than merely typed.

**This is not hypothetical.** The rebrand broke two of these on its first attempt. The
substitution protected each frozen string wherever it appeared as contiguous text, and could
not see the two the code assembled from parts — `"\(prefix).claudruple."` and an
`appendingPathComponent("Claudruple")`. Nothing about the diff looked wrong. Three tests
failed, which is the only reason it was caught.

## Invariants

These are decisions, not accidents. Each one has a comment at its site explaining it; if you
are about to change one, read that comment first.

- **Rendering is a pure function of its inputs.** `snapshots → TelemetryModel →
  WidgetViewModel`, all text, all comparable. The SwiftUI views hold layout and nothing else:
  no formatting, no threshold comparison, no date arithmetic. A view that computes something
  is a view whose output the goldens do not describe. This is why a layout regression fails in
  `swift test` and in `check-generated.sh` instead of appearing on somebody's desktop.
- **The widget only ever reads a file.** The app polls, writes `TelemetryModel` to the App
  Group container and calls `reloadTimelines`; the extension reads that and nothing else. It
  has no network, no keychain and no provider code, which is enforced by its dependencies
  rather than by convention.
- **Widget staleness is precomputed, never refreshed.** One container read emits a fresh entry
  and a second dated to the freshness threshold, already marked. A single entry with policy
  `.never` would leave a frozen widget presenting an old number as current forever, because
  nothing would ever ask it to render again.
- **All published and generated JSON goes through `CanonicalJSON`.** `JSONEncoder` orders keys
  by a per-process hash seed, so the same value encodes differently between runs — which would
  make `web/widgets.json` differ between the machine that committed it and the runner that
  regenerates it.
- **`HTTPClient` has exactly one method, `get`.** That single-method protocol *is* the
  GET-only enforcement — there is no other verb to call. An adapter that could POST is an
  adapter that could be made to change something.
- **Credentials never leave the keychain.** Read-only scopes declared per adapter, secrets
  read from stdin and never from a flag (a flag lands in shell history and in `ps`).
- **Adapters are absent, not stubbed.** A parser written from a remembered API shape is
  indistinguishable from a correct one until it reports the wrong number. `provider probe`
  captures a real response so each adapter is written against fact.
- **Account-scoped config never syncs.** Carrying a permission grant between accounts is a
  security bug, not a convenience.
- **Absence is stated, never drawn as zero.** No data reads "no data"; a stale number carries
  `?`; an unmeasurable trend prints nothing rather than a flat line.

## Tests

XCTest, `final class XxxTests: XCTestCase`. Test names are full sentences describing the
behaviour (`testAZeroLimitHasNoUtilisationRatherThanInfinity`), and nearly every test carries
a comment naming the failure it prevents. Keep both habits — they are why this suite is
readable.

Fixtures are inline string literals, recorded from real responses and annotated with the date.
`Tests/TMUProvidersTests/ProviderConformance.swift` is a shared harness every adapter test
calls before its own specifics; it checks, among other things, that the secret never appears
in a request URL.

## Generated files

Never hand-edit these; regenerate them and commit the result. CI fails if they are stale.

- `web/providers.json` — from `ProviderRegistry`, via `tmu provider --json`
- `web/mark.svg`, `web/icon.svg` — from `BrandMark`, via `tmu assets mark`
- `web/widgets.json` — from `WidgetViewModel` × `DemoWidget`, via `tmu assets widget-models`
- `web/widget-*.png`, `web/og.png` — via `tmu assets widget` / `social`

Regenerate with `./scripts/generate-web.sh`. CI runs `./scripts/check-generated.sh` and fails
if the committed copies differ, which is what makes the provider counts on the website
structurally unable to overstate what actually ships.

The PNGs are excluded from that comparison — CoreGraphics and the installed fonts decide their
bytes and neither is in this repository. `web/widgets.json` is what carries the guarantee
instead: it holds the view models those images are drawn from, as text, and a layout change
alters the model before it alters a pixel. It is the successor to the wallpaper SVGs, which
did this job when the renderer emitted text. **Do not exclude it** to fix a spurious diff —
that would quietly delete the check.
