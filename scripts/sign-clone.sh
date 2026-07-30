#!/bin/bash
# Inside-out re-sign of a cloned Claude.app.
# Entitlements are lifted per-component from the pristine primary, then stripped of
# Team-ID-bound keys that cannot be claimed under a different signing identity.
set -uo pipefail

SRC="${SRC:-/Applications/Claude.app}"
DST="${DST:?set DST to the clone path}"
IDENTITY="${IDENTITY:--}"          # '-' = ad-hoc
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Overridable, because Claude and Codex need different amputations. Claude survives losing
# these three; Codex additionally carries app-sandbox, application-groups and
# aps-environment, all Team-ID-bound and unclaimable by an ad-hoc signature. Rather than a
# second copy of this script with a longer list, the list is an input.
STRIP_KEYS="${STRIP_KEYS:-com.apple.application-identifier com.apple.developer.team-identifier keychain-access-groups}"

fail=0
note() { printf '  %-58s %s\n' "$1" "$2"; }

# Emit filtered entitlements for a component; echoes path, or empty if none.
# Ad-hoc code carries no Team ID, and hardened-runtime library validation only admits
# libraries whose Team ID matches the loader's (or Apple's). Every framework load then
# fails with "code signature" in dyld. Disabling library validation is the standard
# remedy -- Anthropic already ships it on Claude Helper (Plugin).app. A real Developer ID
# signature makes Team IDs match throughout, so this is injected ONLY for ad-hoc.
if [ "$IDENTITY" = "-" ]; then ADHOC=1; else ADHOC=0; fi

ents_for() {
  local src_component="$1" out="$2"
  codesign -d --entitlements :- "$src_component" 2>/dev/null > "$WORK/raw.plist" || return 1
  [ -s "$WORK/raw.plist" ] || return 1
  STRIP="$STRIP_KEYS" ADHOC="$ADHOC" python3 - "$WORK/raw.plist" "$out" <<'PY' 2>/dev/null || return 1
import plistlib,sys,os
raw,out=sys.argv[1],sys.argv[2]
try: d=plistlib.load(open(raw,'rb'))
except Exception: sys.exit(1)
if not isinstance(d,dict) or not d: sys.exit(1)
strip=set(os.environ['STRIP'].split())
d={k:v for k,v in d.items() if k not in strip}
if os.environ.get('ADHOC')=='1':
    d['com.apple.security.cs.disable-library-validation']=True
plistlib.dump(d, open(out,'wb'))
PY
  [ -s "$out" ]
}

sign_one() {
  local target="$1" src_component="$2" label="$3"
  local entfile="$WORK/ent.plist"; rm -f "$entfile"
  local args=(--force --sign "$IDENTITY" --options runtime --timestamp=none)
  if [ -n "$src_component" ] && ents_for "$src_component" "$entfile"; then
    args+=(--entitlements "$entfile")
  fi
  if codesign "${args[@]}" "$target" 2>"$WORK/err"; then
    note "$label" "signed"
  else
    note "$label" "FAILED: $(tr -d '\n' < "$WORK/err" | cut -c1-90)"
    fail=1
  fi
}

echo "=== 1. loose Mach-O inside app.asar.unpacked ==="
while IFS= read -r f; do
  sign_one "$f" "" "$(basename "$f")"
done < <(find "$DST/Contents/Resources/app.asar.unpacked" \
          \( -name '*.node' -o -name '*.dylib' -o -name '*.so' \) 2>/dev/null | sort)

echo "=== 2. framework internals (libraries, then helpers) ==="
while IFS= read -r f; do
  sign_one "$f" "" "${f#"$DST/Contents/Frameworks/"}"
done < <(find "$DST/Contents/Frameworks" -type f \
          \( -path '*/Libraries/*' -o -path '*/Helpers/*' \) -perm -u+x 2>/dev/null | sort -r)

echo "=== 3. nested .app bundles (helpers) ==="
for app in "$DST/Contents/Frameworks/"*.app "$DST/Contents/Helpers/"*.app; do
  [ -d "$app" ] || continue
  rel="${app#"$DST/Contents/"}"
  sign_one "$app" "$SRC/Contents/$rel" "$(basename "$app")"
done

echo "=== 4. loose helper executables ==="
for f in "$DST/Contents/Helpers/"*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  sign_one "$f" "$SRC/Contents/Helpers/$(basename "$f")" "$(basename "$f")"
done

echo "=== 4b. extra Mach-O in Contents/MacOS (the real Electron binary behind the shim) ==="
# CFBundleExecutable is signed as part of the outer bundle; any *sibling* binary is
# nested code and must be signed standalone first. It also needs the full entitlement
# set in its own right -- execv replaces the process image, so the entitlements that
# take effect are the ones on the binary actually executed, not on the shim.
MAIN_EXEC="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$DST/Contents/Info.plist" 2>/dev/null)"
for f in "$DST/Contents/MacOS/"*; do
  [ -f "$f" ] && [ -x "$f" ] || continue
  [ "$(basename "$f")" = "$MAIN_EXEC" ] && continue
  sign_one "$f" "$SRC" "$(basename "$f")"
done

echo "=== 5. frameworks (versioned bundle roots) ==="
# A versioned framework is signed at its version directory, not at the symlinked top
# level. Which directory that is has to be resolved, not assumed: "A" is a convention and
# Apple's own frameworks follow it, but Chromium-derived ones name it after the Chromium
# release — Codex Desktop ships Versions/150.0.7871.128. This previously read
#
#     v="$fw/Versions/A"; sign_one "${v:-$fw}" ...
#
# where the fallback was unreachable, because `v` is a concatenated string and so never
# empty. Anything without a Versions/A was signed at a path that did not exist and failed,
# and the flat-framework case the fallback was written for could not happen.
for fw in "$DST/Contents/Frameworks/"*.framework; do
  [ -d "$fw" ] || continue
  target="$fw"
  if [ -d "$fw/Versions/Current" ]; then
    target="$fw/Versions/Current"
  elif [ -d "$fw/Versions/A" ]; then
    target="$fw/Versions/A"
  fi
  sign_one "$target" "" "$(basename "$fw")"
done

echo "=== 6. outer bundle ==="
sign_one "$DST" "$SRC" "$(basename "$DST")"

echo
echo "=== verification ==="
if codesign --verify --deep --strict --verbose=2 "$DST" 2>&1 | sed 's/^/  /'; then
  echo "  RESULT: signature valid"
else
  echo "  RESULT: signature INVALID"; fail=1
fi
echo
echo "=== identity ==="
codesign -dv --verbose=2 "$DST" 2>&1 | grep -E 'Identifier|Format|CodeDirectory|Signature|TeamIdentifier|Runtime' | sed 's/^/  /'
echo
echo "=== effective entitlements on the clone ==="
codesign -d --entitlements :- "$DST" 2>/dev/null | plutil -convert xml1 -o - - 2>/dev/null \
  | grep -oE '<key>[^<]+</key>' | sed 's/<[^>]*>//g;s/^/  /'

exit $fail
