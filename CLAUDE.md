# Claudruple → TrackMyUsage

Multi-account Claude Desktop management plus usage telemetry across your dev stack, on the
menu bar and painted onto the desktop wallpaper.

> **Rename in progress.** The product is becoming **TrackMyUsage**; the code still says
> `Claudruple` until that PR lands. When it does, update this file's target map — and read
> the frozen-names section below before changing a single string that reaches disk.

## The gate

Run this before every commit. All of it.

```bash
swift build && swift test && swift build -c release \
  && swift format lint --strict --recursive Sources Tests
```

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
ClaudrupleKit           instances · sync · Claude's local usage · steering
ClaudrupleUsage         the provider SDK: HTTP seam, snapshots, credentials, adapters
ClaudrupleUsageClaude   Claude's local history as provider snapshots
ClaudrupleRender        usage → SVG → raster
ClaudrupleDesktop       reading and writing the desktop background

claudruple              CLI: instances, sync, usage, steer, providers
claudrupled             renders and applies the usage wallpaper (one-shot, not resident)
Claudruple.app          menu bar gauge and instance window
Claudruple Link.app     deep-link broker
```

Pure SPM — there is **no Xcode project**. Both `.app` bundles are assembled by hand in
`scripts/build-app.sh` and `scripts/build-link.sh`, so a new Info.plist key, entitlement,
icon or resource is a change to a bash heredoc, not to a project file.

## Names that are frozen, and why

These strings are load-bearing. They look like leftovers from the old brand. They are not.
Changing any of them breaks a working install in a way that produces no error message.

| String | Why it cannot change |
|---|---|
| `com.anthropic.claudefordesktop.claudruple.<slug>` | Each instance is registered with LaunchServices under this id and **signed** with it. Renaming orphans the registration and invalidates the signature. |
| `/Applications/Claudruple` | Where the clones live. Registered with LaunchServices, and named absolutely in the broker's LaunchAgent plist. |
| `~/Library/Application Support/Claudruple/<Name>` | **Compiled into each clone's launcher shim** — `create-instance.sh` passes it as `-DUSER_DATA_DIR` to `clang`. `InstanceLocator.profileURL` must stay in lockstep. Move this directory and every instance boots a fresh, signed-out profile. |
| `com.claudruple.usage` (keychain service) | Kept **readable** forever as a fallback so an existing install's provider tokens still resolve after the rename. New writes go to the new service. |

If you are renaming things and one of these is in your way: stop, and route it through
`LegacyNames` instead. CI greps for stray occurrences and that file is the only exemption.

## Invariants

These are decisions, not accidents. Each one has a comment at its site explaining it; if you
are about to change one, read that comment first.

- **SVG colours are presentation attributes, never a `<style>` block.** Rasterisers implement
  CSS unevenly, and the renderer's tests assert on state classes. See the note at the top of
  `WallpaperSVG.swift`.
- **Rendering is a pure function of its inputs.** `snapshots → SVG string`. The daemon owns
  every byte of I/O. This is why a layout regression fails in `swift test` instead of
  appearing on somebody's desktop.
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
`Tests/ClaudrupleUsageTests/ProviderConformance.swift` is a shared harness every adapter test
calls before its own specifics; it checks, among other things, that the secret never appears
in a request URL.

## Generated files

Never hand-edit these; regenerate them and commit the result. CI fails if they are stale.

- *(none yet — the provider matrix and app icons arrive with the website and brand-mark PRs)*
