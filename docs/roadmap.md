# Roadmap

Three pillars over one shared account model. That model is what keeps this a single
product rather than three tools.

```
ClaudrupleKit (Swift package, no UI, unit-tested)
├── Accounts     — instance identity, org UUIDs, keychain refs
├── Instances    — Clone · Stamp · Sign · Register · Migrate · Launch · Update   [Phase 0 ✓]
├── Usage        — providers → normalized UsageSnapshot → history → alerts
└── Sync         — manifest parse · diff · plan · apply, with scope safety

claudruple (CLI)          — thin wrapper over the kit
Claudruple.app (SwiftUI)  — window + always-visible menu bar gauge
Claudruple Link.app       — deep-link broker                                     [Phase 0 ✓]
```

## Phase 0 — Instances and routing ✅

Done and in use. See [`findings.md`](findings.md).

## Phase 1 — Instances + Sync

Port the shell scripts to `ClaudrupleKit`, add the GUI, and build config sync.

Sync uses a declarative, git-committable manifest — reproducible, reviewable, survives a
machine rebuild, and shareable, which is the point:

```yaml
version: 1
instances:
  - name: Work
    extensions: [ant.dir.ant.anthropic.filesystem, ant.dir.gh.stripe.stripe]
    skills:     [superpowers, dataviz]
    plugins:    [vercel, posthog]
  - name: Personal
    inherits: Work
    extensions: { add: [ant.dir.gh.blender.blender-mcp] }
```

`sync plan` prints the diff and changes nothing; `sync apply` converges; `sync capture`
generates a manifest from an existing instance. The environment/account/machine scope split
in [`findings.md`](findings.md#7-config-surfaces-and-which-are-safe-to-sync) is enforced in
the engine, not left to the manifest author.

Also: watch the primary's `CFBundleShortVersionString` and offer to re-clone instances when
Claude updates (profiles untouched), and generate a tinted icon per instance so the Dock and
Cmd-Tab are distinguishable.

**Open question:** whether the `-3p` managed-settings path is per-instance or global for a
clone. Not needed for Phase 0, but it determines how managed settings can be applied later.

## Phase 2 — Usage and steering

Gated on calibrating `fh` / `sd` against the in-app usage UI. Alerting on a misread field is
worse than no alerting.

- Sampler merges `plan-usage-history.json` per instance by org UUID into SQLite, backfilling
  existing history so the first launch already has a chart.
- Menu bar gauge — always-visible 5-hour and weekly figures per account.
- Burn-rate forecast, native notifications at configurable thresholds.
- **Steering:** active routing with confirmation required by default — name the account with
  headroom, offer one click to switch to it or to swap the active Claude Code credential
  (the keychain already keys these by account hash: `Claude Code-credentials-<hash>`). An
  opt-in Auto-steer mode does it without prompting. In-flight conversations are never moved.

Zero credentials, works offline. This is the first-run hook: real usage across every account
within seconds of launch.

## Phase 3 — Multi-provider telemetry

One `UsageSnapshot` shape across every provider, so a single view and a single alerting
engine serve all of them:

```swift
struct Metric {
  let key: String      // "five_hour", "weekly", "credits", "spend_usd", "seats"
  let kind: Kind       // .percentOfLimit | .absolute | .currency | .count
  let value: Double
  let limit: Double?
  let window: Window   // .rolling(5.hours) | .calendarMonth | .billingPeriod | .none
  let resetsAt: Date?
}
```

Tiered honestly by API feasibility:

| Tier | Providers | Notes |
|---|---|---|
| 1 — local | Claude | `plan-usage-history.json`; no credentials; offline |
| 2 — solid APIs | OpenAI, GitHub, Vercel, Twilio, ElevenLabs, Sentry, PostHog | Real spend/quota endpoints, clean read-only scopes |
| 3 — workable | Firecrawl, Resend, Stripe, Supabase, Modal, Inngest | Thinner data. **Stripe is revenue, not spend** — shown on its own axis |
| 4 — verify | Hostinger, Higgsfield, OpenArt | Public usage APIs uncertain; fall back to manual entry |

**API-only, never scrape.** Where no usage API exists, report unavailable or accept manual
entry. Scraping billing pages is brittle and generally violates ToS.

Cross-cutting: a **renewal calendar** (what renews when, total monthly commitment) needs no
usage API at all and is probably the broadest-appeal feature here.

Credentials live in the Keychain only, per-provider ACL, never on disk or in the repo. Each
adapter documents the **minimum read-only scope**, so a leaked token cannot spend money or
mutate infrastructure.

### Adapter SDK — the growth engine

```swift
protocol UsageProvider {
  static var id: String { get }
  static var credentialSpec: CredentialSpec { get }
  var capabilities: ProviderCapabilities { get }
  func fetch() async throws -> [UsageSnapshot]
}
```

Every adapter ships recorded HTTP fixtures and runs against a shared conformance suite, so a
contributor can add or verify a provider without owning a paid account. That is what turns
17 integrations one person maintains into 17 the community maintains.

## Phase 4 — Release

Developer ID signed and notarized, built in CI; buildable from source. Homebrew cask for the
app, `brew install claudruple` for the CLI.

Not the Mac App Store: the sandbox forbids `codesign`, cannot clear quarantine on files it
writes, and cannot manage LaunchServices — the exact ceiling that breaks existing tools.

Credit prior art (ccusage, Claude Code Usage Monitor, ccflare, MCP Config Sync) and offer
interop rather than competing on their ground.
