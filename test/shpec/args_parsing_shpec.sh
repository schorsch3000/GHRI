
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

describe "Argument parsing" do
  it "parses --list as alias of --outdated" do
    parse_args --list
    assert equal "$MODE" "outdated"
  end

  it "parses -l flag" do
    parse_args -l
    assert equal "$MODE" "outdated"
  end

  it "parses --dry-run as alias of --outdated" do
    parse_args --dry-run
    assert equal "$MODE" "outdated"
  end

  it "parses -n flag" do
    parse_args -n
    assert equal "$MODE" "outdated"
  end

  it "parses package names" do
    parse_args mypackage
    assert present "$(printf '%s\n' "${TARGETS[@]}" | grep 'mypackage')"
  end

  it "parses multiple package names" do
    parse_args pkg1 pkg2 pkg3
    assert gt "${#TARGETS[@]}" 2
  end

  it "defaults to install mode with no args" do
    parse_args
    assert equal "$MODE" "install"
  end

  it "sets INSTALL_ALL when no args" do
    parse_args
    assert equal "$INSTALL_ALL" "true"
  end

  it "clears TARGETS when no args" do
    parse_args
    assert equal "${#TARGETS[@]}" "0"
  end

  it "combines flags with package names" do
    parse_args --dry-run mypackage
    assert equal "$MODE" "outdated"
    assert present "$(printf '%s\n' "${TARGETS[@]}" | grep 'mypackage')"
  end
end

describe "Help" do
  it "has show_help function" do
    assert is_function show_help
  end

  it "displays usage information" do
    output=$(show_help 2>&1)
    assert_contains "$output" 'Usage:'
  end

  it "mentions --list option" do
    output=$(show_help 2>&1)
    assert_contains "$output" '--list'
  end

  it "mentions --dry-run option" do
    output=$(show_help 2>&1)
    assert_contains "$output" '--dry-run'
  end

  it "mentions --check, --force and --verbose" do
    output=$(show_help 2>&1)
    assert_contains "$output" '--check'
    assert_contains "$output" '--force'
    assert_contains "$output" '--verbose'
  end
end

describe "New flags" do
  it "parses --check" do
    parse_args --check
    assert equal "$MODE" "check"
  end

  it "parses --force and --verbose" do
    FORCE=false VERBOSE=false
    parse_args -f -v
    assert equal "$FORCE" "true"
    assert equal "$VERBOSE" "true"
    FORCE=false VERBOSE=false
  end

  it "selects all packages when only flags are given" do
    parse_args --outdated
    assert equal "$INSTALL_ALL" "true"
  end

  it "rejects unknown options" do
    (parse_args --bogus) >/dev/null 2>&1
    assert equal "$?" "2"
  end
end

describe "package_selected" do
  it "skips auto_install: false packages in bare invocation" do
    CONFIG_FILE="$TEST_SANDBOX/sel.yaml"
    mkdir -p "$TEST_SANDBOX"
    printf 'packages:\n  - slug: o/a\n  - slug: o/b\n    auto_install: false\n' > "$CONFIG_FILE"
    _CONFIG_SIG=""
    parse_args
    package_selected 0 a
    assert equal "$?" "0"
    package_selected 1 b
    assert equal "$?" "1"
  end

  it "selects an auto_install: false package when named" do
    CONFIG_FILE="$TEST_SANDBOX/sel.yaml"
    _CONFIG_SIG=""
    parse_args b
    package_selected 1 b
    assert equal "$?" "0"
    package_selected 0 a
    assert equal "$?" "1"
  end
end
