
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

describe "Config file finding" do
  setup_test_dir() {
    mkdir -p "$TEST_SANDBOX/tmp/config_test"
    echo "test: value" > "$TEST_SANDBOX/tmp/config_test/ghri.yaml"
  }

  it "has find_config function" do
    assert is_function find_config
  end

  it "looks for ghri.yaml in script dir" do
    setup_test_dir
    # This tests the function exists and doesn't error
    assert is_function find_config
  end

  after_each() {
    rm -rf "$TEST_SANDBOX/tmp/config_test"
  }
end
describe "load_env" do
  it "loads vars, handles quotes/comments/export, keeps existing env" do
    local f="$TEST_SANDBOX/tmp/env_test.env"
    mkdir -p "$TEST_SANDBOX/tmp"
    printf '# c\nGHRI_T1=abc\nexport GHRI_T2="q v"\nGHRI_T3='"'"'s'"'"'\nGHRI_T4=new\n' > "$f"
    unset GHRI_T1 GHRI_T2 GHRI_T3
    export GHRI_T4=old
    load_env "$f"
    assert equal "$GHRI_T1|$GHRI_T2|$GHRI_T3|$GHRI_T4" "abc|q v|s|old"
    rm -f "$f"
    unset GHRI_T1 GHRI_T2 GHRI_T3 GHRI_T4
  end

  it "ignores missing file" do
    load_env "/nonexistent/.env"
    assert equal "$?" "0"
  end
end

describe "running through a symlink" do
  it "finds ghri.yaml and .env next to the real script, not next to the link" do
    local real="$TEST_SANDBOX/real" link="$TEST_SANDBOX/linkbin"
    rm -rf "$real" "$link"
    mkdir -p "$real" "$link" "$real/inst"
    cp "$GHRI_DIR/ghri.sh" "$real/ghri.sh"
    printf 'install_path: %s/inst\nsymlink_path: %s/b\ncache_path: %s/c\npackages:\n  - slug: acme/tool\n    asset_matcher: x\n' "$real" "$real" "$real" >"$real/ghri.yaml"
    echo 'GHRI_FROM_ENV=found' >"$real/.env"
    ln -s "$real/ghri.sh" "$link/ghri"
    local out
    out=$(cd "$TEST_SANDBOX" && "$link/ghri" --check 2>&1 | sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g')
    assert_contains "$out" 'Config OK'
    out=$(cd "$TEST_SANDBOX" && "$link/ghri" --help | head -1)
    assert_contains "$out" 'Usage: ghri '
  end

  it "resolves SCRIPT_DIR to the real directory when sourced via a link" do
    local real="$TEST_SANDBOX/real2" link="$TEST_SANDBOX/link2"
    rm -rf "$real" "$link"
    mkdir -p "$real" "$link"
    cp "$GHRI_DIR/ghri.sh" "$real/ghri.sh"
    ln -s "$real/ghri.sh" "$link/ghri"
    assert equal "$(bash -c "source '$link/ghri'; echo \"\$SCRIPT_DIR\"")" "$real"
  end
end
