#!/bin/bash
# test_runner.sh - Main test runner for ghri.sh test suite

cd "$(dirname "$0")"

echo "=== GHRI Test Suite ==="
echo ""

# Check for shpec
if [ ! -f "../shpec" ]; then
  echo "ERROR: shpec not found at ../shpec"
  exit 1
fi

# Run all tests
../shpec test/shpec/*.sh 2>&1
exit $?