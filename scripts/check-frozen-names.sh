#!/bin/bash
#
# Fails if "claudruple" appears anywhere except as one of the frozen strings.
#
# The point is not to eliminate the old name — three constants and a keychain service must
# keep it forever, because they are baked into things already on disk. The point is that
# every remaining occurrence is *deliberate*. A new one is either a frozen name being used
# without going through LegacyNames, or a rename somebody missed; both want a human.
#
# See Sources/TMUKit/LegacyNames.swift for why each of these cannot change.
#
# The migration code is exempt wholesale. Naming the old paths, labels and bundle names is
# precisely its job — it is the one place that has to know what the world looked like before
# the rename — so scanning it produces forty findings and zero signal.
set -euo pipefail
cd "$(dirname "$0")/.."

# The only permitted forms. Anything else containing "claudruple" is a finding.
ALLOWED='com\.anthropic\.claudefordesktop\.claudruple\.|/Applications/Claudruple|Application Support/Claudruple|\$SUPPORT/Claudruple|/Caches/Claudruple|com\.claudruple\.usage|Claudruple era|"Claudruple"|Claudruple ->|the Claudruple|called Claudruple'

# Documentation is allowed to discuss the old name in prose; code is not.
# --untracked, because without it this check cannot see a file that has not been added yet
# — which is precisely when a new violation is introduced. It passed locally and failed in
# CI on the commit that added scripts/lib/instance-identity.sh: the gate ran before `git
# add`, so `git grep` searched a tree the new file was not in. A guard that only inspects
# what is already committed reports on the previous commit, not the one being written.
findings=$(
    git grep --untracked -nI -i claudruple -- \
        Sources Tests Package.swift scripts native examples \
        ':!scripts/check-frozen-names.sh' \
        ':!Sources/TMUKit/Migration' \
        ':!Tests/TMUKitTests/Migration*' \
        | grep -vEi "$ALLOWED" \
        || true
)

if [ -n "$findings" ]; then
    echo "Unexpected occurrences of the pre-rename name:"
    echo ""
    echo "$findings"
    echo ""
    echo "If this is a frozen name, route it through Sources/TMUKit/LegacyNames.swift"
    echo "(or KeychainCredentials.legacyService) and add its form to ALLOWED here."
    echo "If it is a missed rename, rename it."
    exit 1
fi

echo "frozen names: ok"
