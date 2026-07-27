# Findings

How Claude Desktop behaves on macOS when you try to run more than one account, determined
by inspection of a real install (Claude Desktop 1.24012.9, macOS 26.5, Apple Silicon).

Recorded because every one of these cost real debugging time, and because the design only
makes sense once you know why the obvious approaches fail.

---

## 1. Identity, not data, is what separates instances

`--user-data-dir` separates profiles and nothing else. A wrapper that exec's the stock
binary produces a process whose enclosing bundle — and therefore whose
`CFBundleIdentifier` — is still the *original* app.

Observed on the broken install:

```
PID 749  /Applications/Claude.app/Contents/MacOS/Claude \
           --user-data-dir=/Users/…/Library/Application Support/Parall/Claude 2
```

macOS keys activation, the Dock, notifications, TCC grants, and URL routing on the bundle
identifier. With two processes claiming one identifier, double-clicking the stock app sends
a re-open event to the *other* account's window. It reads as "the app won't launch."

**Consequence:** each instance needs a genuine bundle with its own `CFBundleIdentifier`.

## 2. `CFBundleName` cannot be changed

The intuitive move — rename the bundle so Electron picks a different `userData` path —
fails twice.

Electron resolves its XPC helpers at `Contents/Frameworks/<CFBundleName> Helper.app`.
Rename it and startup aborts:

```
FATAL:electron/shell/app/electron_main_delegate_mac.mm:66] Unable to find helper app
```

And it would not have helped anyway, because `app.asar` contains:

```js
app.setName("Claude")
```

`app.getName()` is therefore constant, so `app.getPath("userData")` resolves to the
**primary's profile** regardless of the bundle name. A clone launched without an explicit
flag opens the main account's data.

**Consequence:** `CFBundleName` stays `Claude`; `CFBundleDisplayName` carries the label; and
`--user-data-dir` must be injected. An in-bundle shim (`src/launcher/launcher.c`) does it —
exec'ing a *sibling* binary, so the enclosing bundle and hence the identity stay ours.

## 3. Ad-hoc signing needs library validation disabled

Re-signing invalidates Anthropic's Developer ID signature, so the clone must be signed
again. Ad-hoc signing then fails at load:

```
Library not loaded: @rpath/Electron Framework.framework/Electron Framework
Reason: … (code signature …)
```

Hardened-runtime library validation only admits libraries whose Team ID matches the
loader's, and ad-hoc code has no Team ID. Adding
`com.apple.security.cs.disable-library-validation` resolves it — Anthropic already ships
that entitlement on `Claude Helper (Plugin).app`.

Signing with a real Developer ID makes the Team IDs match, and the entitlement becomes
unnecessary; `sign-clone.sh` injects it only for ad-hoc.

### Entitlements that must be stripped

Bound to Anthropic's Team ID and unclaimable by anyone else:

- `com.apple.application-identifier`
- `com.apple.developer.team-identifier`
- `keychain-access-groups` — `Q6L2SF6YDW.com.anthropic.claude.webauthn`, `.hwkey`, and the
  Microsoft identity groups

Losing the keychain groups is why **passkey and hardware-key sign-in may not work in a
clone**. Keep that account on the untouched primary.

### Entitlements that must be kept

`com.apple.security.cs.allow-jit` is required or V8 will not start. The
`device.*` and `personal-information.*` entitlements gate camera, microphone, and location
under the hardened runtime and are preserved.

### Signing order

`--deep` is deprecated and unreliable on Electron. Sign inside-out: unpacked `.node`/`.dylib`
→ framework internals → nested helper `.app`s → loose helpers → **any extra Mach-O in
`Contents/MacOS`** → framework bundle roots → outer bundle.

That second-to-last step is easy to miss. The real Electron binary, once displaced by the
shim, becomes nested code that must be signed standalone — and it needs the full entitlement
set in its own right, because `execv` replaces the process image and the entitlements that
take effect are the ones on the binary actually executed.

## 4. `claude://` is contested on every launch

```js
function Urr(){
  if (Me().authentication.disableDeepLinks)
    for (const e of v7e) P.app.removeAsDefaultProtocolClient(e, b7e, S7e);
  else
    for (const e of v7e) P.app.setAsDefaultProtocolClient(e, b7e, S7e);
}
```

Every instance claims the scheme at launch, so the most recent launch wins and callbacks go
wherever it points. Schemes involved: `claude` and
`msauth.com.anthropic.claudefordesktop`. Known deep links:

- `claude://claude.ai/mcp-auth-callback/sdk`
- `claude://resume`
- `claude://cowork/shared-artifact`

### Why the built-in switch is the wrong tool

`disableDeepLinks` (flat key `disableDeepLinkRegistration`, scope `3p`, since 1.6889.0)
makes an instance release the scheme. But with it on, the handler accepts only a narrow set:

```js
if (Me().authentication.disableDeepLinks) {
  const [, l] = i.pathname.split("/");
  if (!(i.host === Zd.Login || i.host === Zd.ClaudeAI && (l === Fr.MagicLink || l === Fr.SSOCallback)))
    return  // declined
}
```

`mcp-auth-callback` is not in that set, so MCP OAuth would break. It also resolves from a
system-wide `managed-settings.json`, so it cannot be applied per instance. It trades a
routing bug for a worse one.

### What works

A broker owns the scheme and re-claims it after each instance launch. Measured on a real
launch:

```
00:27:14  clone process starts
00:27:31  didLaunchApplication fires (Electron reports late)
00:27:34  steal detected, scheme reclaimed
```

A single delayed check leaves a ~10s window in which the wrong app owns `claude://`. A burst
of probes at 1, 3, 6, 10, 15, 22, 30s closes it — reclaim now lands at **+1s**. No
steady-state polling is needed, because instances only ever steal at launch.

Routing uses the **last activated** Claude instance, not the frontmost one: by the time a
callback arrives the browser is frontmost, and what matters is which instance the user was
in when they started signing in.

Two discovery traps, both found by testing: Electron's XPC helpers share the bundle-ID
prefix (filter to top-level apps), and scanning the install directory picks up the broker
itself — which would route to itself and loop.

## 5. Gatekeeper translocation

Parall's stub carried `com.apple.quarantine: 00c6;00000000;Parall;`, so Gatekeeper ran it
from a randomised read-only path and LaunchServices held **two** registrations — the real
one and the translocated one — both claiming `claude:`.

A sandboxed app cannot clear the quarantine bit on files it writes, which is why an App
Store tool cannot avoid this. Clear it explicitly after creating a bundle.

## 6. Usage telemetry is available locally

`<userData>/plan-usage-history.json`:

```json
{ "version": 2, "samples": [ { "t": 1784969883372, "org": "8339cad5-…", "u": { "fh": 19, "sd": 100 } } ] }
```

Sampled roughly every 13 minutes and tagged by org UUID, so per-account history is already
separated on disk. `fh` / `sd` correspond to the two limits on Max plans — a rolling 5-hour
window and a 7-day cap. **This mapping is inferred and not yet calibrated against the in-app
usage UI; do not build alerting on it until it is.**

There is no usage API for consumer plans, which is why existing monitors estimate from
Claude Code token logs instead. This file is the app's own accounting.

## 7. Config surfaces, and which are safe to sync

Environment-scoped — safe to propagate:

- `Claude Extensions/`, `Claude Extensions Settings/`, `extensions-installations.json`
- `~/.claude/skills`, `~/.claude/plugins`, `CLAUDE.md`

Account-scoped — **never** propagate:

- `bypassPermissionsGateByAccount`, `bypassPermissionsOptInByAccount`,
  `coworkModelAutoFallbackByAccount`
- `lastKnownAccountUuid`, `oauth:tokenCache`, `oauth:tokenCacheV2`, `dxt:allowlist*:<org>`

Copying a permission grant from one account onto another is a security bug, not a
convenience. Note that MCP servers no longer live in `claude_desktop_config.json` — that
file now holds only `coworkUserFilesPath` and `preferences`.
