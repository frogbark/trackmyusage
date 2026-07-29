#!/bin/bash
#
# Fails if a generated file is stale.
#
# This single check is worth more than the rest of the website work: it is what makes the
# provider counts on trackmyusage.dev structurally unable to overstate what ships.
set -euo pipefail
cd "$(dirname "$0")/.."

# web/og.png is deliberately not compared.
#
# It is the one generated file that is a raster, and rasterising is the only step that
# depends on the platform: the same SVG encodes to 49099 bytes on one Mac and 49102 on
# another, because CoreGraphics and the installed fonts are not part of this repository.
# It is reproducible on a single machine and was verified so, which is precisely the check
# that cannot detect this — and diffing it here would fail every build run somewhere other
# than wherever it was last committed from, for a reason no commit could fix.
#
# Nothing goes unnoticed as a result. og.png is rendered from the same DemoSnapshots as the
# SVGs, and those are pure text and are compared, so a layout change still fails this check
# — and whoever reruns generate-web.sh to fix it rewrites og.png in the same command.
GENERATED_SCOPE=(web/ ':(exclude)web/og.png')

./scripts/generate-web.sh >/dev/null
if ! git diff --quiet -- "${GENERATED_SCOPE[@]}"; then
    echo "Generated web files are stale. Run ./scripts/generate-web.sh and commit the result:"
    echo ""
    git --no-pager diff --stat -- "${GENERATED_SCOPE[@]}"
    exit 1
fi
echo "generated files: up to date"
