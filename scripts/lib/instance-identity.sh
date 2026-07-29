# shellcheck shell=bash
#
# One definition of an instance's on-disk identity, derived from its display name.
#
# This exists because three scripts need the same five strings and used to each work them
# out themselves. Every one of those strings is load-bearing in a way that fails silently:
# the bundle id is what the clone is *signed* with and registered under, and the profile
# path is compiled into the launcher shim as -DUSER_DATA_DIR at creation time and cannot be
# changed afterwards by editing anything. Two scripts deriving them a character apart do not
# produce an error — they produce an instance that boots a fresh, signed-out profile, or one
# LaunchServices no longer recognises.
#
# refresh-instance.sh is what made this urgent. It re-clones a bundle *in place*, so it has
# to reproduce the identity the instance already has, exactly. Deriving that independently
# would be the rebrand's mistake a second time, with the same symptom: nothing about the
# diff would look wrong.
#
# Keep in lockstep with InstanceLocator.profileURL and LegacyNames on the Swift side. See
# Sources/TMUKit/LegacyNames.swift for why none of these names can be modernised.

# instance_identity <display-name>
#
# Sets INSTANCE_{NAME,SLUG,DIR,APP,BUNDLE_ID,PROFILE,REALBIN}.
instance_identity() {
    local name="${1:-}"
    [ -n "$name" ] || { echo "instance_identity: needs a name" >&2; return 1; }

    INSTANCE_NAME="$name"

    # Lowercased, non-alphanumerics squeezed to single dashes, dashes trimmed off both ends.
    INSTANCE_SLUG=$(
        printf '%s' "$name" \
            | tr '[:upper:]' '[:lower:]' \
            | tr -cs 'a-z0-9' '-' \
            | sed 's/^-//;s/-$//'
    )

    INSTANCE_DIR="${DEST_DIR:-/Applications/Claudruple}"
    INSTANCE_APP="$INSTANCE_DIR/$name.app"
    INSTANCE_BUNDLE_ID="com.anthropic.claudefordesktop.claudruple.$INSTANCE_SLUG"
    INSTANCE_PROFILE="$HOME/Library/Application Support/Claudruple/$name"

    # The real Electron binary, renamed so the shim can take its place at the name
    # CFBundleExecutable points to.
    INSTANCE_REALBIN="$name Bin"
}

# instance_existing_identity <app-path>
#
# Reads the identity an installed instance actually has. Sets
# EXISTING_{BUNDLE_ID,DISPLAY,EXEC,REALBIN,PROFILE}. Returns non-zero if anything
# load-bearing cannot be read.
#
# Use this, never instance_identity, when modifying a bundle that already exists.
#
# The two are not interchangeable and a real install proves it. One clone has
# CFBundleDisplayName "Claude Two" and bundle id com.anthropic.claudefordesktop.claudruple.two
# — the slug does not follow the display name, because the instance predates the current
# derivation. Deriving on refresh would have stamped
# com.anthropic.claudefordesktop.claudruple.claude-two over it: a different id, so a different
# signed identity and a LaunchServices registration pointing at an app that no longer answers
# to it. Nothing would have reported an error.
#
# instance_identity remains correct for *creating* an instance, where there is no existing
# identity and the name is all there is.
instance_existing_identity() {
    local app="${1:-}"
    local pl="$app/Contents/Info.plist"
    [ -f "$pl" ] || { echo "no Info.plist in $app" >&2; return 1; }

    EXISTING_BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$pl" 2>/dev/null) \
        || { echo "$app has no CFBundleIdentifier" >&2; return 1; }
    EXISTING_EXEC=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$pl" 2>/dev/null) \
        || { echo "$app has no CFBundleExecutable" >&2; return 1; }
    EXISTING_DISPLAY=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' "$pl" 2>/dev/null \
        || basename "$app" .app)
    EXISTING_REALBIN="$EXISTING_EXEC Bin"

    [ -f "$app/Contents/MacOS/$EXISTING_REALBIN" ] \
        || { echo "$app has no '$EXISTING_REALBIN' beside its shim" >&2; return 1; }

    # The profile path only exists as a string compiled into the shim: launcher.c builds it
    # as `FLAG USER_DATA_DIR`, one literal, so it survives in the binary verbatim. There is
    # no other record of it anywhere on disk.
    #
    # Two strings match, not one. The shim also compares incoming arguments against the bare
    # flag, so `--user-data-dir=` is in there on its own, and the linker is under no
    # obligation to order them. Taking the first match yields the empty one about half the
    # time — which is why this insists on at least one character after the `=` rather than
    # trusting position.
    EXISTING_PROFILE=$(
        strings "$app/Contents/MacOS/$EXISTING_EXEC" 2>/dev/null \
            | sed -n 's/^--user-data-dir=\(..*\)$/\1/p' | head -1
    )
    [ -n "$EXISTING_PROFILE" ] || {
        echo "could not recover the profile path compiled into $app" >&2
        echo "refusing to guess: a wrong one boots a fresh, signed-out profile" >&2
        return 1
    }
}

# instance_is_running <executable-name>
#
# True while the instance's Electron process is up. Matched on the renamed real binary
# rather than on "Claude", which would also match the primary and every other clone — and
# refusing to refresh an instance because a different one is open would be its own bug.
instance_is_running() {
    local exec_name="${1:-}"
    pgrep -f "$exec_name Bin" >/dev/null 2>&1
}
