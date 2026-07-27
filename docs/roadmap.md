# Roadmap

## Where things are

```
ClaudrupleKit           instances · sync · Claude's local usage · steering
ClaudrupleUsage         the provider SDK: HTTP seam, snapshots, credentials, adapters
ClaudrupleUsageClaude   Claude's local history as provider snapshots
ClaudrupleRender        usage → SVG → raster
ClaudrupleDesktop       reading and writing the desktop background

claudruple              CLI: instances, sync, usage, steer, providers
claudrupled             renders and applies the usage wallpaper
Claudruple.app          menu bar gauge and instance window
Claudruple Link.app     deep-link broker
```

| | State |
|---|---|
| Instances and deep-link routing | **working** |
| Config sync — capture, plan, apply | **working** |
| Claude usage, forecasting, steering | **working** |
| Menu bar app | **working** |
| Usage wallpaper | **working** |
| Provider adapters | 4 of 17 |
| Codex Desktop | assessed, not started |
| Release | not started |

---

## Instances and routing ✅

A real bundle per instance with its own `CFBundleIdentifier`, an in-bundle shim injecting
`--user-data-dir`, and a broker that owns `claude://` and re-claims it within about a second
whenever an instance grabs it at launch. See [`findings.md`](findings.md) for how each was
determined, including the approaches that failed first.

## Config sync ✅

A declarative, git-committable manifest. `capture` writes one from an instance, `plan` shows
the difference and changes nothing, `apply` converges.

Three rules the engine enforces rather than documents:

- **Account-scoped configuration never crosses accounts.** `*ByAccount` grants,
  `oauth:tokenCache*` and org-suffixed keys are refused and reported.
- **Removal needs `--prune` on the command line**, even when the manifest says
  `policy: exact` — a manifest from someone else's repo must not delete your extensions.
  `keep:` exempts deliberate per-instance extras.
- **Extension settings are not copied.** They hold `api_key` and `allowed_directories`;
  sync moves tooling between accounts, not the authority to use it.

**Still open:** re-cloning instances when Claude updates, a tinted icon per instance, and
instance management in the GUI rather than only the CLI.

## Usage and steering ✅

The calibration question is settled from source: the field map, the limit list and the `xu`
constant were read out of the app bundle, so nothing rests on inference. Utilisation values
are the app's own accounting, not an estimate reconstructed from token logs.

Forecasting is reset-aware — utilisation only rises within a window, so a fall means the
window rolled and a slope fitted across that boundary would hide an imminent exhaustion.
Rate and staleness windows scale to each metric's own period.

Steering names the account with headroom and stops there; switching is offered, never
performed unprompted.

**Not implemented, deliberately:** switching the active Claude Code credential. The keychain
holds `Claude Code-credentials` alongside `Claude Code-credentials-<hash>` entries, but how
the CLI selects among them is not established, and writing keychain items on a guess risks
locking someone out of their own tooling.

## Usage wallpaper ✅

`claudrupled` composites every provider's binding limit onto the desktop background.

The pipeline is snapshots → SVG → raster → desktop, and the split is what makes it testable:
the whole visual design is a pure function from snapshots to SVG text, so a layout
regression fails in `swift test` rather than appearing on someone's screen. Only the last
step is platform-specific.

Providers are fetched concurrently. Serially, seventeen adapters each allowed fifteen
seconds could stall a render for four minutes; in parallel the slowest one sets the cost.
A provider is included when it needs no credential or has one stored — fetching an
unconfigured one would spend a render cycle drawing "unauthorized" on someone's desktop.

**Still open:** running it on a schedule rather than on demand, and per-display density
selection.

---

## Provider adapters — in progress

Four of seventeen. The rest are absent rather than stubbed, and that is the whole policy: a
parser written from a remembered API shape is indistinguishable from a correct one until it
reports the wrong number, and a usage dashboard that is quietly wrong is worse than one that
is honestly incomplete.

| Built | Verified how |
|---|---|
| Claude | local files; field map read from the app bundle |
| ElevenLabs | response shape confirmed against current docs |
| GitHub | `/rate_limit` confirmed against a live call; billing shape confirmed against docs |
| Stripe | confirmed against current docs, including minor-unit amounts |
| Twilio | confirmed against current docs, including string-typed usage fields |

| Blocked | Why |
|---|---|
| OpenAI | API reference returns 403; the published OpenAPI spec omits the costs endpoint |
| Vercel | `/v2/user` documents `billing` as nullable with no fields |
| Sentry, PostHog | shapes documented; not yet written |
| Firecrawl, Resend, Supabase, Modal, Inngest | thinner data expected |
| Hostinger, Higgsfield, OpenArt | no confirmed usage API; may end up manual entry |

`claudruple provider probe <id>` closes the gap: it performs the real call and prints what
came back, so a parser gets written against fact and the response saved as a fixture. That
is also what lets a contributor add a provider without anyone else holding an account.

### The contract

```swift
public protocol UsageProvider: Sendable {
    var id: String { get }
    var credentialSpec: CredentialSpec { get }
    func fetch(secret: String?, now: Date) async throws -> ProviderReading
}
```

Adapters implement `fetch` and nothing else. Turning a failure into a snapshot, checking for
a missing credential and stamping the identity happen once in a protocol extension, so
seventeen adapters cannot disagree about what an outage looks like. `snapshot()` never
throws — one provider being down is the normal state of at least one of seventeen at any
moment, and propagating it would let a single timeout take out the whole render.

`HTTPClient` is deliberately GET-only: an adapter that could POST would be an adapter that
could be made to change something, and the entire credential story is that a leaked token
cannot. `FixtureHTTPClient` replays recorded responses and logs the requests, so a test can
assert the URL and headers an adapter used, and an unrecorded URL throws rather than
silently succeeding — which catches an adapter calling the wrong endpoint.

`utilization` is derived from value and limit, never reported. Uncapped spend yields nil
rather than a percentage invented against a budget nobody set, and only capped metrics can
be a snapshot's binding constraint — an uncapped $9,999 must not outrank a quota at 95%.

**API-only, never scrape.** Where no usage API exists, report unavailable or accept manual
entry. A **renewal calendar** needs no usage API at all and is probably the broadest-appeal
feature left in this phase.

### Credentials

Login keychain only — one service, one account per provider,
`AfterFirstUnlockThisDeviceOnly`. `AfterFirstUnlock` so a launch agent can read it on a
booted-but-not-logged-in machine; `ThisDeviceOnly` because a provider API key has no
business replicating to iCloud Keychain. Secrets are read from stdin rather than a flag,
since an argument lands in shell history and the process list. Every adapter declares its
minimum read-only scope in code, so the setup flow and the docs cannot drift apart.

---

## Codex Desktop — assessed, not started

`/Applications/ChatGPT.app` **is** Codex Desktop (bundle id `com.openai.codex`, version
26.721.41059).

**Transfers:** it is Electron, claims `codex://`, and calls `setAsDefaultProtocolClient` on
launch — the same last-launch-wins tug-of-war. The broker already resolves handlers by
scheme and needs only a second one registered.

**Does not:** it is sandboxed. Its entitlements include `app-sandbox`,
`application-groups`, `keychain-access-groups` and `aps-environment`, all Team-ID-bound and
unclaimable by a re-signed clone. Claude loses only WebAuthn and hardware-key login that
way; a Codex clone would additionally lose its app group, its container identity and push.
Whether it still runs usefully after that is the first thing to establish, and may be what
stops this. It also ships Sparkle, so clones go stale and self-update may fail signature
checks.

**Open questions, each cheap to answer:**

1. Where does its userData name come from? `CFBundleName` is `ChatGPT`, the framework is
   `Codex Framework.framework`, the profile lands at `~/Library/Application Support/Codex`
   — three names that disagree, with no `app.setName("…")` literal found.
2. Where are its Electron helpers? `Contents/Frameworks` holds only the framework and
   Sparkle — no `<Name> Helper.app`. Claude aborted at startup when `CFBundleName` moved
   away from its helpers; whatever Codex does instead decides whether that trap exists here.
3. Does the sandbox survive ad-hoc re-signing, and does the app start without its app group?

## Release — not started

Developer ID signed and notarised, built in CI, buildable from source. Homebrew cask for the
apps, `brew install claudruple` for the CLI.

Not the Mac App Store: the sandbox forbids `codesign`, cannot clear quarantine on files it
writes, and cannot manage LaunchServices — the exact ceiling that breaks existing tools.

Credit prior art — ccusage, Claude Code Usage Monitor, ccflare, MCP Config Sync — and offer
interop rather than competing on their ground.
