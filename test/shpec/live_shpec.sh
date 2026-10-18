# Live smoke test against the real GitHub API with the real `gh` (opt-in: GHRI_LIVE=1, make test-live).
# Everything happens in the sandbox. The fake gh is never used here, so these tests notice when
# the real gh changes the output format ghri.sh depends on. A token (GH_TOKEN/GITHUB_TOKEN) is
# recommended to stay clear of the 60 requests/hour limit.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/fake_gh.sh"

live_ok() {
  [[ "${GHRI_LIVE:-}" == 1 ]] || return 1
  command -v gh >/dev/null 2>&1 || return 1
  gh api rate_limit >/dev/null 2>&1 || return 1
  return 0
}

live_skip() {
  echo "    (skipped: set GHRI_LIVE=1; needs the real gh and network access)"
}

live_world() {
  rm -rf "$install_path" "$cache_path" "$state_path" "$symlink_path"
  FAIL=0
  FAILURES=()
  cache_lifetime=0
}

run_ghri() {
  local fn="$1"
  shift
  parse_args "$@"
  FAIL=0
  FAILURES=()
  "$fn" >"$TEST_SANDBOX/out.txt" 2>&1
  RC=$?
  OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g' "$TEST_SANDBOX/out.txt")
}

describe "live: release metadata" do
  it "reads a real release with assets and digests" do
    if live_ok; then
      live_world
      fake_config 'packages: []'
      fetch_release atanunq/viu false ""
      assert equal "$?" "0"
      assert_matches "$release_tag" '^v[0-9]'
      assert_contains "${release_asset_names[*]}" "viu-x86_64-unknown-linux-musl"
      assert_contains "${release_asset_digests[*]}" "sha256:"
    else
      live_skip
    fi
  end

  it "revalidates with the ETag and gets the same release back" do
    if live_ok; then
      live_world
      fake_config 'packages: []'
      cache_lifetime=0
      local first second
      first=$(api_get /repos/atanunq/viu/releases/latest | jq -r .tag_name)
      second=$(api_get /repos/atanunq/viu/releases/latest | jq -r .tag_name)
      assert_matches "$first" '^v[0-9]'
      assert equal "$first" "$second"
      assert equal "$([[ -s "$cache_path/api/_repos_atanunq_viu_releases_latest.etag" ]] && echo etag)" "etag"
    else
      live_skip
    fi
  end

  it "reports an unknown repository clearly" do
    if live_ok; then
      live_world
      fake_config 'packages: []'
      fetch_release ghri-test-nonexistent-owner/nothing-here false "" 2>/dev/null
      assert equal "$?" "1"
      assert_contains "$LAST_ERROR" "404"
    else
      live_skip
    fi
  end

  it "resolves a version pattern against the real release list" do
    if live_ok; then
      live_world
      fake_config 'packages: []'
      fetch_release jqlang/jq false 'jq-1.*'
      assert equal "$?" "0"
      assert_matches "$release_tag" '^jq-1\.'
    else
      live_skip
    fi
  end
end

describe "live: install" do
  it "downloads, verifies and links a real binary" do
    if live_ok; then
      live_world
      fake_config 'packages:
  - slug: jqlang/jq
    name: jq
    asset_matcher: jq-linux-amd64
    post_process:
      - make_exec
      - link
      - name: testrun
        args: --version'
      run_ghri do_install --verbose
      assert_contains "$OUT" "Verified sha256"
      assert_contains "$OUT" "jq installed"
      assert_matches "$("$symlink_path/jq" --version)" '^jq-'
      assert equal "$FAIL" "0"
      VERBOSE=false
    else
      live_skip
    fi
  end

  it "skips the package on the next run" do
    if live_ok; then
      live_world
      fake_config 'packages:
  - slug: jqlang/jq
    name: jq
    asset_matcher: jq-linux-amd64
    post_process: [make_exec, link]'
      run_ghri do_install
      run_ghri do_install
      assert_contains "$OUT" "up to date"
    else
      live_skip
    fi
  end

  it "verifies the attestation of an immutable release" do
    if live_ok; then
      live_world
      fake_config 'packages: []'
      fetch_release cli/cli false ""
      if [[ "$release_immutable" == "true" ]]; then
        fake_config 'packages:
  - slug: cli/cli
    name: gh-checksums
    asset_matcher: gh_*_checksums.txt'
        run_ghri do_install --verbose
        assert_contains "$OUT" "Verified release attestation"
        assert equal "$FAIL" "0"
        VERBOSE=false
      else
        echo "    (cli/cli releases are not immutable right now; attestation path not exercised)"
      fi
    else
      live_skip
    fi
  end

  it "shows real --outdated JSON" do
    if live_ok; then
      live_world
      fake_config 'packages:
  - slug: atanunq/viu
    asset_matcher: viu-x86_64-unknown-linux-musl'
      run_ghri do_outdated --json
      assert equal "$(jq -r '.[0].status' <<<"$OUT")" "not-installed"
      assert_matches "$(jq -r '.[0].latest' <<<"$OUT")" '^v[0-9]'
      JSON=false
    else
      live_skip
    fi
  end
end
