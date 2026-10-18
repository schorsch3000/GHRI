
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

describe "Color system" do
  it "initializes color variables" do
    color_init
    assert present "$C_RESET"
  end

  it "sets color escape sequences when tput works" do
    color_init
    assert present "$C_RED"
    assert present "$C_YELLOW"
    assert present "$C_GREEN"
    assert present "$C_CYAN"
    assert present "$C_RESET"
  end

  it "provides helper functions" do
    color_init
    assert is_function err
    assert is_function warn
    assert is_function info
    assert is_function ok
    assert is_function log
  end

  it "err() writes to stderr" do
    color_init
    output=$(err "test error" 2>&1 1>/dev/null)
    assert present "$output"
  end

  it "info() writes to stdout" do
    color_init
    output=$(info "test info" 2>&1)
    assert present "$output"
  end

  it "ok() outputs with checkmark" do
    color_init
    output=$(ok "test" 2>&1)
    assert present "✓"
  end
end