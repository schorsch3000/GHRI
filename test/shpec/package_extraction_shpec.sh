TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

TEST_CONFIG="$TEST_SANDBOX/tmp/ghri_test.yaml"

describe "Package count" do
  setup() {
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'EOF'
---
install_path: ./install
symlink_path: /tmp/symlinks
cache_path: ./cache
cache_lifetime_sec: 600
global_post_process:
  prepend: []
  append: []
packages:
  - slug: owner/repo1
    name: pkg1
    asset_matcher: "bin-*"
    post_process:
      - make_exec
      - link
    auto_install: true
  - slug: owner/repo2
    asset_matcher: "*.tar.gz"
    post_process:
      - gunzip
      - tar
    auto_install: false
  - slug: owner/repo3
    prerelease: true
    post_process:
      - name: testrun
        args:
          - --version
EOF
    CONFIG_FILE="$TEST_CONFIG"
  }

  teardown() {
    rm -rf "$TEST_SANDBOX/tmp"
  }

  it "returns correct package count" do
    setup
    result=$(get_pkg_count)
    assert equal "$result" "3"
    teardown
  end
end

describe "Package fields" do
  setup() {
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'EOF'
---
install_path: ./install
symlink_path: /tmp/symlinks
cache_path: ./cache
cache_lifetime_sec: 600
global_post_process:
  prepend: []
  append: []
packages:
  - slug: owner/repo1
    name: pkg1
    asset_matcher: "bin-*"
    post_process:
      - make_exec
      - link
    auto_install: true
  - slug: owner/repo2
    asset_matcher: "*.tar.gz"
    post_process:
      - gunzip
      - tar
    auto_install: false
  - slug: owner/repo3
    prerelease: true
    post_process:
      - name: testrun
        args:
          - --version
EOF
    CONFIG_FILE="$TEST_CONFIG"
  }

  teardown() {
    rm -rf "$TEST_SANDBOX/tmp"
  }

  it "reads slug" do
    setup
    result=$(get_pkg_field 0 "slug")
    assert equal "$result" "owner/repo1"
    teardown
  end

  it "reads name when set" do
    setup
    result=$(get_pkg_name 0)
    assert equal "$result" "pkg1"
    teardown
  end

  it "derives name from slug when not set" do
    setup
    result=$(get_pkg_name 1)
    assert equal "$result" "repo2"
    teardown
  end

  it "reads asset_matcher" do
    setup
    result=$(get_pkg_asset_matcher 0)
    assert equal "$result" "bin-*"
    teardown
  end

  it "defaults asset_matcher to *" do
    setup
    result=$(get_pkg_asset_matcher 2)
    assert equal "$result" "*"
    teardown
  end

  it "reads auto_install true" do
    setup
    result=$(get_pkg_auto_install 0)
    assert equal "$result" "true"
    teardown
  end

  it "reads auto_install false" do
    setup
    result=$(get_pkg_auto_install 1)
    assert equal "$result" "false"
    teardown
  end

  it "defaults auto_install to true when not set" do
    setup
    result=$(get_pkg_auto_install 2)
    assert equal "$result" "true"
    teardown
  end

  it "reads prerelease" do
    setup
    result=$(get_pkg_prerelease 2)
    assert equal "$result" "true"
    teardown
  end

  it "defaults prerelease to false" do
    setup
    result=$(get_pkg_prerelease 0)
    assert equal "$result" "false"
    teardown
  end
end

describe "Post-processor extraction" do
  setup() {
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'EOF'
---
install_path: ./install
symlink_path: /tmp/symlinks
cache_path: ./cache
cache_lifetime_sec: 600
global_post_process:
  prepend: []
  append: []
packages:
  - slug: owner/repo1
    name: pkg1
    post_process:
      - make_exec
      - link
      - name: testrun
        args:
          - --version
        quiet: false
  - slug: owner/repo2
    post_process:
      - gunzip
      - tar
      - link
  - slug: owner/repo3
    post_process:
      - name: testrun
        args:
          - -v
EOF
    CONFIG_FILE="$TEST_CONFIG"
  }

  teardown() {
    rm -rf "$TEST_SANDBOX/tmp"
  }

  it "counts post-processors" do
    setup
    result=$(get_pp_count 0)
    assert equal "$result" "3"
    teardown
  end

  it "gets post-processor names including scalars" do
    setup
    pp_names=$(get_post_process_names 0)
    assert present "$pp_names"
    teardown
  end

  it "handles scalar post-processors" do
    setup
    pp_names=$(get_post_process_names 0)
    assert_contains "$pp_names" 'make_exec'
    assert_contains "$pp_names" 'link'
    teardown
  end

  it "handles object post-processors" do
    setup
    pp_names=$(get_post_process_names 0)
    assert_contains "$pp_names" 'testrun'
    teardown
  end

  it "handles package with no post_process" do
    setup
    pp_names=$(get_post_process_names 2)
    assert present "$pp_names"
    teardown
  end

  it "gets post-processor config for object" do
    setup
    result=$(get_pp_config 0 2 "args")
    assert present "$result"
    teardown
  end

  it "handles scalar post-processor config" do
    setup
    result=$(get_pp_config 0 0 "args")
    assert blank "$result"
    teardown
  end
end