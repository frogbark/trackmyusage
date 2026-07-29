#!/bin/bash
#
# Regenerates the files the website derives from the code.
#
# The provider matrix is the load-bearing one. A hand-written table on the site would go
# stale the first time an adapter landed, and a page claiming more coverage than the binary
# has is exactly the dishonesty the project's whole pitch is against. CI runs this and fails
# if the result differs from what is committed.
#
# The wallpaper images are here for the same reason. They come out of the renderer that
# draws the real thing, seeded with fixtures and a frozen clock, so the site cannot show a
# layout the code does not produce — and a layout regression turns up as a diff here before
# it turns up on anyone's desktop.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product tmu >/dev/null
.build/release/tmu provider --json > web/providers.json
.build/release/tmu assets mark 96 > web/mark.svg
.build/release/tmu assets mark 512 > web/icon.svg

for demo in ledger board card-alert card-quiet; do
    .build/release/tmu assets wallpaper "$demo" > "web/wallpaper-$demo.svg"
done

# The social preview has to be a raster: the unfurlers do not accept SVG. Verified
# byte-deterministic for a fixed input, which is what lets check-generated.sh diff it
# without reporting staleness on every run.
.build/release/tmu assets social ledger 1200 630 > web/og.png

echo "generated: web/providers.json web/mark.svg web/icon.svg web/wallpaper-*.svg web/og.png"
