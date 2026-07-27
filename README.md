# Claudruple

Run multiple Claude Desktop accounts on one Mac — properly.

Each instance gets its own macOS app identity, its own profile, and its own place in the
Dock. A small broker makes sure sign-in and MCP OAuth callbacks reach the account that
asked for them, instead of whichever instance happened to launch last.

> **Status: early.** Phase 0 (instance creation + deep-link routing) works and is in daily
> use. The usage dashboard, config sync, and GUI described in [`docs/roadmap.md`](docs/roadmap.md)
> are not built yet.

Claudruple never bundles or redistributes Claude Desktop. It clones the copy already
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

## What Claudruple does instead

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
git clone <this repo> && cd claudruple

# Build and install the deep-link broker (once)
./scripts/build-link.sh
cp -Rp "build/Claudruple Link.app" /Applications/Claudruple/
./scripts/install-link-agent.sh

# Create an instance
./scripts/create-instance.sh "Work" --launch
```

Then sign into the new window with your second account. Remove one with:

```bash
./scripts/remove-instance.sh "Work"              # keeps the profile
./scripts/remove-instance.sh "Work" --purge-data # removes it too
```

### Scripts

| Script | Purpose |
|---|---|
| `create-instance.sh` | Clone, stamp, shim, sign, register a new instance |
| `remove-instance.sh` | Remove an instance; keeps the profile unless `--purge-data` |
| `sign-clone.sh` | Inside-out re-signing (used by the above) |
| `build-link.sh` | Build the deep-link broker |
| `install-link-agent.sh` | Register the broker as a login agent |
| `finish-repair.sh` | One-off: migrate a Parall install into Claudruple |
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
- **Clones do not auto-update.** When Claude updates, recreate them (profiles are unaffected).
- **`safeStorage` is shared.** Electron derives the keychain item from `app.getName()`, which
  is hardcoded, so all instances share `Claude Safe Storage`. Profiles remain separate; the
  encryption key does not. On the upside, this is why migrating a profile between instances
  does not force a re-login.
- Apple Silicon only for now (the shim is built `arm64`).

## License

Apache-2.0. See [`LICENSE`](LICENSE).
