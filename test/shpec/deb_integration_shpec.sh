# Integration test for the interactive `deb` fix prompt. Opt-in: GHRI_INTEGRATION=1 (make test-integration).
# Downloads `toilet` (depends on packages that are not installed in a minimal image)
# from the Debian mirror, installs it with sudo via pp_deb inside a pty, and removes
# everything it installed afterwards. Skipped without passwordless sudo, `script`,
# or network access.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

DEB_TEST_DIR="$TEST_SANDBOX/tmp/deb_integration"
DEB_PKGS_BEFORE="$DEB_TEST_DIR/pkgs_before"

deb_integration_prereqs() {
  [[ "${GHRI_INTEGRATION:-}" == 1 ]] || return 1   # opt-in: changes the real system via sudo (make test-integration)
  command -v script >/dev/null 2>&1 || return 1
  sudo -n true >/dev/null 2>&1 || return 1
  dpkg -s toilet >/dev/null 2>&1 && return 1   # never touch a pre-existing install
  return 0
}

deb_integration_setup() {
  rm -rf "$DEB_TEST_DIR"
  mkdir -p "$DEB_TEST_DIR"
  dpkg-query -W -f '${Package}\n' | sort > "$DEB_PKGS_BEFORE"
  # apt-get download runs as the current user; refresh lists if the package is unknown
  (cd "$DEB_TEST_DIR" && { apt-get download toilet || { sudo -n apt-get update >/dev/null 2>&1 && apt-get download toilet; }; } >/dev/null 2>&1)
  ls "$DEB_TEST_DIR"/toilet_*.deb >/dev/null 2>&1
}

deb_integration_cleanup() {
  local added
  added=$(dpkg-query -W -f '${Package}\n' | sort | comm -13 "$DEB_PKGS_BEFORE" - | tr '\n' ' ')
  # shellcheck disable=SC2086
  [[ -n "$added" ]] && sudo -n dpkg --purge --force-depends $added >/dev/null 2>&1
  rm -rf "$DEB_TEST_DIR"
}

# Run pp_deb in a pty, feeding $1 as the answer to the prompt after a short delay
# (input sent earlier gets swallowed by sudo/dpkg). Prints "RC=<exit code>" last.
deb_integration_run() {
  local answer="$1" deb
  deb=$(ls "$DEB_TEST_DIR"/toilet_*.deb)
  { sleep 4; printf '%s\n' "$answer"; sleep 25; } |
    script -qec "bash -c 'source \"$GHRI_DIR/ghri.sh\"; pp_deb \"$deb\" toilet; echo RC=\$?'" /dev/null 2>&1
}

describe "pp_deb interactive fix (integration)" do
  it "asks and fixes missing dependencies when answering y" do
    if deb_integration_prereqs && deb_integration_setup; then
      local out
      out=$(deb_integration_run y)
      assert_contains "$out" "Try to fix with"
      assert_contains "$out" "RC=0"
      dpkg -s toilet 2>/dev/null | grep -q '^Status: install ok installed'
      assert equal "$?" "0"
    else
      echo "    (skipped: set GHRI_INTEGRATION=1; needs sudo -n, script, network, toilet not installed)"
    fi
    deb_integration_cleanup
  end

  it "leaves the package unconfigured when answering n" do
    if deb_integration_prereqs && deb_integration_setup; then
      local out
      out=$(deb_integration_run n)
      assert_contains "$out" "Try to fix with"
      assert_contains "$out" "RC=1"
      dpkg -s toilet 2>/dev/null | grep -q '^Status: install ok installed'
      assert equal "$?" "1"
    else
      echo "    (skipped: set GHRI_INTEGRATION=1; needs sudo -n, script, network, toilet not installed)"
    fi
    deb_integration_cleanup
  end
end
