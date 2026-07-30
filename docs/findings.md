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

## 8. Codex Desktop is not the same shape as Claude Desktop

Measured against `/Applications/ChatGPT.app`, `com.openai.codex`, version `26.721.41059`.
All of it is read-only inspection; nothing was cloned or launched.

### It is Electron, but the Chromium underneath is not stock

`Contents/Resources/app.asar` is present, so the packaging is Electron. The profile it
writes is not: `~/Library/Application Support/Codex` contains `ChromeFeatureState`,
`Crowd Deny`, `AmountExtractionHeuristicRegexes` and `CaptchaProviders` — Chrome browser
features, not things an Electron app accumulates. The helper set says the same:
`app_mode_loader` and `web_app_shortcut_copier` ship with Chromium, not with Electron.

This matters because the Claude playbook assumes Electron's conventions, and two of the
three traps that shaped it turn out not to apply here.

### Where the profile name comes from — and why the shim still works

Three names disagree, and none of them is the answer:

| | |
|---|---|
| `CFBundleName` | `ChatGPT` |
| Framework | `Codex Framework.framework` |
| Profile | `~/Library/Application Support/Codex` |

There is no `app.setName("Codex")` in the asar — the only `setName` hits are a date
library. The string is compiled into `Codex Framework`, as the Chromium product name.

So the profile path cannot be moved by stamping `CFBundleName`, the way it cannot for
Claude, but for a different reason: it is fixed in signed framework code rather than in
JavaScript. The launcher shim still transfers unchanged, because `--user-data-dir` is a
Chromium flag before it is an Electron one, and this is Chromium.

### The `CFBundleName` trap does not apply

Claude aborts at startup when `CFBundleName` moves away from its helpers, because Electron
looks for them at `Contents/Frameworks/<CFBundleName> Helper.app`. Codex keeps its helpers
somewhere else entirely:

```
Contents/Frameworks/Codex Framework.framework/Helpers/
  Codex (Alerts).app      com.openai.codex.framework.AlertNotificationService
  Codex (GPU).app         com.openai.codex.helper
  Codex (Renderer).app    com.openai.codex.helper.renderer
  Codex (Service).app     com.openai.codex.helper
```

They are named after the *framework*, which stamping an instance never touches. The
constraint that forced `CFBundleName` to stay `"Claude"` has no equivalent here.

### What a re-signed clone loses

```
com.apple.security.app-sandbox
com.apple.security.application-groups   2DC432GLL2.com.openai.codex.notifications
                                        2DC432GLL2.com.openai.sky.CUAService
com.apple.developer.aps-environment     production
keychain-access-groups                  2DC432GLL2.*
                                        2DC432GLL2.com.openai.shared
com.apple.application-identifier        2DC432GLL2.com.openai.codex
```

Every one is Team-ID-bound and unclaimable by an ad-hoc signature. `sign-clone.sh` already
strips three of these; a Codex clone would additionally have to lose `app-sandbox`,
`application-groups` and `aps-environment`, which is a larger amputation than Claude
survives.

The keychain group is the interesting one. Codex keeps its session there:

```
"svce"="Codex Auth"            "acct"="session-response.chatgpt.com"
"svce"="Codex Safe Storage"    "acct"="Codex Key"
```

`Codex Safe Storage` is Chromium's profile encryption key — the one that decrypts `Cookies`
and `Login Data`. Losing `keychain-access-groups` means a clone cannot read either item.

For a second-account tool that is not obviously fatal: a fresh instance *should* start
signed out, and Chromium creates a Safe Storage key per profile. Whether it can create and
read its own under an ad-hoc signature, and whether the app starts at all once
`app-sandbox` is stripped, are the two things inspection cannot settle.

### It runs

Measured, not reasoned about. `scripts/probe-codex.sh` clones the app, stamps a distinct
bundle id, strips `app-sandbox`, `application-groups`, `aps-environment`,
`keychain-access-groups`, `application-identifier` and `team-identifier`, re-signs ad-hoc,
launches it, and removes itself afterwards.

**A stripped Codex clone starts, with a valid ad-hoc signature.** What survives is the set
of entitlements that were never Team-ID-bound:

```
automation.apple-events   cs.allow-jit   cs.allow-unsigned-executable-memory
cs.disable-library-validation   device.audio-input   device.camera
files.user-selected.read-write   network.client   personal-information.calendars
```

Losing the sandbox and the app group does not stop it launching, which was the open
question and the one most likely to end this.

**`--user-data-dir` is honoured.** The clone wrote a full profile to the directory it was
given rather than to `~/Library/Application Support/Codex`. The launcher shim transfers as
designed — unsurprising once the framework is known to be Chromium, and worth confirming
rather than assuming, since it is the mechanism the whole approach rests on.

Two things this does **not** establish, both of which need a signed-in account:

1. Whether the clone can create and keep its own `Codex Safe Storage` item under an ad-hoc
   signature, and so stay signed in across a restart.
2. Whether anything inside the app depends on the app group or push at runtime rather than
   at launch. Twelve seconds at a sign-in screen exercises very little.

Sparkle remains the standing hazard, and it is not hypothetical: the version recorded at
the top of this section was 26.721.41059 when it was written and 26.721.81911 by the time
the probe ran, a few hours later, on the same machine. Codex updates itself on its own
schedule, so a clone goes stale on that schedule and its self-update will fail a signature
check against an ad-hoc signature.

### What the probe found out about our own tooling

`sign-clone.sh` could not sign it at first, and the reason was ours. It resolved every
framework's version directory as `Versions/A`:

```bash
v="$fw/Versions/A"
sign_one "${v:-$fw}" ...          # the fallback can never fire — `v` is never empty
```

`A` is a convention. Apple's frameworks follow it and so does Claude's Electron Framework;
Chromium names the directory after the Chromium release, and Codex ships
`Versions/150.0.7871.128`. The fallback that was supposed to cover the difference was
unreachable, because a concatenated string is never empty — so the framework was signed at
a path that did not exist, and the flat-framework case the fallback was written for could
not have worked either. It resolves `Versions/Current` now.

The first two runs of the probe also produced a result that was not true. Cleanup sent
SIGTERM, waited two seconds and deleted the bundle regardless; Chromium does not exit that
quickly, and macOS will happily unlink a running application. That left a live process
executing from a bundle that no longer existed, which the next run's `pgrep` matched and
reported as a successful launch — and `open -a` re-activated it instead of starting a new
one, silently dropping the `--user-data-dir` under test. The probe now refuses to start if
a previous one is alive, escalates to SIGKILL, confirms the process is gone before
unlinking anything, and uses `open -n`.
