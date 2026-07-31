#!/bin/bash
#
# Regenerates the files the website derives from the code.
#
# The provider matrix is the load-bearing one. A hand-written table on the site would go
# stale the first time an adapter landed, and a page claiming more coverage than the binary
# has is exactly the dishonesty the project's whole pitch is against. CI runs this and fails
# if the result differs from what is committed.
#
# The widget images are here for the same reason. They come out of the code that draws the
# real widget, seeded with fixtures and a frozen clock, so the site cannot show a layout the
# binary does not produce.
#
# They are rasters, though, and rasters cannot be byte-compared — see check-generated.sh.
# web/widgets.json is what carries that guarantee now: the same view models these images
# draw, as text, diffable. It is the successor to the wallpaper SVGs, which were readable and
# comparable for exactly the same reason.
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

# The text artifact. This is the one that makes a layout regression fail CI.
.build/release/tmu assets widget-models > web/widgets.json

# Four images, matching the four the wallpaper shipped: every family of the interesting case,
# plus the calm state, which is what the widget looks like almost all of the time.
for family in small medium large; do
    .build/release/tmu assets widget "$family" busy > "web/widget-$family-busy.png"
done
.build/release/tmu assets widget medium calm > web/widget-medium-calm.png

# The social preview, on the canvas the unfurlers crop to.
.build/release/tmu assets social busy 1200 630 > web/og.png

echo "generated: web/providers.json web/mark.svg web/icon.svg web/widgets.json web/widget-*.png web/og.png"
