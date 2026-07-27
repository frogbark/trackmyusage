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

The calibration gate is closed: the field map, the limit list and the `xu` constant were read
out of the app bundle directly, so nothing here rests on inference. Parsing, forecasting and
the steering decision engine are built and covered by tests; the menu bar surface and
notifications wait on the GUI.

**Not implemented, deliberately:** switching the active Claude Code credential. The keychain
holds `Claude Code-credentials` alongside `Claude Code-credentials-<hash>` entries, but how
the CLI selects among them is not established, and writing keychain items on a guess risks
locking someone out of their own tooling. It needs its own investigation before any code.

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

**In progress.** The SDK, the credential store and one verified adapter are built; the
remaining fifteen are deliberately absent rather than stubbed.

### Why only one adapter so far

A parser written from a remembered API shape is indistinguishable from a correct one until
it reports the wrong number, and a usage dashboard that is quietly wrong is worse than one
that is honestly incomplete. ElevenLabs shipped because its response shape was verified
against current documentation. OpenAI's reference is behind a 403 and GitHub's usage
endpoint was not in the page that documents its billing API, so neither was written.

`claudruple provider probe <id>` exists to close that gap: it performs the real call and
prints the raw body, so a parser can be written against fact and the response saved as a
fixture. That is also the mechanism that lets contributors add a provider without anyone
else needing an account with them.

### The adapter contract

```swift
public protocol UsageProviderAdapter: Sendable {
    static var id: String { get }
    static var displayName: String { get }
    static var credentialSpec: CredentialSpec { get }
    static var capabilities: ProviderCapabilities { get }

    func request(credential: String) throws -> URLRequest
    func parse(_ data: Data, now: Date) throws -> ProviderSnapshot
}
```

Request-building and parsing are separate on purpose. Parsing is where the risk and the
churn live, and keeping it a pure function of `Data` means every adapter is verifiable
offline against a recorded fixture.

Everything normalises to one shape so a single view and a single alerting engine can serve
all of them. `utilization` is *derived* from value and limit, never reported: uncapped spend
yields nil rather than a percentage invented against a budget the user never set, and only
capped metrics can be a snapshot's binding constraint — an uncapped $9,999 must not outrank
a quota at 95%.

### Credentials

Keychain only, one service per provider, `AfterFirstUnlockThisDeviceOnly` and never synced.
Keys are read from stdin rather than a flag, because an argument lands in shell history and
in the process list. Every adapter declares the minimum scope that makes it work, in code,
so the setup flow and the docs cannot drift apart.

### Remaining, in order of API quality

| Tier | Providers |
|---|---|
| Verified | ElevenLabs ✅ |
| Expected to be straightforward | OpenAI, GitHub, Vercel, Twilio, Sentry, PostHog |
| Workable, thinner data | Firecrawl, Resend, Stripe (revenue, separate axis), Supabase, Modal, Inngest |
| Unknown until probed | Hostinger, Higgsfield, OpenArt — may end up manual entry |

**API-only, never scrape.** Where no usage API exists, report unavailable or accept manual
entry. A **renewal calendar** needs no usage API at all and is probably the broadest-appeal
feature in this phase.

## Phase 5 — Codex Desktop

Same problem, second app. Assessed against the real install rather than assumed —
`/Applications/ChatGPT.app` **is** Codex Desktop (bundle id `com.openai.codex`,
version 26.721.41059).

### What transfers

It is Electron, so the shape of the solution carries over: a real bundle per instance with
its own `CFBundleIdentifier`, `--user-data-dir` for the profile, quarantine cleared, and
re-signed inside-out. It calls `setAsDefaultProtocolClient` exactly like Claude, and claims
`codex://`, so the same last-launch-wins tug-of-war applies and the broker generalises —
it already resolves handlers by scheme, and needs only a second scheme registered.

### What does not

**It is sandboxed**, and that changes the cost of cloning. Its entitlements include
`com.apple.security.app-sandbox`, `com.apple.security.application-groups`,
`keychain-access-groups` and `com.apple.developer.aps-environment` — all Team-ID-bound and
unclaimable by a re-signed clone. Claude loses only WebAuthn and hardware-key login this
way; a Codex clone would additionally lose its app group, its sandbox container identity
and push notifications. Whether the app still functions usefully after that is the first
thing to establish, and it may be the finding that stops this.

It also ships **Sparkle**, so clones go stale and self-update attempts may fail signature
checks against a re-signed bundle.

### Open questions, each cheap to answer

1. **Where does its userData name come from?** `CFBundleName` is `ChatGPT`, the framework is
   `Codex Framework.framework`, and the profile lands at `~/Library/Application
   Support/Codex` — three different names. No `app.setName("…")` literal was found, so the
   mechanism differs from Claude's and needs a probe before `--user-data-dir` is trusted.
2. **Where are its Electron helpers?** `Contents/Frameworks` holds only `Codex
   Framework.framework` and `Sparkle.framework` — no `<Name> Helper.app`. Claude aborted at
   startup when `CFBundleName` moved away from its helpers; whatever Codex does instead
   determines whether that trap exists here at all.
3. **Does the sandbox survive ad-hoc re-signing**, and does the app still start without its
   app group?

Sequenced after the provider work: it shares the instance engine, and the engine should
settle before it grows a second app's worth of special cases.

## Phase 4 — Release

Developer ID signed and notarized, built in CI; buildable from source. Homebrew cask for the
app, `brew install claudruple` for the CLI.

Not the Mac App Store: the sandbox forbids `codesign`, cannot clear quarantine on files it
writes, and cannot manage LaunchServices — the exact ceiling that breaks existing tools.

Credit prior art (ccusage, Claude Code Usage Monitor, ccflare, MCP Config Sync) and offer
interop rather than competing on their ground.
