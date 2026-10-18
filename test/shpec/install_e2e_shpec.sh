# End-to-end tests of do_install / do_outdated against the fake gh (test/fakes/gh).
# No network, nothing outside the sandbox is touched.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/fake_gh.sh"

BARE_PKG='packages:
  - slug: acme/tool
    name: tool
    asset_matcher: tool-linux
    post_process:
      - make_exec
      - link
      - name: testrun
        args: --version'

# run <function> [args]: run an ghri command, capturing (ANSI-stripped) output in $OUT, status in $RC
run_ghri() {
  local fn="$1"; shift
  parse_args "$@"
  FAIL=0
  FAILURES=()
  "$fn" >"$TEST_SANDBOX/out.txt" 2>&1
  RC=$?
  OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g' "$TEST_SANDBOX/out.txt")
}

# new_world: fresh sandbox dirs + fake gh
new_world() {
  rm -rf "$install_path" "$cache_path" "$state_path" "$symlink_path" "$TEST_SANDBOX/rel"
  mkdir -p "$TEST_SANDBOX/rel"
  fake_gh_setup
}

# publish <tag> [version output] [exit code] [immutable] [digest] [created_at] [prerelease]
publish() {
  fake_script "$TEST_SANDBOX/rel/tool-linux" "${2:-tool $1}" "${3:-0}"
  fake_release acme/tool "$1" tool-linux "$TEST_SANDBOX/rel/tool-linux" "${4:-false}" "${5:-}" "${6:-}" "${7:-false}"
}

describe "do_install (fake gh)" do
  it "installs a bare binary, verifies it and links it" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_install
    assert_contains "$OUT" '✓ tool installed (v1)'
    assert_contains "$OUT" '1 installed, 0 up to date, 0 failed'
    assert equal "$(readlink "$symlink_path/tool")" "$install_path/acme_tool/v1/tool-linux"
    assert equal "$("$symlink_path/tool" --version)" "tool v1"
    state_read acme/tool
    assert equal "$state_tag" "v1"
  end

  it "skips a package that is already up to date" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_install
    : > "$GHRI_FAKE_DIR/calls.log"
    run_ghri do_install
    assert_contains "$OUT" '= tool up to date (v1)'
    assert equal "$(grep -c 'release download' "$GHRI_FAKE_DIR/calls.log")" "0"
  end

  it "reinstalls with --force" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_install
    run_ghri do_install --force
    assert_contains "$OUT" '✓ tool installed (v1)'
    FORCE=false
  end

  it "updates to a new version and removes the old one" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_install
    publish v2
    run_ghri do_install
    assert_contains "$OUT" 'tool installed (v1 to v2)'
    assert equal "$("$symlink_path/tool" --version)" "tool v2"
    assert equal "$(ls "$install_path/acme_tool")" "v2"
  end

  it "rejects a download whose sha256 does not match" do
    new_world
    publish v1 "tool v1" 0 false "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    fake_config "$BARE_PKG"
    run_ghri do_install
    assert_contains "$OUT" 'Checksum mismatch'
    assert_contains "$OUT" '✗ tool: download failed'
    assert equal "$FAIL" "1"
    assert equal "$([[ -e "$symlink_path/tool" ]] && echo linked || echo none)" "none"
    assert equal "$(ls -A "$install_path/acme_tool/v1")" ""
  end

  it "installs with a warning when GitHub published no digest" do
    new_world
    publish v1 "tool v1" 0 false "x"
    fake_config "$BARE_PKG"
    run_ghri do_install --verbose
    assert_contains "$OUT" 'published no sha256 digest'
    assert_contains "$OUT" '✓ tool installed'
    VERBOSE=false
  end

  it "verifies the attestation of immutable releases" do
    new_world
    publish v1 "tool v1" 0 true
    fake_config "$BARE_PKG"
    run_ghri do_install --verbose
    assert_contains "$OUT" 'Verified release attestation'
    assert_contains "$(fake_calls)" 'verify-asset v1'
    VERBOSE=false
  end

  it "fails when the attestation of an immutable release does not verify" do
    new_world
    publish v1 "tool v1" 0 true
    touch "$GHRI_FAKE_DIR/verify_fail"
    fake_config "$BARE_PKG"
    run_ghri do_install
    assert_contains "$OUT" 'attestation verification failed'
    assert equal "$FAIL" "1"
    assert equal "$([[ -e "$symlink_path/tool" ]] && echo linked || echo none)" "none"
  end

  it "rolls back to the previous version when post-processing fails" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_install
    publish v2 "broken" 1
    run_ghri do_install
    assert_contains "$OUT" '✗ tool: post-processing failed'
    assert equal "$FAIL" "1"
    assert equal "$(readlink "$symlink_path/tool")" "$install_path/acme_tool/v1/tool-linux"
    assert equal "$("$symlink_path/tool" --version)" "tool v1"
    assert equal "$([[ -d "$install_path/acme_tool/v1" ]] && echo kept)" "kept"
    state_read acme/tool
    assert equal "$state_tag" "v1"
  end

  it "removes the new link when a first installation fails" do
    new_world
    publish v1 "broken" 1
    fake_config "$BARE_PKG"
    run_ghri do_install
    assert equal "$FAIL" "1"
    assert equal "$([[ -e "$symlink_path/tool" || -L "$symlink_path/tool" ]] && echo linked || echo none)" "none"
    assert equal "$(state_read acme/tool && echo recorded || echo none)" "none"
  end

  it "installs a pinned version instead of the latest" do
    new_world
    publish v1
    publish v2
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    version: v1
    asset_matcher: tool-linux
    post_process: [make_exec, link]'
    run_ghri do_install
    assert_contains "$OUT" 'tool installed (v1)'
    assert_contains "$(fake_calls)" 'releases/tags/v1'
  end

  it "extracts archives via the post-processor chain" do
    new_world
    mkdir -p "$TEST_SANDBOX/rel/arc"
    fake_script "$TEST_SANDBOX/rel/arc/tool" "tool from archive"
    chmod +x "$TEST_SANDBOX/rel/arc/tool"
    (cd "$TEST_SANDBOX/rel/arc" && tar -czf ../tool.tar.gz tool)
    fake_release acme/tool v1 tool.tar.gz "$TEST_SANDBOX/rel/tool.tar.gz"
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    asset_matcher: tool.tar.gz
    post_process:
      - gunzip
      - name: tar
        asset_matcher: tool
      - link
      - name: testrun
        args: --version'
    run_ghri do_install
    assert_contains "$OUT" '✓ tool installed (v1)'
    assert equal "$("$symlink_path/tool" --version)" "tool from archive"
  end

  it "shows the buffered log of a failing package" do
    new_world
    publish v1 "broken" 1
    fake_config "$BARE_PKG"
    run_ghri do_install
    assert_contains "$OUT" 'testrun failed'
  end

  it "reports a missing asset" do
    new_world
    publish v1
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    asset_matcher: nothing-matches-*'
    run_ghri do_install
    assert_contains "$OUT" "no asset matches 'nothing-matches-*'"
    assert equal "$FAIL" "1"
  end

  it "reports an unknown repository" do
    new_world
    fake_config 'packages:
  - slug: acme/missing
    asset_matcher: x'
    run_ghri do_install
    assert_contains "$OUT" 'HTTP 404'
    assert equal "$FAIL" "1"
  end

  it "reports rate limiting with the reset time" do
    new_world
    publish v1
    touch "$GHRI_FAKE_DIR/rate_limited"
    fake_config "$BARE_PKG"
    run_ghri do_install
    assert_contains "$OUT" 'rate limit exceeded'
    assert equal "$FAIL" "1"
  end

  it "continues with other packages after a failure" do
    new_world
    publish v1
    fake_release acme/other v1 other-linux "$TEST_SANDBOX/rel/tool-linux"
    fake_config 'packages:
  - slug: acme/missing
    asset_matcher: x
  - slug: acme/other
    name: other
    asset_matcher: other-linux
    post_process: [make_exec, link]'
    run_ghri do_install
    assert_contains "$OUT" '✗ missing'
    assert_contains "$OUT" '✓ other installed'
    assert equal "$FAIL" "1"
  end

  it "installs only named packages" do
    new_world
    publish v1
    fake_release acme/other v1 other-linux "$TEST_SANDBOX/rel/tool-linux"
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    asset_matcher: tool-linux
    post_process: [make_exec, link]
  - slug: acme/other
    name: other
    asset_matcher: other-linux
    post_process: [make_exec, link]'
    run_ghri do_install other
    assert_contains "$OUT" '✓ other installed'
    assert equal "$(grep -c 'tool' <<< "$OUT" || true)" "0"
  end
end

describe "do_outdated (fake gh)" do
  it "reports not installed, up to date and update available" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_outdated
    assert_contains "$OUT" 'not installed'
    run_ghri do_install
    run_ghri do_outdated
    assert_contains "$OUT" 'up to date'
    publish v2
    run_ghri do_outdated
    assert_contains "$OUT" 'update available'
    assert_matches "$OUT" 'v1 +v2'
  end

  it "does not download or change anything" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_outdated
    assert equal "$(grep -c 'release download' "$GHRI_FAKE_DIR/calls.log" || true)" "0"
    assert equal "$([[ -e "$install_path" ]] && echo exists || echo none)" "none"
  end

  it "shows API errors per row and counts them" do
    new_world
    fake_config 'packages:
  - slug: acme/missing
    asset_matcher: x'
    run_ghri do_outdated
    assert_contains "$OUT" 'error'
    assert equal "$FAIL" "1"
  end

  it "marks pinned packages" do
    new_world
    publish v1
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    version: v1
    asset_matcher: tool-linux'
    run_ghri do_outdated
    assert_contains "$OUT" '(pinned)'
  end
end

describe "api_get (fake gh)" do
  it "revalidates a stale cache entry with the ETag and reuses it on 304" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    cache_lifetime=0
    api_get /repos/acme/tool/releases/latest >/dev/null
    : > "$GHRI_FAKE_DIR/calls.log"
    local body
    body=$(api_get /repos/acme/tool/releases/latest)
    assert_contains "$(fake_calls)" 'If-None-Match'
    assert_contains "$(jq -c . <<< "$body")" '"tag_name":"v1"'
  end

  it "makes no request while the cache is fresh" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    cache_lifetime=600
    api_get /repos/acme/tool/releases/latest >/dev/null
    : > "$GHRI_FAKE_DIR/calls.log"
    api_get /repos/acme/tool/releases/latest >/dev/null
    assert equal "$(wc -c < "$GHRI_FAKE_DIR/calls.log")" "0"
    cache_lifetime=0
  end

  it "picks up a changed release after the TTL" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    api_get /repos/acme/tool/releases/latest >/dev/null
    publish v2
    local tag
    tag=$(api_get /repos/acme/tool/releases/latest | jq -r .tag_name)
    assert equal "$tag" "v2"
  end
end

# run_main <args>: run the whole program (main) against the sandbox config; sets OUT and RC
run_main() {
  (
    SCRIPT_DIR="$TEST_SANDBOX/cfg"
    FAIL=0 FAILURES=() OUTDATED_COUNT=0 QUIET=false VERBOSE=false FORCE=false
    main "$@"
  ) >"$TEST_SANDBOX/out.txt" 2>&1
  RC=$?
  OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g' "$TEST_SANDBOX/out.txt")
}

describe "version patterns (fake gh)" do
  it "picks the newest release matching a glob" do
    new_world
    publish v1.0 "tool 1.0" 0 false "" "2026-01-01T00:00:00Z"
    publish v1.1 "tool 1.1" 0 false "" "2026-02-01T00:00:00Z"
    publish v2.0 "tool 2.0" 0 false "" "2026-03-01T00:00:00Z"
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    version: "v1.*"
    asset_matcher: tool-linux
    post_process: [make_exec, link]'
    run_ghri do_install
    assert_contains "$OUT" 'tool installed (v1.1)'
    assert_contains "$(fake_calls)" 'releases?per_page=100'
  end

  it "skips pre-releases unless the package accepts them" do
    new_world
    publish v1.0 "tool 1.0" 0 false "" "2026-01-01T00:00:00Z"
    publish v1.1 "tool 1.1" 0 false "" "2026-02-01T00:00:00Z" true
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    version: "v1.*"
    asset_matcher: tool-linux
    post_process: [make_exec, link]'
    run_ghri do_install
    assert_contains "$OUT" 'tool installed (v1.0)'
  end

  it "supports /regex/ patterns" do
    new_world
    publish v1.0 "tool 1.0" 0 false "" "2026-01-01T00:00:00Z"
    publish v2.0 "tool 2.0" 0 false "" "2026-03-01T00:00:00Z"
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    version: "/^v1\\./"
    asset_matcher: tool-linux
    post_process: [make_exec, link]'
    run_ghri do_install
    assert_contains "$OUT" 'tool installed (v1.0)'
  end

  it "fails clearly when no release matches" do
    new_world
    publish v1.0
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    version: "v9.*"
    asset_matcher: tool-linux'
    run_ghri do_install
    assert_contains "$OUT" "No release of acme/tool matches version pattern 'v9.*'"
    assert equal "$FAIL" "1"
  end
end

describe "exit codes and quiet mode (main)" do
  it "exits 10 for --outdated when a package is not current" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main --outdated
    assert equal "$RC" "10"
    assert_contains "$OUT" 'not installed'
  end

  it "exits 0 for --outdated when everything is current" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    assert equal "$RC" "0"
    run_main --outdated
    assert equal "$RC" "0"
  end

  it "exits 1 when --outdated hits an error" do
    new_world
    fake_config 'packages:
  - slug: acme/missing
    asset_matcher: x'
    run_main --outdated
    assert equal "$RC" "1"
  end

  it "--quiet --outdated prints only packages that are not current" do
    new_world
    publish v1
    fake_release acme/other v1 other-linux "$TEST_SANDBOX/rel/tool-linux"
    fake_config 'packages:
  - slug: acme/tool
    name: tool
    asset_matcher: tool-linux
    post_process: [make_exec, link]
  - slug: acme/other
    name: other
    asset_matcher: other-linux
    post_process: [make_exec, link]'
    run_main install tool
    publish v2
    run_main --outdated --quiet
    assert equal "$RC" "10"
    assert_contains "$OUT" 'tool'
    assert equal "$(grep -c 'NAME' <<< "$OUT" || true)" "0"
    assert_contains "$OUT" 'update available'
    assert equal "$(grep -c 'other .* up to date' <<< "$OUT" || true)" "0"
  end

  it "--quiet install prints nothing when nothing changed" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    run_main install --quiet
    assert equal "$RC" "0"
    assert equal "$OUT" ""
  end

  it "--quiet install still reports changes" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install --quiet
    assert_contains "$OUT" 'tool installed (v1)'
  end

  it "aborts before any network access when the config is invalid" do
    new_world
    fake_config 'packages:
  - slug: nonsense'
    run_main install
    assert equal "$RC" "1"
    assert_contains "$OUT" 'Config check failed'
    assert equal "$(wc -c < "$GHRI_FAKE_DIR/calls.log" 2>/dev/null || echo 0)" "0"
  end
end

describe "prune" do
  prune_world() {
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_install
    mkdir -p "$install_path/acme_gone/v1" "$state_path/acme_gone" "$symlink_path"
    echo x > "$install_path/acme_gone/v1/gone-linux"
    echo tag_name=v1 > "$state_path/acme_gone/release.dat"
    ln -s "$install_path/acme_gone/v1/gone-linux" "$symlink_path/gone"
    ln -s /usr/bin/env "$symlink_path/unrelated"
  }

  it "finds installs, records and links of packages that left the config" do
    prune_world
    local found
    found=$(find_orphans | sort)
    assert equal "$found" "$(printf 'install\t%s\nlink\t%s\nrecord\t%s' "$install_path/acme_gone" "$symlink_path/gone" "$state_path/acme_gone" | sort)"
  end

  it "never lists configured packages, the api cache or unrelated links" do
    prune_world
    local found
    found=$(find_orphans)
    assert equal "$(grep -c 'acme_tool\|unrelated\|/api' <<< "$found" || true)" "0"
  end

  it "deletes nothing without confirmation when not interactive" do
    prune_world
    ASSUME_YES=false
    do_prune </dev/null >/dev/null 2>&1
    assert equal "$([[ -d "$install_path/acme_gone" ]] && echo kept)" "kept"
  end

  it "deletes orphans with --yes and keeps everything else" do
    prune_world
    ASSUME_YES=true
    do_prune >/dev/null 2>&1
    ASSUME_YES=false
    assert equal "$([[ -e "$install_path/acme_gone" || -L "$symlink_path/gone" || -e "$state_path/acme_gone" ]] && echo left || echo gone)" "gone"
    assert equal "$("$symlink_path/tool" --version)" "tool v1"
    assert equal "$([[ -L "$symlink_path/unrelated" ]] && echo kept)" "kept"
    assert equal "$(find_orphans)" ""
  end

  it "reports when there is nothing to prune" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_ghri do_install
    run_ghri do_prune
    assert_contains "$OUT" 'Nothing to prune'
  end
end

describe "nothing is installed without the install command" do
  it "shows the help for a bare run" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main
    assert equal "$RC" "0"
    assert_contains "$OUT" 'Usage: '
    assert_contains "$OUT" 'install [NAMES...]'
    assert equal "$([[ -e "$install_path" || -e "$symlink_path/tool" ]] && echo installed || echo untouched)" "untouched"
    assert equal "$(wc -c < "$GHRI_FAKE_DIR/calls.log" 2>/dev/null || echo 0)" "0"
  end

  it "rejects loose package names and points at the install command" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main tool
    assert equal "$RC" "2"
    assert_contains "$OUT" 'install tool'
    assert equal "$([[ -e "$symlink_path/tool" ]] && echo installed || echo untouched)" "untouched"
  end

  it "rejects install-only flags without the command" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main --force
    assert equal "$RC" "2"
    run_main --quiet
    assert equal "$RC" "2"
    run_main --verbose
    assert equal "$RC" "2"
  end

  it "still runs the other commands without install" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main --check
    assert equal "$RC" "0"
    run_main --outdated
    assert equal "$RC" "10"
  end
end
