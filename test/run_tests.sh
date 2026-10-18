#!/bin/bash
# Test runner for GHRI - uses shpec
set -o pipefail

cd "$(dirname "$0")/.." || exit 1

echo "=== GHRI Test Suite ==="
echo ""

# Runs every *_shpec.sh below the current directory. The deb integration test skips
# itself unless GHRI_INTEGRATION=1.
out=$(./shpec 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g')
status=${PIPESTATUS[0]}
printf '%s\n' "$out"

# shpec's exit status is not reliable across versions: also look at the summary line
if [[ $status -ne 0 ]] || grep -Eq '[1-9][0-9]* failures' <<<"$out"; then
  exit 1
fi
