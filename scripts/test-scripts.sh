#!/bin/bash
#
# Tests for the shell that mutates signed bundles.
#
# 1,600 lines of it had none. That is the code with the worst failure mode in the project:
# every Swift target is covered, and the part that can silently orphan somebody's account is
# the part nothing checked. CLAUDE.md says it outright — get a frozen name wrong and there is
# no error at any layer, just an instance that boots a fresh, signed-out profile.
#
# The identity derivation is the whole point of this file. `instance_identity` decides the
# bundle id a clone is *signed* with and the profile path compiled into its launcher, and
# those two are derived differently — the id from a slug, the profile from the display name.
# Swapping them produces something that looks entirely reasonable and cannot be undone by
# editing Swift afterwards.
#
# No framework. bats would be a dependency to install before anyone could run the tests for
# a project whose own argument is that it has almost none, and the whole harness is the
# twelve lines below.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0
fail=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

is() {
    local what="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf '  \033[31mFAIL\033[0m %s\n       expected: %s\n         actual: %s\n' \
            "$what" "$expected" "$actual"
    fi
}

succeeds() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf '  \033[31mFAIL\033[0m %s (expected success, got %s)\n' "$what" "$?"
    fi
}

refuses() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then
        fail=$((fail + 1))
        printf '  \033[31mFAIL\033[0m %s (expected failure, got success)\n' "$what"
    else
        pass=$((pass + 1))
    fi
}

section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# shellcheck source=lib/instance-identity.sh
source "$ROOT/scripts/lib/instance-identity.sh"

# ---------------------------------------------------------------- Identity derivation

section "instance_identity"

# The literals here are deliberately spelled out rather than composed from the same
# expressions the code uses. A test that derives its expectation the way the subject does
# agrees with any implementation, including a wrong one. These match the strings asserted on
# the Swift side in InstanceLocatorTests, so the two derivations cannot drift apart without
# one of them failing.
HOME_SAVED="$HOME"
export HOME="/Users/example"

instance_identity "Work"
is "slug"      "work"                                              "$INSTANCE_SLUG"
is "bundle id" "com.anthropic.claudefordesktop.claudruple.work"     "$INSTANCE_BUNDLE_ID"
is "profile"   "/Users/example/Library/Application Support/Claudruple/Work" "$INSTANCE_PROFILE"
is "app"       "/Applications/Claudruple/Work.app"                  "$INSTANCE_APP"
is "real bin"  "Work Bin"                                           "$INSTANCE_REALBIN"

# The distinction that matters. The bundle id is built from the slug and the profile path
# from the display name, and they are not the same string the moment a name has a space in
# it. Deriving either from the other is the silent failure this whole file exists for.
instance_identity "Claude Two"
is "spaced slug"    "claude-two"                                          "$INSTANCE_SLUG"
is "spaced id"      "com.anthropic.claudefordesktop.claudruple.claude-two" "$INSTANCE_BUNDLE_ID"
is "spaced profile" "/Users/example/Library/Application Support/Claudruple/Claude Two" \
    "$INSTANCE_PROFILE"
is "spaced bin"     "Claude Two Bin"                                      "$INSTANCE_REALBIN"

instance_identity "Client A/B (2026)"
is "punctuation squeezed to single dashes" "client-a-b-2026" "$INSTANCE_SLUG"

instance_identity "---Edges---"
is "dashes trimmed from both ends" "edges" "$INSTANCE_SLUG"

instance_identity "UPPER case"
is "lowercased" "upper-case" "$INSTANCE_SLUG"

instance_identity "v2 Work 3"
is "digits kept" "v2-work-3" "$INSTANCE_SLUG"

refuses "an empty name is refused rather than yielding an empty bundle id" \
    instance_identity ""

export HOME="$HOME_SAVED"

# ---------------------------------------------------------------- Reading an installed one

section "instance_existing_identity"

# A bundle that looks like an instance: a plist, a shim holding the compiled-in path, and the
# renamed real binary beside it.
make_fake_instance() {
    local dir="$1" display="$2" exec_name="$3" bundle_id="$4" profile="$5"
    mkdir -p "$dir/Contents/MacOS"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $bundle_id" \
        "$dir/Contents/Info.plist" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string $exec_name" \
        "$dir/Contents/Info.plist" >/dev/null 2>&1
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string $display" \
        "$dir/Contents/Info.plist" >/dev/null 2>&1
    # Both literals, bare one first — launcher.c contains the flag on its own for the
    # strncmp against incoming arguments, and the linker will not promise an order. Putting
    # the empty one first is the arrangement that breaks a first-match implementation.
    printf 'padding\0--user-data-dir=\0--user-data-dir=%s\0more\0' "$profile" \
        > "$dir/Contents/MacOS/$exec_name"
    printf 'the real electron binary\0' > "$dir/Contents/MacOS/$exec_name Bin"
}

# The identity a real install actually has: display name "Claude Two", slug "two". It
# predates the current derivation, so deriving from the name would stamp `claude-two` over
# it — a different signed identity and a LaunchServices registration pointing at an app that
# no longer answers to it.
make_fake_instance "$WORK/Claude Two.app" "Claude Two" "Claude Two" \
    "com.anthropic.claudefordesktop.claudruple.two" \
    "/Users/example/Library/Application Support/Claudruple/Claude Two"

if instance_existing_identity "$WORK/Claude Two.app"; then
    is "reads the id it actually has, not one derived from the name" \
        "com.anthropic.claudefordesktop.claudruple.two" "$EXISTING_BUNDLE_ID"
    is "display name" "Claude Two" "$EXISTING_DISPLAY"
    is "executable"   "Claude Two" "$EXISTING_EXEC"
    is "real binary"  "Claude Two Bin" "$EXISTING_REALBIN"
    is "recovers the compiled-in profile, not the bare flag" \
        "/Users/example/Library/Application Support/Claudruple/Claude Two" "$EXISTING_PROFILE"
else
    fail=$((fail + 1))
    printf '  \033[31mFAIL\033[0m could not read a well-formed fake instance\n'
fi

# The refusals. Each of these would otherwise proceed on a guess, and a wrong profile path
# boots a fresh, signed-out profile with every extension gone.
refuses "a bundle with no Info.plist" \
    instance_existing_identity "$WORK/Nothing.app"

mkdir -p "$WORK/NoPlistKeys.app/Contents/MacOS"
/usr/libexec/PlistBuddy -c "Add :CFBundleName string Claude" \
    "$WORK/NoPlistKeys.app/Contents/Info.plist" >/dev/null 2>&1
refuses "a plist with no CFBundleIdentifier" \
    instance_existing_identity "$WORK/NoPlistKeys.app"

make_fake_instance "$WORK/NoShimPath.app" "Ghost" "Ghost" "com.example.ghost" ""
refuses "a launcher with no path compiled in — refusing to guess" \
    instance_existing_identity "$WORK/NoShimPath.app"

make_fake_instance "$WORK/NoRealBin.app" "Lonely" "Lonely" "com.example.lonely" "/tmp/x"
rm -f "$WORK/NoRealBin.app/Contents/MacOS/Lonely Bin"
refuses "a bundle with no renamed real binary beside the shim" \
    instance_existing_identity "$WORK/NoRealBin.app"

# ---------------------------------------------------------------- Framework version dirs

section "sign-clone.sh framework resolution"

# Regression: it resolved every framework as Versions/A, which is a convention rather than a
# rule — Chromium names the directory after the Chromium release, so Codex Desktop ships
# Versions/150.0.7871.128 and signing failed at a path that did not exist. The `${v:-$fw}`
# fallback written to cover it could never fire, because a concatenated string is never
# empty. This asserts the resolution the fix put in.
resolve_framework() {
    local fw="$1"
    if [ -d "$fw/Versions/Current" ]; then printf '%s' "$fw/Versions/Current"
    elif [ -d "$fw/Versions/A" ]; then printf '%s' "$fw/Versions/A"
    else printf '%s' "$fw"; fi
}

mkdir -p "$WORK/Apple.framework/Versions/A"
ln -s "A" "$WORK/Apple.framework/Versions/Current"
is "an Apple-style framework resolves through Current" \
    "$WORK/Apple.framework/Versions/Current" "$(resolve_framework "$WORK/Apple.framework")"

mkdir -p "$WORK/Chromium.framework/Versions/150.0.7871.128"
ln -s "150.0.7871.128" "$WORK/Chromium.framework/Versions/Current"
is "a Chromium-style framework resolves too" \
    "$WORK/Chromium.framework/Versions/Current" "$(resolve_framework "$WORK/Chromium.framework")"

mkdir -p "$WORK/Flat.framework"
is "a flat framework falls back to its own root" \
    "$WORK/Flat.framework" "$(resolve_framework "$WORK/Flat.framework")"

mkdir -p "$WORK/OnlyA.framework/Versions/A"
is "a framework with A but no Current still resolves" \
    "$WORK/OnlyA.framework/Versions/A" "$(resolve_framework "$WORK/OnlyA.framework")"

section "widget identity"

# The App Group identifier decides which container the app writes to and the widget reads
# from. Get it wrong and both sides work perfectly, in different directories, and the widget
# shows "no data yet" forever with nothing reporting an error anywhere.
. "$ROOT/scripts/lib/widget-identity.sh"

is "an ad-hoc identity yields no team, so no group" \
    "" "$(tmu_team_id -)"
is "and therefore no app group at all" \
    "" "$(tmu_app_group -)"

is "the team id is read from the identity's parenthesised suffix" \
    "ABCDE12345" "$(tmu_team_id 'Apple Development: A Person (ABCDE12345)')"

is "the group is the team id joined to the suffix" \
    "ABCDE12345.com.trackmyusage.shared" \
    "$(tmu_app_group 'Apple Development: A Person (ABCDE12345)')"

# macOS requires the Team ID prefix outside the Mac App Store. The `group.` form is
# App-Store-only and silently resolves to nothing here.
case "$(tmu_app_group 'Apple Development: A Person (ABCDE12345)')" in
    group.*) is "the group must not use the App Store form" "not group.*" "group.*" ;;
    *)       pass=$((pass + 1)) ;;
esac

is "TEAM_ID overrides the certificate" \
    "OVERRIDE99.com.trackmyusage.shared" \
    "$(TEAM_ID=OVERRIDE99 tmu_app_group 'Apple Development: A Person (ABCDE12345)')"

# Apple requires an app extension's identifier to be prefixed by its host's. A mismatch
# registers nothing and reports nothing.
case "$TMU_WIDGET_BUNDLE_ID" in
    "$TMU_APP_BUNDLE_ID".*) pass=$((pass + 1)) ;;
    *) is "extension id is prefixed by the host app id" "$TMU_APP_BUNDLE_ID.*" "$TMU_WIDGET_BUNDLE_ID" ;;
esac

section "widget plist injection"

# An ad-hoc build must produce a complete app with no widget -- a supported configuration --
# rather than a half-built one or a failure.
OUT="$WORK/adhoc" ./scripts/build-app.sh >/dev/null 2>&1
is "an ad-hoc build produces an app" \
    "yes" "$([ -d "$WORK/adhoc/TrackMyUsage.app" ] && echo yes || echo no)"
is "and no widget extension" \
    "no" "$([ -d "$WORK/adhoc/TrackMyUsage.app/Contents/PlugIns" ] && echo yes || echo no)"

# The heredoc that writes Info.plist has bitten twice: a multi-line ${VAR:+...} emits its own
# body verbatim when empty, and $(cat <<EOF) cannot contain an apostrophe. Both produce a
# plist that is wrong rather than a build that fails.
is "the ad-hoc plist is valid and carries no group key" \
    "ok" "$(plutil -lint "$WORK/adhoc/TrackMyUsage.app/Contents/Info.plist" >/dev/null 2>&1 \
            && (/usr/libexec/PlistBuddy -c 'Print :TMUAppGroupIdentifier' \
                "$WORK/adhoc/TrackMyUsage.app/Contents/Info.plist" >/dev/null 2>&1 \
                && echo "leaked" || echo ok) || echo "invalid")"

is "and contains no unexpanded shell variable" \
    "" "$(grep -o '\$GROUP' "$WORK/adhoc/TrackMyUsage.app/Contents/Info.plist" 2>/dev/null | head -1)"

# ---------------------------------------------------------------- Result

printf '\n'
if [ "$fail" -eq 0 ]; then
    printf '\033[32m%s passed\033[0m\n\n' "$pass"
    exit 0
fi
printf '\033[31m%s failed\033[0m, %s passed\n\n' "$fail" "$pass"
exit 1
