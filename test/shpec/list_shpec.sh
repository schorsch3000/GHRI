# Tests for `list` and `list -v`
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/fake_gh.sh"

LIST_BODY='packages:
  - slug: acme/one
    name: uno
    asset_matcher: one
  - slug: acme/two
    desc: from config
    asset_matcher: two
  - slug: acme/three
    asset_matcher: three
'

list_world() {
  fake_gh_setup
  rm -rf "$cache_path"
  fake_config "$LIST_BODY"
  mkdir -p "$GHRI_FAKE_DIR/acme/one"
  printf '{"description":"The first tool, which has a long about text"}\n' >"$GHRI_FAKE_DIR/acme/one/repo.json"
}

describe "list" do
it "parses without arguments" do
parse_args list -v
assert equal "$MODE|$VERBOSE" "list|true"
VERBOSE=false
end

it "rejects arguments" do
out=$(bash "$GHRI_DIR/ghri.sh" list foo 2>&1)
assert equal "$?" "2"
end

it "prints name and slug per line" do
list_world
out=$(do_list)
assert_contains "$out" "uno"
assert_contains "$out" "uno                  acme/one"
assert_contains "$out" "three                acme/three"
assert equal "$(wc -l <<<"$out")" "3"
end

it "prints markdown with descriptions with -v" do
list_world
VERBOSE=true
out=$(do_list 2>/dev/null)
VERBOSE=false
assert_contains "$out" "# acme/one `uno`"
assert_contains "$out" "The first tool, which has a long about text"
assert_contains "$out" "# acme/two `two`"
assert_contains "$out" "from config"
assert_contains "$out" "# acme/three `three`"
assert_contains "$out" "**No description.**"
end
end
