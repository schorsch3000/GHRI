# helpers.sh - Common test setup

# Get the directory where this file lives (test/shpec/)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# Go up two levels to ghri-v2/
GHRI_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

# Source ghri.sh (avoid running main)
source "$GHRI_DIR/ghri.sh"

# Every test run works in a throwaway sandbox; nothing is written to the repo.
# install/cache/symlink paths point into it so a test can never touch real installs.
if [[ -z "${TEST_SANDBOX:-}" ]]; then
  TEST_SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ghri-test.XXXXXX")"
  export TEST_SANDBOX
  trap 'rm -rf "$TEST_SANDBOX"' EXIT
fi
install_path="$TEST_SANDBOX/install"
cache_path="$TEST_SANDBOX/cache"
state_path="$TEST_SANDBOX/state"
mkdir -p "$TEST_SANDBOX/tmp"
export TMPDIR="$TEST_SANDBOX/tmp"
symlink_path="$TEST_SANDBOX/bin"
cache_lifetime=600

# shpec's `assert grep` argument order is easy to get wrong (and vacuously true with a
# here-string), so use these: assert_contains <text> <literal>, assert_matches <text> <regex>
assert_contains() {
  assert equal "$([[ "$1" == *"$2"* ]] && echo found || echo "missing [$2] in [$1]")" "found"
}
assert_matches() {
  assert equal "$([[ "$1" =~ $2 ]] && echo found || echo "no match for [$2] in [$1]")" "found"
}
