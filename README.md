# TrackMyUsage

Run multiple Claude Desktop accounts on one Mac — properly.

Each instance gets its own macOS app identity, its own profile, and its own place in the
Dock. A small broker makes sure sign-in and MCP OAuth callbacks reach the account that
asked for them, instead of whichever instance happened to launch last.

> **Status: early.** Instances, deep-link routing, config sync, usage tracking, steering,
> the menu bar app and the usage wallpaper all work and are in daily use. Five of seventeen
> provider integrations are built, two more have no public usage endpoint to build against,
> and the remaining ten are planned — see [`docs/roadmap.md`](docs/roadmap.md). The Pro tier
> described on the website is **not built**; nothing in this repository charges for anything.

TrackMyUsage never bundles or redistributes Claude Desktop. It clones the copy already
installed on your machine, leaves `app.asar` byte-for-byte untouched, and never handles
your credentials. **Each instance still requires its own paid Anthropic account.**

---

## Why wrappers break

The obvious approach — and what existing tools do — is to launch the stock binary with a
different `--user-data-dir`. That separates the *data* but not the *identity*, and macOS
keys almost everything on identity:

| Symptom | Cause |
|---|---|
| Double-clicking Claude does nothing | Both processes exec from the same bundle, so LaunchServices thinks the app is already running and just re-activates the other account's window |
| Sign-in lands in the wrong account | Claude calls `setAsDefaultProtocolClient("claude")` on **every** launch; last one wins |
| MCP OAuth callbacks vanish | Same tug-of-war, on `claude://claude.ai/mcp-auth-callback/sdk` |
| The second app runs from `/var/folders/…/AppTranslocation/…` | A quarantined bundle gets relocated to a random read-only path by Gatekeeper, and registers itself twice |

Data isolation was never the hard part. Identity is.

## What TrackMyUsage does instead

1. **A real bundle per instance.** APFS `clonefile` copy (sub-second, copy-on-write), a
   unique `CFBundleIdentifier`, re-signed inside-out, quarantine cleared.
2. **An in-bundle launcher shim** that injects `--user-data-dir`, because the app hardcodes
   `app.setName("Claude")` and would otherwise open the primary's profile.
3. **A deep-link broker** that owns `claude://`, tracks which instance you were last working
   in, and forwards each callback there — reclaiming the scheme within ~1s whenever an
   instance grabs it at launch.

See [`docs/findings.md`](docs/findings.md) for how each of these was determined, including
the things that failed first.

---

## Requirements

- macOS 13+ on APFS
- Claude Desktop installed at `/Applications/Claude.app`
- Xcode command line tools (`clang`, `swiftc`)

## Usage

```bash
git clone <this repo> && cd trackmyusage

# Build and install the deep-link broker (once)
./scripts/build-link.sh
cp -Rp "build/TrackMyUsage Link.app" /Applications/
./scripts/install-link-agent.sh

# Create an instance
./scripts/create-instance.sh "Work" --launch
```

> You will see `/Applications/Claudruple` elsewhere, and it is not a typo. The project was
> renamed, but that directory, each clone's bundle id and each clone's profile path are baked
> into LaunchServices registrations, code signatures and a compiled-in launcher path.
> Renaming them would not move anything — it would make working instances unreachable,
> silently. It stays, and it holds **clones only**: TrackMyUsage's own two apps install to
> `/Applications` like anything else.
> See [`Sources/TMUKit/LegacyNames.swift`](Sources/TMUKit/LegacyNames.swift).

Then sign into the new window with your second account. Remove one with:

```bash
./scripts/remove-instance.sh "Work"              # keeps the profile
./scripts/remove-instance.sh "Work" --purge-data # removes it too
```

### Keeping instances in step

```bash
swift build -c release
.build/release/tmu instances                    # what is installed
.build/release/tmu capture "Claude" > trackmyusage.yaml
.build/release/tmu plan trackmyusage.yaml         # read-only: shows what would change
.build/release/tmu apply trackmyusage.yaml        # install what is missing
.build/release/tmu apply trackmyusage.yaml --prune # also remove unmanaged extensions
```

Payloads are copied from an instance that already has them (`--from` to choose). On APFS
this is a clonefile copy: 15 extensions totalling 700 MB apply in ~2 seconds and cost about
54 MB of real disk. A snapshot is taken before the first write.

The manifest is meant to be committed. See [`examples/trackmyusage.yaml`](examples/trackmyusage.yaml).

Two rules the engine enforces rather than documents:

- **Account-scoped config never syncs.** `*ByAccount` permission grants, `oauth:tokenCache*`,
  and org-suffixed keys are refused and reported, not copied. Carrying a permission grant
  between accounts is a security bug, not a convenience.
- **Removal requires `--prune` on the command line**, even when the manifest says
  `policy: exact`. Manifests get shared; a file someone else wrote must not be able to
  delete your extensions. `keep:` exempts deliberate per-instance extras.
- **Extension settings are not copied.** `Claude Extensions Settings/*.json` holds things
  like `api_key` and `allowed_directories` — a credential and a filesystem grant. Sync moves
  tooling between accounts, not the authority to use it, so extensions arrive installed but
  unconfigured. `--with-settings` overrides this and copies the credentials too.
- **`apply` refuses to write to a running instance.** Claude rewrites its extension registry
  on exit and would discard the changes.

### The menu bar app

```bash
./scripts/build-app.sh
cp -Rp build/TrackMyUsage.app /Applications/
open -a /Applications/TrackMyUsage.app
```

Every account's binding limit, always visible — `61% · 100%`, with a warning glyph when one
is spent. The panel shows each limit, time-to-exhaustion where a trend is measurable, and a
switch button when another account has materially more headroom. Notifications fire once per
threshold per window and re-arm when the window rolls.

No Dock icon (`LSUIElement`). Add it to **System Settings → General → Login Items** to have
it start with the machine.

### Seeing usage across accounts

```bash
.build/release/tmu usage    # per-account limits, burn rate, time to exhaustion
.build/release/tmu steer    # which account to work in
```

No credentials and no network: Claude Desktop already records plan utilisation to
`plan-usage-history.json` in each profile, tagged by organisation. TrackMyUsage reads the same
numbers the app does, for every account at once. Existing monitors estimate usage from
Claude Code token logs; this is the app's own accounting.

`steer` names the account with headroom and stops there. `--yes` performs the switch.

### Your usage, on the desktop

```bash
swift build -c release
.build/release/tmud status    # what it would draw, and onto what
.build/release/tmud render    # write the image, leave the desktop alone
.build/release/tmud apply     # write it and set it as the wallpaper
```

Composites every account's limit, and every service's, onto the desktop background. Three
layouts, chosen per display:

| `--layout` | |
|---|---|
| `ledger` | a left rail naming every provider, with sparklines and a renewals line |
| `board` | tiles across the bottom of a wide desktop; falls back to the rail if the display is too narrow |
| `card` | a corner card: four named, the rest as bare bars, over a 30-day renewal axis |

The card is also the one that changes with the weather. When everything is under 80% it dims
to a whisper and stops enumerating — two accounts and one line confirming the rest was
checked. When something is hot it grows, brightens and leads with the offender. Silence is
information too.

Set a layout per display in `~/Library/Application Support/TrackMyUsage/settings.json`; a
laptop beside a large monitor usually wants `card` on one and `ledger` on the other.

The pipeline is snapshots → model → SVG → raster → desktop, and everything up to the raster
is a pure function — so a layout regression fails in `swift test` rather than appearing on
your screen.

Providers are fetched concurrently: seventeen adapters each allowed fifteen seconds would
stall a serial render for four minutes, where in parallel the slowest one sets the cost. A
provider is included when it needs no credential or has one stored.

### Metered service accounts

```bash
.build/release/tmu provider list           # what exists, what has a key
.build/release/tmu provider add stripe     # read from stdin, never a flag
.build/release/tmu provider probe stripe   # the real response, for writing a parser
.build/release/tmu provider check          # parsed snapshots
```

Built today: Claude (local files, no credential), ElevenLabs, GitHub, Stripe, Twilio. The
other twelve are **absent rather than stubbed** — a parser written from a remembered API
shape is indistinguishable from a correct one until it reports the wrong number. `probe`
captures a real response so each adapter is written against fact.

Credentials live in the login keychain only, `AfterFirstUnlockThisDeviceOnly`, one account
per provider. Every adapter declares its minimum read-only scope in code.

### Scripts

| Script | Purpose |
|---|---|
| `create-instance.sh` | Clone, stamp, shim, sign, register a new instance |
| `remove-instance.sh` | Remove an instance; keeps the profile unless `--purge-data` |
| `refresh-instance.sh` | Re-clone an instance from the current Claude, keeping its identity and profile |
| `sign-clone.sh` | Inside-out re-signing (used by the above) |
| `build-link.sh` | Build the deep-link broker |
| `install-link-agent.sh` | Register the broker as a login agent |
| `uninstall-link-agent.sh` | Stop the broker and hand `claude://` back |
| `build-app.sh` | Build the menu bar app |
| `finish-repair.sh` | One-off: migrate a Parall install into TrackMyUsage |
| `remove-parall.sh` | One-off: remove Parall after verifying the migration |

## Signing

Ad-hoc signing (the default) requires `com.apple.security.cs.disable-library-validation`,
because hardened-runtime library validation only admits libraries whose Team ID matches the
loader's — and ad-hoc code has no Team ID. Signing with a real Developer ID makes the Team
IDs match throughout, and the scripts then omit that entitlement automatically:

```bash
IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/create-instance.sh "Work"
```

## Known limitations

- **Passkey / hardware-key sign-in may not work in clones.** The stock app carries
  `keychain-access-groups` entitlements bound to Anthropic's Team ID, which cannot survive
  re-signing. Keep the account that needs passkeys on the untouched `/Applications/Claude.app`.
- **Clones do not auto-update.** They are byte copies taken at a moment in time. `tmu instances`
  marks any that are on a different build, and `./scripts/refresh-instance.sh --all` re-clones
  them from the Claude you have now. Profiles are untouched: they live outside the bundle, and
  the refresh reuses each instance's existing bundle id and the profile path compiled into its
  launcher rather than deriving either.
- **`safeStorage` is shared.** Electron derives the keychain item from `app.getName()`, which
  is hardcoded, so all instances share `Claude Safe Storage`. Profiles remain separate; the
  encryption key does not. On the upside, this is why migrating a profile between instances
  does not force a re-login.
- Apple Silicon only for now (the shim is built `arm64`).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
