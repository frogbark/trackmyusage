#!/bin/bash
#
# Re-clone an instance from the Claude Desktop that is installed now.
#
#   ./refresh-instance.sh "Work"     # one instance
#   ./refresh-instance.sh --all      # every instance on a different build
#   ./refresh-instance.sh "Work" --force
#
# Clones are byte copies taken at a moment in time and they do not update themselves. When
# Claude updates, every instance stays on the old build and nothing says so: the app still
# launches, still signs in, and works several versions behind until something it depends on
# changes server-side. The documented remedy used to be "recreate them".
#
# This is that, without the recreating. The instance keeps its name, so it keeps the three
# things that are actually load-bearing — the bundle id it is signed and registered under,
# the profile directory compiled into its shim, and its place in LaunchServices. The profile
# lives outside the bundle and is never touched, which is the whole reason this is safe.
#
# Design notes:
#
#  * The new bundle is staged beside the old one and only swapped in once it is signed and
#    verified. A failure halfway through leaves the working instance exactly where it was,
#    rather than a hole where somebody's account used to be.
#
#  * Staging happens inside the destination directory on purpose: same filesystem, so the
#    clone is an APFS clonefile rather than a real copy, and the swap is a rename.
#
#  * It refuses to touch a running instance. Replacing a bundle out from under a live
#    Electron process gets you a half-updated app and, if it writes on exit, a damaged
#    profile. `apply` refuses for the same reason.
#
#  * The old bundle is kept until the new one is in place and registered, then removed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${SRC:-/Applications/Claude.app}"
DEST_DIR="${DEST_DIR:-/Applications/Claudruple}"
IDENTITY="${IDENTITY:--}"
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# shellcheck source=lib/instance-identity.sh
source "$ROOT/scripts/lib/instance-identity.sh"
# shellcheck source=lib/instance-icon.sh
source "$ROOT/scripts/lib/instance-icon.sh"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
ok()   { printf '    \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '    \033[33m!\033[0m %s\n' "$1"; }

version_of() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
        "$1/Contents/Info.plist" 2>/dev/null || true
}

usage() {
    echo "usage: $0 <instance-name> [--force]" >&2
    echo "       $0 --all [--force]" >&2
    exit 1
}

# ---------------------------------------------------------------- Arguments

TARGET=""
ALL=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --all)   ALL=1 ;;
        --force) FORCE=1 ;;
        -*)      usage ;;
        *)       [ -n "$TARGET" ] && usage; TARGET="$arg" ;;
    esac
done
[ "$ALL" = 1 ] || [ -n "$TARGET" ] || usage
[ "$ALL" = 1 ] && [ -n "$TARGET" ] && usage

[ -d "$SRC" ] || { echo "Claude Desktop is not installed at $SRC" >&2; exit 1; }
INSTALLED=$(version_of "$SRC")
[ -n "$INSTALLED" ] || { echo "could not read a version from $SRC" >&2; exit 1; }

# ---------------------------------------------------------------- One instance

refresh_one() {
    local name="$1"
    local app="$DEST_DIR/$name.app"

    say "$name"

    [ -d "$app" ] || { echo "    no such instance: $app" >&2; return 1; }

    # Read the identity this bundle already has. Never derive it — see
    # instance_existing_identity for the install that makes the difference concrete.
    instance_existing_identity "$app" || return 1

    local current
    current=$(version_of "$app")
    if [ "$current" = "$INSTALLED" ] && [ "$FORCE" = 0 ]; then
        ok "already on $INSTALLED — nothing to do"
        SKIPPED=$((SKIPPED + 1))
        return 0
    fi
    ok "${current:-unknown} -> $INSTALLED"
    ok "keeping $EXISTING_BUNDLE_ID"

    if instance_is_running "$EXISTING_EXEC"; then
        echo "    $name is running. Quit it first — replacing a live bundle" >&2
        echo "    half-updates the app and can damage the profile on exit." >&2
        return 1
    fi

    # The profile is the thing that must survive. It is outside the bundle, so nothing below
    # touches it, but say so out loud: it is the only part that cannot be rebuilt.
    ok "profile kept at $EXISTING_PROFILE"

    local staged="$DEST_DIR/.$name.refresh.app"
    local retired="$DEST_DIR/.$name.retired.app"
    rm -rf "$staged" "$retired"

    # Anything that fails from here until the swap leaves the live bundle untouched.
    # shellcheck disable=SC2317
    cleanup_staged() { rm -rf "$staged"; }
    trap cleanup_staged RETURN

    printf '    cloning… '
    cp -Rpc "$SRC" "$staged"
    codesign --verify --deep --strict "$staged" 2>/dev/null \
        || { echo; echo "    clone is not byte-faithful; aborting" >&2; return 1; }
    echo "done"

    # Every value below is the one already on disk, copied across unchanged. This step
    # restores an identity; it does not assign one.
    local pl="$staged/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $EXISTING_BUNDLE_ID" "$pl"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName $EXISTING_DISPLAY" "$pl"
    /usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $EXISTING_EXEC" "$pl"
    # CFBundleName stays "Claude" — Electron finds its helpers by it.
    rm -f "$staged/Contents/embedded.provisionprofile"
    ok "$EXISTING_BUNDLE_ID"

    # The shim is recompiled with the profile path read out of the old shim, so the
    # refreshed instance opens the same profile it did a minute ago. Deriving it instead
    # would sign the account out and take every extension with it.
    mv "$staged/Contents/MacOS/Claude" "$staged/Contents/MacOS/$EXISTING_REALBIN"
    clang -arch arm64 -O2 -Wall -Wextra \
        -DREAL_BINARY="\"$EXISTING_REALBIN\"" -DUSER_DATA_DIR="\"$EXISTING_PROFILE\"" \
        -o "$staged/Contents/MacOS/$EXISTING_EXEC" "$ROOT/native/launcher/launcher.c"
    ok "shim -> $EXISTING_PROFILE"

    # Re-badged every time, because the staged bundle is a fresh clone of Claude and so
    # carries Claude's icon again. Without this, refreshing an instance would silently take
    # its colour away — and the first symptom would be two identical icons in the Dock.
    instance_apply_icon "$staged" "$EXISTING_DISPLAY" "$ROOT"

    DST="$staged" SRC="$SRC" IDENTITY="$IDENTITY" "$ROOT/scripts/sign-clone.sh" 2>&1 \
        | grep -E 'RESULT|FAILED' | sed 's/^ */    /'
    codesign --verify --deep --strict "$staged" 2>/dev/null \
        || { echo "    refreshed bundle does not verify; leaving the old one in place" >&2; return 1; }
    ok "signed and verified"

    # ---- The swap. Two renames on one filesystem, old bundle retained until the end.
    trap - RETURN
    mv "$app" "$retired"
    if ! mv "$staged" "$app"; then
        echo "    swap failed; restoring the previous bundle" >&2
        mv "$retired" "$app"
        rm -rf "$staged"
        return 1
    fi

    xattr -dr com.apple.quarantine "$app" 2>/dev/null || true
    "$LSREG" -f "$app"
    ok "registered, quarantine cleared"

    rm -rf "$retired"
    ok "now on $INSTALLED"
    REFRESHED=$((REFRESHED + 1))
}

# ---------------------------------------------------------------- Targets

say "Preflight"
ok "installed Claude: $INSTALLED"

names=()
if [ "$ALL" = 1 ]; then
    shopt -s nullglob
    for app in "$DEST_DIR"/*.app; do
        base=$(basename "$app" .app)
        # Skip our own staging and retirement bundles, which are dotfiles.
        [ "${base:0:1}" = "." ] && continue
        if [ "$FORCE" = 1 ] || [ "$(version_of "$app")" != "$INSTALLED" ]; then
            names+=("$base")
        fi
    done
    shopt -u nullglob
    if [ ${#names[@]} -eq 0 ]; then
        ok "every instance is already on $INSTALLED"
        exit 0
    fi
    ok "to refresh: ${names[*]}"
else
    names=("$TARGET")
fi

failed=()
REFRESHED=0
SKIPPED=0
for name in "${names[@]}"; do
    refresh_one "$name" || failed+=("$name")
done

# Counted rather than assumed. Reporting "refreshed 1 instance" after skipping the only one
# named is a small lie, and this project's whole argument is that its numbers do not tell
# them — a summary that cannot distinguish "did the work" from "found nothing to do" is the
# same defect as a wallpaper drawing a missing reading as zero.
summary="Refreshed $REFRESHED to $INSTALLED"
[ "$SKIPPED" -gt 0 ] && summary="$summary · $SKIPPED already current"
[ ${#failed[@]} -gt 0 ] && summary="$summary · ${#failed[@]} failed"

if [ ${#failed[@]} -gt 0 ]; then
    printf '\n\033[1m%s: %s\033[0m\n\n' "$summary" "${failed[*]}"
    exit 1
fi

printf '\n\033[1m%s\033[0m\n\n' "$summary"
