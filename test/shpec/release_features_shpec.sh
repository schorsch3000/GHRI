# Version, example config, JSON output, architecture, time limits, lock, interrupts, state migration
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

new_world() {
  rm -rf "$install_path" "$cache_path" "$state_path" "$symlink_path" "$TEST_SANDBOX/rel" "$TEST_SANDBOX/cfg"
  mkdir -p "$TEST_SANDBOX/rel"
  fake_gh_setup
}

publish() {
  fake_script "$TEST_SANDBOX/rel/tool-linux" "${2:-tool $1}" "${3:-0}"
  fake_release acme/tool "$1" tool-linux "$TEST_SANDBOX/rel/tool-linux"
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

run_main() {
  (
    SCRIPT_DIR="$TEST_SANDBOX/cfg"
    FAIL=0 FAILURES=() OUTDATED_COUNT=0 QUIET=false VERBOSE=false FORCE=false JSON=false
    main "$@"
  ) >"$TEST_SANDBOX/out.txt" 2>"$TEST_SANDBOX/err.txt"
  RC=$?
  OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g' "$TEST_SANDBOX/out.txt")
}

describe "version" do
  it "prints the version" do
    assert equal "$(bash "$GHRI_DIR/ghri.sh" --version)" "ghri.sh $VERSION"
  end

  it "matches the latest CHANGELOG entry" do
    assert_contains "$(cat "$GHRI_DIR/CHANGELOG.md")" "## [$VERSION]"
  end

  it "ships a license" do
    assert_contains "$(head -1 "$GHRI_DIR/LICENSE")" "MIT License"
  end
end

describe "example config" do
  it "passes the config check" do
    CONFIG_FILE="$GHRI_DIR/ghri.example.yaml"
    _CONFIG_SIG=""
    local out
    out=$(check_config false 2>&1)
    assert equal "$?" "0"
    assert equal "$out" ""
  end

  it "is what a missing config points to" do
    mkdir -p "$TEST_SANDBOX/empty"
    local out
    out=$(
      SCRIPT_DIR="$TEST_SANDBOX/empty"
      find_config 2>&1
    )
    assert_contains "$out" "ghri.example.yaml"
  end

  it "keeps the personal config out of git" do
    assert_contains "$(cat "$GHRI_DIR/.gitignore")" "ghri.yaml"
    assert_contains "$(cat "$GHRI_DIR/.gitignore")" ".env"
  end
end

describe "--outdated --json" do
  it "prints a JSON array with one object per package" do
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
    version: v1
    asset_matcher: other-linux'
    run_main install tool
    publish v2
    run_main --outdated --json
    assert equal "$RC" "10"
    assert equal "$(jq -r 'map(.name + ":" + .status) | join(",")' <<<"$OUT")" "tool:update-available,other:not-installed"
    assert equal "$(jq -r '.[0] | [.installed, .latest, (.pinned // "none")] | @tsv' <<<"$OUT")" "$(printf 'v1\tv2\tnone')"
    assert equal "$(jq -r '.[1].pinned' <<<"$OUT")" "v1"
    assert equal "$(jq -r '.[1].installed' <<<"$OUT")" "null"
  end

  it "reports errors per package and exits 1" do
    new_world
    fake_config 'packages:
  - slug: acme/missing
    asset_matcher: x'
    run_main --outdated --json
    assert equal "$RC" "1"
    assert equal "$(jq -r '.[0].status' <<<"$OUT")" "error"
    assert_contains "$(jq -r '.[0].error' <<<"$OUT")" "404"
  end

  it "prints only packages that need attention with --quiet" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    run_main --outdated --json --quiet
    assert equal "$RC" "0"
    assert equal "$OUT" "[]"
  end

  it "keeps stdout clean (pure JSON, no table header)" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main --outdated --json
    assert equal "$(jq -r 'type' <<<"$OUT")" "array"
  end
end

describe "architecture" do
  it "suggests the asset for the host CPU" do
    release_asset_names=("tool_linux_amd64.tar.gz" "tool_linux_arm64.tar.gz" "tool_darwin_arm64.tar.gz" "tool_linux_armv7.tar.gz")
    release_asset_count=4
    assert equal "$(GHRI_ARCH=x86_64 suggest_asset_index)" "0"
    assert equal "$(GHRI_ARCH=aarch64 suggest_asset_index)" "1"
    assert equal "$(GHRI_ARCH=arm64 suggest_asset_index)" "1"
    assert equal "$(GHRI_ARCH=armv7l suggest_asset_index)" "3"
  end

  it "does not prefer an arch for unknown CPUs" do
    release_asset_names=("tool_linux_amd64.tar.gz")
    release_asset_count=1
    assert equal "$(GHRI_ARCH=riscv64 suggest_asset_index)" "0"
  end

  it "uses uname -m by default" do
    release_asset_names=("tool_linux_arm64.tar.gz" "tool_linux_amd64.tar.gz")
    release_asset_count=2
    local expected=1
    [[ "$(uname -m)" == aarch64 || "$(uname -m)" == arm64 ]] && expected=0
    assert equal "$(suggest_asset_index)" "$expected"
  end
end

describe "time limits" do
  it "gives up on a slow API call" do
    new_world
    publish v1
    echo 5 >"$GHRI_FAKE_DIR/slow_api"
    fake_config "timeout_sec: 1
$BARE_PKG"
    run_ghri do_install
    assert_contains "$OUT" "timed out after 1s (timeout_sec)"
    assert equal "$FAIL" "1"
  end

  it "gives up on a slow download and removes the partial file" do
    new_world
    publish v1
    echo 5 >"$GHRI_FAKE_DIR/slow_download"
    fake_config "download_timeout_sec: 1
$BARE_PKG"
    run_ghri do_install
    assert_contains "$OUT" "timed out after 1s (download_timeout_sec)"
    assert equal "$(find "$install_path" -name '*.part' | wc -l)" "0"
  end

  it "reads the limits from the config and defaults them" do
    new_world
    fake_config "timeout_sec: 7
download_timeout_sec: 77
packages: []"
    assert equal "$gh_timeout|$download_timeout" "7|77"
    fake_config "$BARE_PKG"
    assert equal "$gh_timeout|$download_timeout" "60|900"
  end

  it "rejects non-numeric limits in the config check" do
    new_world
    fake_config "timeout_sec: soon
$BARE_PKG"
    local out
    out=$(check_config false 2>&1)
    assert_contains "$out" "timeout_sec must be a number"
  end
end

describe "lock" do
  it "refuses to start while another run holds the lock" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    mkdir -p "$state_path"
    exec 8>"$state_path/ghri.lock"
    flock -n 8
    run_main install
    exec 8>&-
    assert equal "$RC" "1"
    assert_contains "$(cat "$TEST_SANDBOX/err.txt")" "Another ghri run is in progress"
    assert equal "$([[ -e "$symlink_path/tool" ]] && echo installed || echo untouched)" "untouched"
  end

  it "runs once the lock is free again" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    assert equal "$RC" "0"
  end

  it "does not lock read-only commands" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    mkdir -p "$state_path"
    exec 8>"$state_path/ghri.lock"
    flock -n 8
    run_main --outdated
    exec 8>&-
    assert equal "$RC" "10"
  end
end

# start_real <args...>: run ghri.sh as a real process in its own session (so a signal reaches its children too)
start_real() {
  cp "$GHRI_DIR/ghri.sh" "$TEST_SANDBOX/cfg/ghri.sh"
  : >"$TEST_SANDBOX/real.out"
  setsid bash "$TEST_SANDBOX/cfg/ghri.sh" "$@" >"$TEST_SANDBOX/real.out" 2>&1 &
  REAL_PID=$!
}

# wait_for <seconds> <command...>: poll until the command succeeds
wait_for() {
  local n=$(($1 * 10))
  shift
  while ((n-- > 0)); do
    "$@" && return 0
    sleep 0.1
  done
  return 1
}

stop_real() {
  kill -TERM -- "-$REAL_PID" 2>/dev/null
  wait "$REAL_PID" 2>/dev/null
  REAL_RC=$?
}

describe "interrupts" do
  it "removes the partial download and the temp dir when stopped during a download" do
    new_world
    publish v1
    echo 30 >"$GHRI_FAKE_DIR/slow_download"
    fake_config "$BARE_PKG"
    start_real install
    wait_for 10 grep -q 'release download' "$GHRI_FAKE_DIR/calls.log"
    stop_real
    assert equal "$REAL_RC" "143"
    assert_contains "$(cat "$TEST_SANDBOX/real.out")" "Terminated"
    assert equal "$(find "$install_path" -name '*.part' 2>/dev/null | wc -l)" "0"
    assert equal "$(ls -A "$TEST_SANDBOX/tmp" | grep -c '^ghri\.' || true)" "0"
  end

  it "restores the previous version when stopped during post-processing" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    assert equal "$("$symlink_path/tool" --version)" "tool v1"
    # v2 hangs in its smoke test
    printf '#!/bin/sh\nsleep 30\n' >"$TEST_SANDBOX/rel/tool-linux"
    fake_release acme/tool v2 tool-linux "$TEST_SANDBOX/rel/tool-linux"
    start_real install
    wait_for 10 test "$(readlink "$symlink_path/tool" 2>/dev/null)" = "$install_path/acme_tool/v2/tool-linux"
    stop_real
    assert equal "$REAL_RC" "143"
    assert equal "$(readlink "$symlink_path/tool")" "$install_path/acme_tool/v1/tool-linux"
    assert equal "$("$symlink_path/tool" --version)" "tool v1"
    state_read acme/tool
    assert equal "$state_tag" "v1"
    assert equal "$(ls -A "$TEST_SANDBOX/tmp" | grep -c '^ghri\.' || true)" "0"
  end
end

describe "installed state (e2e)" do
  it "keeps the record when the cache is cleared" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    rm -rf "$cache_path"
    run_main --outdated
    assert_contains "$OUT" "up to date"
    assert equal "$RC" "0"
  end

  it "migrates a record from an older version that kept it in the cache" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    mkdir -p "$cache_path/acme_tool"
    mv "$state_path/acme_tool/release.dat" "$cache_path/acme_tool/release.dat"
    run_main --outdated
    assert_contains "$OUT" "up to date"
    assert equal "$([[ -f "$state_path/acme_tool/release.dat" ]] && echo migrated)" "migrated"
  end

  it "lets prune remove records of packages that left the config (state and legacy)" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    run_main install
    mkdir -p "$state_path/acme_gone" "$cache_path/acme_old"
    echo tag_name=v1 >"$state_path/acme_gone/release.dat"
    echo tag_name=v1 >"$cache_path/acme_old/release.dat"
    run_main --prune --yes
    assert equal "$([[ -e "$state_path/acme_gone" || -e "$cache_path/acme_old" ]] && echo left || echo gone)" "gone"
    assert equal "$([[ -f "$state_path/acme_tool/release.dat" ]] && echo kept)" "kept"
  end
end

describe "--no-cache" do
  it "parses --no-cache, --refresh and -r" do
    NO_CACHE=false
    parse_args install --no-cache
    assert equal "$NO_CACHE" "true"
    NO_CACHE=false
    parse_args install --refresh
    assert equal "$NO_CACHE" "true"
    NO_CACHE=false
    parse_args install -r
    assert equal "$NO_CACHE" "true"
    NO_CACHE=false
  end

  it "is documented in the help" do
    assert_contains "$(show_help)" "--no-cache"
  end

  it "uses a fresh cache entry without --no-cache but not with it" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    cache_lifetime=600
    api_get /repos/acme/tool/releases/latest >/dev/null
    : >"$GHRI_FAKE_DIR/calls.log"
    api_get /repos/acme/tool/releases/latest >/dev/null
    assert equal "$(wc -c <"$GHRI_FAKE_DIR/calls.log")" "0"
    NO_CACHE=true
    api_get /repos/acme/tool/releases/latest >/dev/null
    NO_CACHE=false
    assert_contains "$(fake_calls)" "api -i"
  end

  it "does not send If-None-Match even when a stale entry exists" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    cache_lifetime=0
    api_get /repos/acme/tool/releases/latest >/dev/null
    : >"$GHRI_FAKE_DIR/calls.log"
    NO_CACHE=true
    api_get /repos/acme/tool/releases/latest >/dev/null
    NO_CACHE=false
    assert equal "$(grep -c 'If-None-Match' "$GHRI_FAKE_DIR/calls.log" || true)" "0"
    assert_contains "$(fake_calls)" "api -i"
  end

  it "installs a release published within the cache lifetime" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    cache_lifetime=600
    run_main install
    publish v2
    # the cached answer still says v1 ...
    sed -i 's/^cache_lifetime_sec: .*/cache_lifetime_sec: 600/' "$CONFIG_FILE"
    run_main install --force
    assert_contains "$OUT" "tool installed (v1)"
    # ... --no-cache asks GitHub again
    run_main install --force --no-cache
    assert_contains "$OUT" "tool installed (v1 to v2)"
    assert equal "$("$symlink_path/tool" --version)" "tool v2"
  end

  it "makes --outdated see a new release immediately" do
    new_world
    publish v1
    fake_config "$BARE_PKG"
    sed -i 's/^cache_lifetime_sec: .*/cache_lifetime_sec: 600/' "$CONFIG_FILE"
    run_main install
    publish v2
    run_main --outdated
    assert_contains "$OUT" "up to date"
    run_main --outdated --no-cache
    assert_contains "$OUT" "update available"
  end
end
