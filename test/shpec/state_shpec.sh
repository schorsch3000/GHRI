# Installed-state records (state_path) and the migration of records from cache_path
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

STATE_TEST_DIR="$TEST_SANDBOX/tmp/state_test"

state_setup() {
  rm -rf "$STATE_TEST_DIR"
  mkdir -p "$STATE_TEST_DIR"
  state_path="$STATE_TEST_DIR/state"
  cache_path="$STATE_TEST_DIR/cache"
}

describe "State paths" do
  it "converts slug to a directory name" do
    assert equal "$(slug_to_dir "owner/repo")" "owner_repo"
  end

  it "handles multi-segment slugs" do
    assert equal "$(slug_to_dir "org/sub/repo")" "org_sub_repo"
  end

  it "puts records in state_path, not in cache_path" do
    state_setup
    assert equal "$(state_file "owner/repo")" "$state_path/owner_repo/release.dat"
  end
end

describe "State write" do
  it "writes the record" do
    state_setup
    state_write "owner/repo" "v1.0.0" "false" "binary-linux" "https://example.com/binary"
    assert file_present "$state_path/owner_repo/release.dat"
  end

  it "writes the expected fields" do
    state_setup
    state_write "test/pkg" "v2.0" "true" "app" "https://example.com/app"
    content=$(cat "$state_path/test_pkg/release.dat")
    assert_contains "$content" 'tag_name=v2.0'
    assert_contains "$content" 'prerelease=true'
    assert_contains "$content" 'asset_name=app'
    assert_contains "$content" 'download_url=https://example.com/app'
  end

  it "creates the directory if missing" do
    state_setup
    state_path="$STATE_TEST_DIR/nonexistent/deeper"
    state_write "new/pkg" "v1.0" "false" "app" "https://example.com/app"
    assert file_present "$state_path/new_pkg/release.dat"
  end
end

describe "State read" do
  it "reads the record" do
    state_setup
    state_write "test/pkg" "v1.5.0" "true" "app" "https://example.com/app"
    state_read "test/pkg"
    assert equal "$?" "0"
    assert equal "$state_tag" "v1.5.0"
  end

  it "fails when the package is not recorded" do
    state_setup
    state_read "nonexistent/pkg"
    assert equal "$?" "1"
    assert equal "$state_tag" ""
  end

  it "migrates a record that still lives in cache_path" do
    state_setup
    mkdir -p "$cache_path/old_pkg"
    printf 'tag_name=v0.9\nprerelease=false\nasset_name=a\ndownload_url=u\n' >"$cache_path/old_pkg/release.dat"
    state_read "old/pkg"
    assert equal "$?" "0"
    assert equal "$state_tag" "v0.9"
    assert file_present "$state_path/old_pkg/release.dat"
    assert equal "$([[ -e "$cache_path/old_pkg" ]] && echo left || echo moved)" "moved"
  end

  it "prefers the record in state_path over a legacy one" do
    state_setup
    state_write "o/r" "v2" "false" "a" "u"
    mkdir -p "$cache_path/o_r"
    printf 'tag_name=v1\n' >"$cache_path/o_r/release.dat"
    state_read "o/r"
    assert equal "$state_tag" "v2"
  end
end
