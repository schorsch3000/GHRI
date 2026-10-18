TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

PP_TEST_DIR="$TEST_SANDBOX/tmp/pp_test"

cleanup_pp_test() {
  rm -rf "$PP_TEST_DIR"
}

describe "make_exec post-processor" do
  it "makes file executable" do
    mkdir -p "$PP_TEST_DIR"
    echo "test" > "$PP_TEST_DIR/test_binary"
    chmod 644 "$PP_TEST_DIR/test_binary"
    pp_make_exec "$PP_TEST_DIR/test_binary"
    local perms=$(stat -c %a "$PP_TEST_DIR/test_binary")
    assert equal "$perms" "755"
    cleanup_pp_test
  end
end

describe "link post-processor" do
  it "creates symlink" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/target" "$PP_TEST_DIR/links"
    echo "test" > "$PP_TEST_DIR/target/actual_binary"
    symlink_path="$PP_TEST_DIR/links"
    CURRENT_ASSET="$PP_TEST_DIR/target/actual_binary"
    pp_link "$PP_TEST_DIR/target/actual_binary" "test_pkg"
    assert file_present "$symlink_path/test_pkg"
    cleanup_pp_test
  end

  it "symlink points to correct target" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/target" "$PP_TEST_DIR/links"
    echo "test" > "$PP_TEST_DIR/target/actual_binary"
    symlink_path="$PP_TEST_DIR/links"
    CURRENT_ASSET="$PP_TEST_DIR/target/actual_binary"
    pp_link "$PP_TEST_DIR/target/actual_binary" "test_pkg"
    local link_target=$(readlink "$symlink_path/test_pkg")
    assert equal "$link_target" "$PP_TEST_DIR/target/actual_binary"
    cleanup_pp_test
  end

  it "replaces existing symlink" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/target" "$PP_TEST_DIR/links"
    echo "test" > "$PP_TEST_DIR/target/actual_binary"
    symlink_path="$PP_TEST_DIR/links"
    ln -sf /tmp/old_target "$symlink_path/test_pkg"
    CURRENT_ASSET="$PP_TEST_DIR/target/actual_binary"
    pp_link "$PP_TEST_DIR/target/actual_binary" "test_pkg"
    local link_target=$(readlink "$symlink_path/test_pkg")
    assert equal "$link_target" "$PP_TEST_DIR/target/actual_binary"
    cleanup_pp_test
  end
end

describe "check_in_path post-processor" do
  it "succeeds when command is in PATH" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/links"
    printf '#!/bin/sh\n' > "$PP_TEST_DIR/links/test_pkg"
    chmod +x "$PP_TEST_DIR/links/test_pkg"
    local old_path="$PATH"
    PATH="$PP_TEST_DIR/links:$PATH"
    pp_check_in_path "$PP_TEST_DIR/unused" "test_pkg"
    local rc=$?
    PATH="$old_path"
    assert equal "$rc" "0"
    cleanup_pp_test
  end

  it "succeeds for system-installed command without symlink" do
    pp_check_in_path "/nonexistent/asset" "ls"
    local rc=$?
    assert equal "$rc" "0"
  end

  it "fails when command is not in PATH" do
    pp_check_in_path "/nonexistent/asset" "definitely_not_a_command_xyz"
    local rc=$?
    assert equal "$rc" "1"
  end
end

describe "api_get" do
  it "serves fresh cached response without network" do
    cleanup_pp_test
    cache_path="$PP_TEST_DIR/cache"
    cache_lifetime=600
    mkdir -p "$cache_path/api"
    printf '{"tag_name":"v1"}' > "$cache_path/api/_repos_o_r_releases_latest.json"
    local out
    out=$(api_get "/repos/o/r/releases/latest")
    assert equal "$out" '{"tag_name":"v1"}'
    cleanup_pp_test
  end
end

describe "testrun post-processor" do
  it "executes linked binary" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/links" "$PP_TEST_DIR/target"
    cat > "$PP_TEST_DIR/target/actual_binary" <<'SCRIPT'
#!/bin/bash
echo "test output"
exit 0
SCRIPT
    chmod +x "$PP_TEST_DIR/target/actual_binary"
    ln -sf "$PP_TEST_DIR/target/actual_binary" "$PP_TEST_DIR/links/test_pkg"
    symlink_path="$PP_TEST_DIR/links"
    local output=$(pp_testrun "$PP_TEST_DIR/target/actual_binary" "test_pkg")
    local rc=$?
    assert equal "$rc" "0"
    assert present "$output"
    cleanup_pp_test
  end

  it "returns success on exit 0" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/links" "$PP_TEST_DIR/target"
    cat > "$PP_TEST_DIR/target/actual_binary" <<'SCRIPT'
#!/bin/bash
exit 0
SCRIPT
    chmod +x "$PP_TEST_DIR/target/actual_binary"
    ln -sf "$PP_TEST_DIR/target/actual_binary" "$PP_TEST_DIR/links/test_pkg"
    symlink_path="$PP_TEST_DIR/links"
    pp_testrun "$PP_TEST_DIR/target/actual_binary" "test_pkg"
    local rc=$?
    assert equal "$rc" "0"
    cleanup_pp_test
  end
end

describe "Post-processor runner" do
  it "is a function" do
    assert is_function run_post_processors
  end
end
describe "testrun arguments" do
  it "passes args as separate words without eval" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/links"
    cat > "$PP_TEST_DIR/links/real" <<'SCRIPT'
#!/bin/bash
printf '%s|' "$#" "$@"
SCRIPT
    chmod +x "$PP_TEST_DIR/links/real"
    ln -sf "$PP_TEST_DIR/links/real" "$PP_TEST_DIR/links/test_pkg"
    symlink_path="$PP_TEST_DIR/links"
    local output
    output=$(pp_testrun "unused" "test_pkg" "wd" "*" "false" "--flag" "two words; echo pwned")
    assert equal "$output" "2|--flag|two words; echo pwned|"
    cleanup_pp_test
  end

  it "fails on non-zero exit" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/links"
    printf "#!/bin/bash\nexit 3\n" > "$PP_TEST_DIR/links/real"
    chmod +x "$PP_TEST_DIR/links/real"
    ln -sf "$PP_TEST_DIR/links/real" "$PP_TEST_DIR/links/test_pkg"
    symlink_path="$PP_TEST_DIR/links"
    pp_testrun "unused" "test_pkg" "wd" "*" "false" >/dev/null 2>&1
    assert equal "$?" "1"
    cleanup_pp_test
  end
end

describe "post-processor config parsing" do
  it "reads scalar and list args and matchers via get_pp_specs" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR"
    cat > "$PP_TEST_DIR/c.yaml" <<'YAML'
packages:
  - slug: o/r
    post_process:
      - make_exec
      - name: tar
        asset_matcher: bin
      - name: testrun
        args: -V
      - name: testrun
        args:
          - --version
          - two words
YAML
    CONFIG_FILE="$PP_TEST_DIR/c.yaml"
    local specs
    specs=$(get_pp_specs 0 | tr '\037' '|')
    assert equal "$specs" $'make_exec||false\ntar|bin|false\ntestrun||false|-V\ntestrun||false|--version|two words'
    cleanup_pp_test
  end
end

describe "run_post_processors" do
  it "runs the chain, passing matcher/args and CURRENT_ASSET between processors" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/work"
    cat > "$PP_TEST_DIR/c.yaml" <<'YAML'
packages:
  - slug: o/r
    post_process:
      - name: record
        asset_matcher: m*
        args: [a, "b c"]
YAML
    CONFIG_FILE="$PP_TEST_DIR/c.yaml"
    pp_record() { printf '%s\n' "$*" >> "$PP_TEST_DIR/calls"; CURRENT_ASSET="changed"; }
    pp_after() { printf 'after:%s\n' "$1" >> "$PP_TEST_DIR/calls"; }
    global_prepend=()
    global_append=(after)
    FAIL=0 FAILURES=()
    run_post_processors 0 "$PP_TEST_DIR/work" "orig" "pkg" >/dev/null 2>&1
    local rc=$?
    assert equal "$rc" "0"
    assert equal "$(cat "$PP_TEST_DIR/calls")" $'orig pkg '"$PP_TEST_DIR/work"$' m* false a b c\nafter:changed'
    unset -f pp_record pp_after
    global_append=()
    cleanup_pp_test
  end

  it "counts a failing processor and stops the chain" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR"
    cat > "$PP_TEST_DIR/c.yaml" <<'YAML'
packages:
  - slug: o/r
    post_process: [boom, never]
YAML
    CONFIG_FILE="$PP_TEST_DIR/c.yaml"
    pp_boom() { return 1; }
    pp_never() { touch "$PP_TEST_DIR/ran"; }
    global_prepend=() global_append=()
    FAIL=0 FAILURES=()
    run_post_processors 0 "$PP_TEST_DIR" "x" "pkg" >/dev/null 2>&1
    assert equal "$?" "1"
    assert equal "$FAIL" "1"
    assert equal "${FAILURES[0]}" "pkg (boom)"
    assert equal "$([[ -e "$PP_TEST_DIR/ran" ]] && echo yes || echo no)" "no"
    unset -f pp_boom pp_never
    FAIL=0 FAILURES=()
    cleanup_pp_test
  end
end

describe "deb post-processor" do
  it "fails without prompting when not interactive" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/bin"
    printf '#!/bin/bash\nexit 1\n' > "$PP_TEST_DIR/bin/sudo"
    chmod +x "$PP_TEST_DIR/bin/sudo"
    local old_path="$PATH"
    PATH="$PP_TEST_DIR/bin:$PATH"
    pp_deb "x.deb" "pkg" </dev/null >/dev/null 2>&1
    local rc=$?
    PATH="$old_path"
    assert equal "$rc" "1"
    cleanup_pp_test
  end

  it "succeeds when dpkg succeeds" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/bin"
    printf '#!/bin/bash\nexit 0\n' > "$PP_TEST_DIR/bin/sudo"
    chmod +x "$PP_TEST_DIR/bin/sudo"
    local old_path="$PATH"
    PATH="$PP_TEST_DIR/bin:$PATH"
    pp_deb "x.deb" "pkg" </dev/null >/dev/null 2>&1
    local rc=$?
    PATH="$old_path"
    assert equal "$rc" "0"
    cleanup_pp_test
  end
end

describe "cleanup_old_versions" do
  it "keeps only the given version directory" do
    cleanup_pp_test
    install_path="$PP_TEST_DIR/install"
    mkdir -p "$install_path/o_r/v1" "$install_path/o_r/v2" "$install_path/o_r/v3"
    cleanup_old_versions "$install_path/o_r" "v2" >/dev/null
    assert equal "$(ls "$install_path/o_r")" "v2"
    cleanup_pp_test
  end

  it "refuses to touch paths outside install_path" do
    cleanup_pp_test
    install_path="$PP_TEST_DIR/install"
    mkdir -p "$PP_TEST_DIR/other/v1" "$install_path"
    cleanup_old_versions "$PP_TEST_DIR/other" "v2" >/dev/null
    assert equal "$(ls "$PP_TEST_DIR/other")" "v1"
    cleanup_pp_test
  end
end

describe "testrun quiet option" do
  it "suppresses the output line when quiet is true" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR/links"
    printf '#!/bin/sh\necho noisy output\n' > "$PP_TEST_DIR/links/real"
    chmod +x "$PP_TEST_DIR/links/real"
    ln -sf "$PP_TEST_DIR/links/real" "$PP_TEST_DIR/links/test_pkg"
    symlink_path="$PP_TEST_DIR/links"
    assert equal "$(pp_testrun x test_pkg wd '*' true)" ""
    assert equal "$(pp_testrun x test_pkg wd '*' false)" "noisy output"
    cleanup_pp_test
  end

  it "is read from the config by get_pp_specs" do
    cleanup_pp_test
    mkdir -p "$PP_TEST_DIR"
    printf 'packages:\n  - slug: o/r\n    post_process:\n      - name: testrun\n        quiet: true\n        args: [--help]\n' > "$PP_TEST_DIR/c.yaml"
    CONFIG_FILE="$PP_TEST_DIR/c.yaml"
    _CONFIG_SIG=""
    assert equal "$(get_pp_specs 0 | tr '\037' '|')" "testrun||true|--help"
    cleanup_pp_test
  end
end
