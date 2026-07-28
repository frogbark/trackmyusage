#!/bin/bash
#
# Regenerates the files the website derives from the code.
#
# The provider matrix is the load-bearing one. A hand-written table on the site would go
# stale the first time an adapter landed, and a page claiming more coverage than the binary
# has is exactly the dishonesty the project's whole pitch is against. CI runs this and fails
# if the result differs from what is committed.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product tmu >/dev/null
.build/release/tmu provider --json > web/providers.json
.build/release/tmu assets mark 96 > web/mark.svg
.build/release/tmu assets mark 512 > web/icon.svg

echo "generated: web/providers.json web/mark.svg web/icon.svg"
