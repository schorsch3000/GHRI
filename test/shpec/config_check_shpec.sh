TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

# run_check <yaml>: write config, run check_config (warnings shown), keep output in $CHECK_OUT
run_check() {
  mkdir -p "$TEST_SANDBOX/chk"
  CONFIG_FILE="$TEST_SANDBOX/chk/ghri.yaml"
  printf '%s\n' "$1" > "$CONFIG_FILE"
  _CONFIG_SIG=""
  PATH="$symlink_path:$PATH"   # keep the symlink_path warning out of the way
  CHECK_OUT=$(check_config true 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g')
  check_config true >/dev/null 2>&1
  CHECK_RC=$?
}

describe "check_config" do
  it "accepts a valid config" do
    run_check "packages:
  - slug: o/tool
    asset_matcher: '*-linux'
    post_process:
      - make_exec
      - link
      - name: testrun
        args: --version"
    assert equal "$CHECK_RC" "0"
  end

  it "rejects a bad slug" do
    run_check "packages:
  - slug: nonsense"
    assert equal "$CHECK_RC" "1"
    assert_contains "$CHECK_OUT" "slug must look like owner/repo"
  end

  it "rejects an unknown post-processor" do
    run_check "packages:
  - slug: o/tool
    post_process:
      - make_exec
      - frobnicate"
    assert equal "$CHECK_RC" "1"
    assert_contains "$CHECK_OUT" 'unknown post-processor "frobnicate"'
  end

  it "rejects unknown global post-processors" do
    run_check "global_post_process:
  append:
    - nope
packages:
  - slug: o/tool"
    assert equal "$CHECK_RC" "1"
    assert_contains "$CHECK_OUT" 'unknown post-processor "nope"'
  end

  it "rejects an invalid regex asset_matcher" do
    run_check "packages:
  - slug: o/tool
    asset_matcher: '/(unclosed/'"
    assert equal "$CHECK_RC" "1"
    assert_contains "$CHECK_OUT" 'invalid regex'
  end

  it "rejects duplicate package names" do
    run_check "packages:
  - slug: a/tool
  - slug: b/other
    name: tool"
    assert equal "$CHECK_RC" "1"
    assert_contains "$CHECK_OUT" 'duplicate package name "tool"'
  end

  it "rejects wrong types" do
    run_check "packages:
  - slug: o/tool
    prerelease: maybe
    post_process: make_exec"
    assert equal "$CHECK_RC" "1"
    assert_contains "$CHECK_OUT" 'prerelease must be true or false'
    assert_contains "$CHECK_OUT" 'post_process must be a list'
  end

  it "rejects an empty package list" do
    run_check "packages: []"
    assert equal "$CHECK_RC" "1"
  end

  it "warns about unknown keys without failing" do
    run_check "packages:
  - slug: o/tool
    colour: blue"
    assert equal "$CHECK_RC" "0"
    assert_contains "$CHECK_OUT" 'unknown key "colour"'
  end

  it "warns when symlink_path is not in PATH" do
    mkdir -p "$TEST_SANDBOX/chk"
    CONFIG_FILE="$TEST_SANDBOX/chk/ghri.yaml"
    printf 'packages:\n  - slug: o/tool\n' > "$CONFIG_FILE"
    _CONFIG_SIG=""
    symlink_path="$TEST_SANDBOX/not-in-path"
    local out
    out=$(check_config true 2>&1)
    assert_contains "$out" 'not in PATH'
    symlink_path="$TEST_SANDBOX/bin"
  end

  it "reports a missing tool needed by a post-processor" do
    run_check "packages:
  - slug: o/tool
    post_process: [unzip]"
    # pretend unzip is not installed
    command() { if [[ "$1 $2" == "-v unzip" ]]; then return 1; fi; builtin command "$@"; }
    local out rc
    out=$(check_config true 2>&1)
    rc=$?
    unset -f command
    assert equal "$rc" "1"
    assert_contains "$out" "needs 'unzip'"
  end
end

describe "check_targets" do
  it "rejects unknown package names" do
    CONFIG_FILE="$TEST_SANDBOX/chk/ghri.yaml"
    printf 'packages:\n  - slug: o/tool\n' > "$CONFIG_FILE"
    _CONFIG_SIG=""
    TARGETS=(tool nosuch)
    check_targets >/dev/null 2>&1
    assert equal "$?" "1"
    TARGETS=(tool)
    check_targets >/dev/null 2>&1
    assert equal "$?" "0"
    TARGETS=()
  end
end

describe "detect_tools" do
  it "passes when all required tools are present" do
    (detect_tools) >/dev/null 2>&1
    assert equal "$?" "0"
  end

  it "reports every missing tool at once with an install hint and exits 1" do
    # pretend gh, jq and sha256sum are not installed
    command() {
      if [[ "$1" == "-v" ]]; then
        case "$2" in gh | jq | sha256sum) return 1 ;; esac
      fi
      builtin command "$@"
    }
    local out rc
    out=$(detect_tools 2>&1)
    rc=$?
    unset -f command
    assert equal "$rc" "1"
    assert_contains "$out" "'gh' not found. Install with: apt install gh"
    assert_contains "$out" "'jq' not found. Install with: apt install jq"
    assert_contains "$out" "'sha256sum' not found. Install with: apt install coreutils"
  end

  it "names the package for a missing post-processor tool" do
    run_check "packages:
  - slug: o/tool
    post_process: [unzip, deb]"
    command() {
      if [[ "$1" == "-v" ]]; then
        case "$2" in unzip | apt-get) return 1 ;; esac
      fi
      builtin command "$@"
    }
    local out
    out=$(check_config true 2>&1)
    unset -f command
    assert_contains "$out" "needs 'unzip', which is not installed (apt install unzip)"
    assert_contains "$out" "apt-get not found"
  end
end

describe "apt-packages.txt" do
  it "lists every package ghri.sh needs (so the Dockerfile and make deps stay in sync)" do
    local listed missing="" entry pkg
    listed=$(grep -vE '^(#|$)' "$GHRI_DIR/apt-packages.txt")
    for entry in "${REQUIRED_TOOLS[@]}" $(for p in gunzip bz2 xz tar unzip deb; do processor_tools "$p"; done); do
      pkg="${entry#*:}"
      for pkg in $pkg; do
        grep -qx "${pkg#*:}" <<<"$listed" || missing="$missing $pkg"
      done
    done
    assert equal "$missing" ""
  end
end

describe "load_package" do
  it "reads all fields at once and applies defaults" do
    mkdir -p "$TEST_SANDBOX/chk"
    CONFIG_FILE="$TEST_SANDBOX/chk/ghri.yaml"
    printf 'packages:\n  - slug: o/full\n    name: custom\n    prerelease: true\n    asset_matcher: "*.deb"\n    version: v1.*\n    auto_install: false\n  - slug: o/bare\n' > "$CONFIG_FILE"
    _CONFIG_SIG=""
    load_package 0
    assert equal "$PKG_SLUG|$PKG_NAME|$PKG_PRERELEASE|$PKG_ASSET_MATCHER|$PKG_VERSION|$PKG_AUTO_INSTALL" "o/full|custom|true|*.deb|v1.*|false"
    load_package 1
    assert equal "$PKG_SLUG|$PKG_NAME|$PKG_PRERELEASE|$PKG_ASSET_MATCHER|$PKG_VERSION|$PKG_AUTO_INSTALL" "o/bare|bare|false|*||true"
  end
end
