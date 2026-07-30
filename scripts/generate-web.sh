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

# No TZ pin here any more. It used to need one: Format.time read TimeZone.current, so the
# same frozen instant drew 20:33 on a laptop and 03:33 on a UTC runner and the committed
# images disagreed with the ones CI produced. The zone is an input to the renderer now, and
# DemoSnapshots states its own — so these are reproducible wherever they are generated,
# which is what "rendering is a pure function of its inputs" was always supposed to mean.

swift build -c release --product tmu >/dev/null
.build/release/tmu provider --json > web/providers.json
.build/release/tmu assets mark 96 > web/mark.svg
.build/release/tmu assets mark 512 > web/icon.svg

for demo in ledger board card-alert card-quiet; do
    .build/release/tmu assets wallpaper "$demo" > "web/wallpaper-$demo.svg"
done

# The social preview has to be a raster: the unfurlers do not accept SVG. It is
# byte-identical run to run on one machine, and not between two — CoreGraphics and the
# installed fonts decide the encoding, and neither is in this repository. check-generated.sh
# compares every generated file except this one, and says why.
.build/release/tmu assets social ledger 1200 630 > web/og.png

echo "generated: web/providers.json web/mark.svg web/icon.svg web/wallpaper-*.svg web/og.png"
