#!/bin/bash
# Where the App Group identifier comes from.
#
# Sourced by build-app.sh, build-widget.sh and check-widget.sh so all three agree; sourced by
# test-scripts.sh so the derivation is tested rather than assumed.
#
# The Team ID is not in this repository and must not be. It is part of the App Group
# identifier, it differs per developer, and hard-coding one would mean every contributor
# builds an app whose widget silently belongs to somebody else's team.

# The group's suffix. The Team ID is prepended at build time.
TMU_GROUP_SUFFIX="com.trackmyusage.shared"

# Bundle identifiers. The extension's must be prefixed by the host app's — macOS requires it
# of app extensions, and a mismatch registers nothing without saying why.
TMU_APP_BUNDLE_ID="com.trackmyusage.app"
TMU_WIDGET_BUNDLE_ID="com.trackmyusage.app.widgets"

# Derive the Team ID: $TEAM_ID wins, otherwise read the OU field out of the signing identity.
#
# `codesign` writes the certificate's Organizational Unit into the OU field, and for Apple
# developer certificates that field *is* the Team ID. Parsing it means `IDENTITY` is the only
# thing a developer has to set.
#
# Echoes the Team ID, or nothing at all when the identity is ad-hoc or unreadable. Callers
# must treat empty as "no App Group in this build" rather than as an error: an ad-hoc build
# is a supported configuration that produces a working app without a widget.
tmu_team_id() {
    local identity="${1:--}"
    if [ -n "${TEAM_ID:-}" ]; then
        printf '%s' "$TEAM_ID"
        return 0
    fi
    # Ad-hoc signing carries no certificate, so there is no team to find.
    [ "$identity" = "-" ] && return 0

    # The identity string itself usually carries it: "Apple Development: Name (TEAMID)".
    local from_name
    from_name=$(printf '%s' "$identity" | sed -n 's/.*(\([A-Z0-9]\{10\}\))$/\1/p')
    if [ -n "$from_name" ]; then
        printf '%s' "$from_name"
        return 0
    fi

    # Otherwise ask the keychain for the certificate and read its OU.
    security find-certificate -c "$identity" -p 2>/dev/null \
        | openssl x509 -noout -subject 2>/dev/null \
        | sed -n 's/.*OU[ ]*=[ ]*\([A-Z0-9]\{10\}\).*/\1/p'
}

# The full App Group identifier, or empty when there is no team.
#
# macOS requires the Team ID prefix for apps outside the Mac App Store; the `group.` form is
# Mac-App-Store-only and is rejected here.
tmu_app_group() {
    local team
    team=$(tmu_team_id "${1:--}")
    [ -z "$team" ] && return 0
    printf '%s.%s' "$team" "$TMU_GROUP_SUFFIX"
}
