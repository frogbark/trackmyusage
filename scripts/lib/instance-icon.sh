# shellcheck shell=bash
#
# The coloured badge that tells one instance from another in the Dock.
#
# Clones are byte copies and inherit the same icon, so several identical tiles sit in the
# Dock, the app switcher and Mission Control, and the only way to find out which account a
# window belongs to is to click it. The badge answers that before you click.
#
# It is drawn over the icon already inside the clone, on the machine that made the clone.
# Nothing is redistributed and /Applications/Claude.app is never touched — the same footing
# as stamping the plist and compiling the shim.
#
# Best-effort by design: a missing toolchain leaves an unbadged instance, which is exactly
# what you had before. Failing instance creation over an icon would be a poor trade.

# instance_icon_tool
#
# Echoes a path to a usable `tmu`, building one if that is quick. Empty if none can be had.
instance_icon_tool() {
    local root="${1:?instance_icon_tool needs the repo root}"

    for candidate in "$root/.build/release/tmu" "$root/.build/debug/tmu"; do
        [ -x "$candidate" ] && { printf '%s' "$candidate"; return 0; }
    done

    # Nothing built yet. Try once, quietly — on a fresh checkout this is the common case and
    # it is a few seconds, but it must not be fatal on a machine with no Swift toolchain.
    if command -v swift >/dev/null 2>&1 \
        && (cd "$root" && swift build -c release --product tmu >/dev/null 2>&1); then
        [ -x "$root/.build/release/tmu" ] && { printf '%s' "$root/.build/release/tmu"; return 0; }
    fi
    return 1
}

# instance_apply_icon <app-path> <display-name> <repo-root>
#
# Replaces the clone's icon with a badged copy of itself. Must run before signing: the icns
# is inside the bundle, so changing it afterwards invalidates the signature.
instance_apply_icon() {
    local app="${1:?}" name="${2:?}" root="${3:?}"
    local resources="$app/Contents/Resources"

    local tool
    tool=$(instance_icon_tool "$root") || {
        echo "    ! no tmu binary and none could be built; leaving the icon unbadged" >&2
        return 0
    }

    # Whatever the bundle actually points at, rather than a hardcoded name. Claude ships
    # `electron.icns` today; a rename upstream would otherwise badge a file nothing reads.
    local icon_file
    icon_file=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' \
        "$app/Contents/Info.plist" 2>/dev/null) || icon_file="electron"
    [ "${icon_file##*.}" = "icns" ] || icon_file="$icon_file.icns"

    local source="$resources/$icon_file"
    [ -f "$source" ] || {
        echo "    ! $icon_file not found in the bundle; leaving the icon unbadged" >&2
        return 0
    }

    local work
    work=$(mktemp -d) || return 0

    # Cleanup is written out at each exit rather than hung on `trap ... RETURN`. A RETURN
    # trap is bash-only and silently does nothing elsewhere — sourcing this into zsh to test
    # it reported "undefined signal: RETURN" and leaked the directory. The scripts that use
    # this are bash, so the trap would have worked in production and only ever misled
    # whoever was reading it.
    if ! "$tool" assets instance-icon "$name" "$source" "$work/instance.iconset" \
        >/dev/null 2>&1; then
        rm -rf "$work"
        echo "    ! could not render the badge; leaving the icon unbadged" >&2
        return 0
    fi

    if ! iconutil -c icns "$work/instance.iconset" -o "$work/instance.icns" >/dev/null 2>&1; then
        rm -rf "$work"
        echo "    ! iconutil refused the iconset; leaving the icon unbadged" >&2
        return 0
    fi

    # Overwrite in place, so CFBundleIconFile keeps pointing at a file that exists. Writing
    # a second icns and repointing the plist would leave the original inside the bundle for
    # no reason, and every clone carries a 1 MB copy of it already.
    if cp "$work/instance.icns" "$source"; then
        ok "icon badged for \"$name\""
    else
        echo "    ! could not replace the icon; leaving it unbadged" >&2
    fi
    rm -rf "$work"
}
