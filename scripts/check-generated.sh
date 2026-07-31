#!/bin/bash
#
# Fails if a generated file is stale.
#
# This single check is worth more than the rest of the website work: it is what makes the
# provider counts on trackmyusage.dev structurally unable to overstate what ships.
set -euo pipefail
cd "$(dirname "$0")/.."

# The PNGs are deliberately not compared.
#
# They are the generated files that are rasters, and rasterising is the only step that depends
# on the platform: the same view encodes to a slightly different byte count on another Mac,
# because CoreGraphics and the installed fonts are not part of this repository. Diffing them
# here would fail every build run somewhere other than wherever they were last committed from,
# for a reason no commit could fix.
#
# Nothing goes unnoticed as a result, and this is the load-bearing part. web/widgets.json holds
# the view models those images are drawn from — every family of every demo case, as text — and
# it *is* compared. A layout change alters the model before it alters a pixel, so a regression
# still fails this check, and whoever reruns generate-web.sh to fix it rewrites the PNGs in the
# same command.
#
# That file is the successor to the wallpaper SVGs, which did this job when the renderer emitted
# text. It only works because CanonicalJSON sorts its keys: a plain JSONEncoder orders them by a
# per-process hash seed, so the file would differ between the machine that committed it and the
# runner that regenerates it — and the natural response to that would be to exclude it here,
# which would quietly delete the guarantee this whole comment is about.
GENERATED_SCOPE=(web/ ':(exclude)web/*.png')

./scripts/generate-web.sh >/dev/null
if ! git diff --quiet -- "${GENERATED_SCOPE[@]}"; then
    echo "Generated web files are stale. Run ./scripts/generate-web.sh and commit the result:"
    echo ""
    git --no-pager diff --stat -- "${GENERATED_SCOPE[@]}"
    exit 1
fi
echo "generated files: up to date"
