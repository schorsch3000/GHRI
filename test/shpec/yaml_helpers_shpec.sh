TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"

TEST_FILE="$TEST_SANDBOX/tmp/ghri_test.yaml"

describe "YAML helpers" do
  setup() {
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_FILE" <<'EOF'
---
string_field: "hello"
number_field: 42
bool_field: true
null_field: null
empty_field:
quoted_field: "'single quotes'"
array_field:
  - item1
  - item2
  - item3
EOF
    CONFIG_FILE="$TEST_FILE"
  }

  teardown() {
    rm -rf "$TEST_SANDBOX/tmp"
  }

  it "reads scalar fields" do
    setup
    result=$(yaml_field '.string_field')
    assert equal "$result" "hello"
    teardown
  end

  it "strips quotes from scalar values" do
    setup
    result=$(yaml_field '.quoted_field')
    assert equal "$result" "single quotes"
    teardown
  end

  it "returns empty for null fields" do
    setup
    result=$(yaml_field '.null_field')
    assert blank "$result"
    teardown
  end

  it "returns empty for empty fields" do
    setup
    result=$(yaml_field '.empty_field')
    assert blank "$result"
    teardown
  end

  it "reads array length" do
    setup
    result=$(yaml_array_length '.array_field | length')
    assert equal "$result" "3"
    teardown
  end
end

describe "Field defaults" do
  setup() {
    mkdir -p "$TEST_SANDBOX/tmp"
    cat > "$TEST_FILE" <<'EOF'
---
string_field: "hello"
packages:
  - slug: test/repo
    name: pkg
    asset_matcher: "*"
    post_process: []
EOF
    CONFIG_FILE="$TEST_FILE"
  }

  teardown() {
    rm -rf "$TEST_SANDBOX/tmp"
  }

  it "returns default for missing field" do
    setup
    result=$(yaml_field_default '.nonexistent_field' '"default_value"')
    assert equal "$result" "default_value"
    teardown
  end

  it "returns actual value for existing field" do
    setup
    result=$(yaml_field_default '.string_field' '"default"')
    assert equal "$result" "hello"
    teardown
  end
end

describe "Value cleaning" do
  it "strips double quotes" do
    result=$(clean_val '"hello"')
    assert equal "$result" "hello"
  end

  it "strips single quotes" do
    result=$(clean_val "'hello'")
    assert equal "$result" "hello"
  end

  it "returns empty for null" do
    result=$(clean_val 'null')
    assert blank "$result"
  end

  it "returns empty for tilde" do
    result=$(clean_val '~')
    assert blank "$result"
  end

  it "returns empty for empty string" do
    result=$(clean_val '')
    assert blank "$result"
  end

  it "preserves normal strings" do
    result=$(clean_val 'hello')
    assert equal "$result" "hello"
  end
end