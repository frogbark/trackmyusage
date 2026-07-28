#!/bin/bash
#
# Fails if a generated file is stale.
#
# This single check is worth more than the rest of the website work: it is what makes the
# provider counts on trackmyusage.dev structurally unable to overstate what ships.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/generate-web.sh >/dev/null
if ! git diff --quiet -- web/; then
    echo "Generated web files are stale. Run ./scripts/generate-web.sh and commit the result:"
    echo ""
    git --no-pager diff --stat -- web/
    exit 1
fi
echo "generated files: up to date"
