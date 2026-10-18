# config_shpec.sh - Tests for config loading

source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

TEST_CONFIG="$TEST_SANDBOX/tmp/ghri_test.yaml"

describe "Config loading" do
  it "loads config file" do
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'YAML'
---
install_path: ./install
symlink_path: /tmp/test_symlinks
cache_path: ./cache
cache_lifetime_sec: 300
global_post_process:
  prepend:
    - make_exec
  append:
    - check_in_path
packages:
  - slug: test/repo1
    name: pkg1
    asset_matcher: "binary-*"
    post_process:
      - make_exec
      - link
    auto_install: true
YAML
    CONFIG_FILE="$TEST_CONFIG"
    load_config
    assert present "$install_path"
    rm -rf "$TEST_SANDBOX/tmp"
  end

  it "loads global paths" do
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'YAML'
---
install_path: ./install
symlink_path: /tmp/test_symlinks
cache_path: ./cache
cache_lifetime_sec: 300
global_post_process:
  prepend: []
  append: []
packages: []
YAML
    CONFIG_FILE="$TEST_CONFIG"
    load_config
    assert present "$install_path"
    assert present "$cache_path"
    assert present "$symlink_path"
    rm -rf "$TEST_SANDBOX/tmp"
  end

  it "sets cache_lifetime from config" do
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'YAML'
---
install_path: ./install
symlink_path: /tmp/symlinks
cache_path: ./cache
cache_lifetime_sec: 300
global_post_process:
  prepend: []
  append: []
packages: []
YAML
    CONFIG_FILE="$TEST_CONFIG"
    load_config
    assert present "$cache_lifetime"
    rm -rf "$TEST_SANDBOX/tmp"
  end

  it "loads global_post_process.prepend" do
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'YAML'
---
install_path: ./install
symlink_path: /tmp/symlinks
cache_path: ./cache
cache_lifetime_sec: 300
global_post_process:
  prepend:
    - make_exec
    - test
  append: []
packages: []
YAML
    CONFIG_FILE="$TEST_CONFIG"
    load_config
    assert present "${#global_prepend[@]}"
    rm -rf "$TEST_SANDBOX/tmp"
  end

  it "loads global_post_process.append" do
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_CONFIG" <<'YAML'
---
install_path: ./install
symlink_path: /tmp/symlinks
cache_path: ./cache
cache_lifetime_sec: 300
global_post_process:
  prepend: []
  append:
    - check_in_path
    - verify
packages: []
YAML
    CONFIG_FILE="$TEST_CONFIG"
    load_config
    assert present "${#global_append[@]}"
    rm -rf "$TEST_SANDBOX/tmp"
  end
end

describe "Config error handling" do
  it "errors when config not found" do
    result=$(CONFIG_FILE="/nonexistent/path/ghri.yaml" load_config 2>&1)
    assert present "$result"
  end
end
