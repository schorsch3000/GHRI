# Tests for `add`, `edit` and `delete` (interactive config management). Input comes from
# stdin and a fake $EDITOR; GHRI_TEST_INTERACTIVE stands in for a terminal.
TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
GHRI_DIR="$(dirname "$TEST_DIR")"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/helpers.sh"
source "$(dirname "${BASH_SOURCE[0]:-$0}")/fake_gh.sh"

MGMT_BODY='# my tools
packages:
  # the first group
  - slug: acme/one
    name: one
    asset_matcher: one-linux
    post_process:
      - make_exec   # chmod
      - link

  #- slug: acme/disabled
  #  asset_matcher: x

  - slug: acme/two
    asset_matcher: two-linux
    post_process: [make_exec, link]
  - slug: acme/three
    asset_matcher: three-linux
    post_process:
      - make_exec
global_post_process:
  append: []
'

# mgmt_run <stdin text (printf %b)> <command...>: sets OUT (stdout+stderr, ANSI stripped) and RC
mgmt_run() {
  local answers="$1"
  shift
  OUT=$(
    printf '%b' "$answers" | GHRI_TEST_INTERACTIVE=1 "$@" 2>&1
    echo "RC=${PIPESTATUS[1]}"
  )
  RC="${OUT##*RC=}"
  OUT="${OUT%RC=*}"
  OUT=$(sed 's/\x1b\[[0-9;]*[a-zA-Z]//g; s/\x1b(B//g' <<<"$OUT")
}

# mgmt_world: fresh sandbox, fake gh and a commented config
mgmt_world() {
  rm -rf "$install_path" "$cache_path" "$state_path" "$symlink_path" "$TEST_SANDBOX/rel" "$TEST_SANDBOX/cfg"
  mkdir -p "$TEST_SANDBOX/rel"
  fake_gh_setup
  fake_config "$MGMT_BODY"
  cp "$CONFIG_FILE" "$TEST_SANDBOX/orig.yaml"
  ASSUME_YES=false
  unset VISUAL
}

# diff_lines: changed lines between the original and the current config ("-" removed, "+" added)
diff_lines() {
  diff --unchanged-line-format= --old-line-format='-%L' --new-line-format='+%L' "$TEST_SANDBOX/orig.yaml" "$CONFIG_FILE"
}

# make_editor <shell body using $1 as the file>: set $EDITOR to a script running it
make_editor() {
  printf '#!/bin/bash\n%s\n' "$1" >"$TEST_SANDBOX/ed.sh"
  chmod +x "$TEST_SANDBOX/ed.sh"
  export EDITOR="$TEST_SANDBOX/ed.sh"
}

describe "parse_args subcommands" do
it "recognises add, edit and delete" do
parse_args add acme/tool
assert equal "$MODE|$SUBARG" "add|acme/tool"
parse_args edit tool
assert equal "$MODE|$SUBARG" "edit|tool"
parse_args delete tool
assert equal "$MODE|$SUBARG" "delete|tool"
parse_args rm tool
assert equal "$MODE|$SUBARG" "delete|tool"
parse_args remove tool
assert equal "$MODE|$SUBARG" "delete|tool"
end

it "accepts --yes next to a subcommand" do
ASSUME_YES=false
parse_args delete tool --yes
assert equal "$MODE|$ASSUME_YES" "delete|true"
ASSUME_YES=false
end

it "requires exactly one argument" do
(parse_args edit) >/dev/null 2>&1
assert equal "$?" "2"
(parse_args delete a b) >/dev/null 2>&1
assert equal "$?" "2"
end

it "still treats other words as package names" do
parse_args one two
assert equal "$MODE|${TARGETS[*]}" "install|one two"
end
end

describe "delete" do
it "removes only that package and leaves comments and formatting alone" do
mgmt_world
ASSUME_YES=true
mgmt_run "" cmd_delete two
assert equal "$RC" "0"
assert_contains "$OUT" 'Deleted two from the config'
assert equal "$(diff_lines)" "$(printf -- '-  - slug: acme/two\n-    asset_matcher: two-linux\n-    post_process: [make_exec, link]')"
assert equal "$(yq '.packages | length' "$CONFIG_FILE")" "2"
assert equal "$([[ -f "$CONFIG_FILE.bak" ]] && cmp -s "$CONFIG_FILE.bak" "$TEST_SANDBOX/orig.yaml" && echo same)" "same"
end

it "removes the last package without touching the keys after it" do
mgmt_world
ASSUME_YES=true
mgmt_run "" cmd_delete three
assert equal "$(diff_lines)" "$(printf -- '-  - slug: acme/three\n-    asset_matcher: three-linux\n-    post_process:\n-      - make_exec')"
assert_contains "$(cat "$CONFIG_FILE")" 'append: []'
end

it "removes the first package and keeps the comments around it" do
mgmt_world
ASSUME_YES=true
mgmt_run "" cmd_delete one
assert_contains "$(cat "$CONFIG_FILE")" '# the first group'
assert_contains "$(cat "$CONFIG_FILE")" '#- slug: acme/disabled'
assert equal "$(yq '.packages[0].slug' "$CONFIG_FILE")" "acme/two"
end

it "finds a package by slug" do
mgmt_world
ASSUME_YES=true
mgmt_run "" cmd_delete acme/two
assert equal "$RC" "0"
assert equal "$(yq '.packages | length' "$CONFIG_FILE")" "2"
end

it "asks for confirmation and aborts on n" do
mgmt_world
mgmt_run 'n\n' cmd_delete two
assert_contains "$OUT" 'Delete'
assert_contains "$OUT" 'Aborted.'
assert equal "$(diff_lines)" ""
assert equal "$([[ -e "$CONFIG_FILE.bak" ]] && echo bak || echo none)" "none"
end

it "deletes on y" do
mgmt_world
mgmt_run 'y\n' cmd_delete two
assert equal "$(yq '.packages | length' "$CONFIG_FILE")" "2"
end

it "points at --prune for the installed files" do
mgmt_world
ASSUME_YES=true
mgmt_run "" cmd_delete two
assert_contains "$OUT" '--prune'
end

it "rejects unknown packages" do
mgmt_world
mgmt_run 'y\n' cmd_delete nosuch
assert equal "$RC" "1"
assert_contains "$OUT" 'Unknown package: nosuch'
assert equal "$(diff_lines)" ""
end

it "needs a terminal unless --yes is given" do
mgmt_world
OUT=$(cmd_delete two </dev/null 2>&1)
assert_contains "$OUT" 'needs a terminal'
assert equal "$(diff_lines)" ""
end
end

describe "edit" do
it "shows only the package, with its own comments" do
mgmt_world
make_editor 'cp "$1" '"$TEST_SANDBOX"'/seen.yaml'
mgmt_run "" cmd_edit one
assert equal "$(cat "$TEST_SANDBOX/seen.yaml")" "$(printf 'slug: acme/one\nname: one\nasset_matcher: one-linux\npost_process:\n  - make_exec   # chmod\n  - link')"
assert_contains "$OUT" 'No changes.'
end

it "replaces just that block with the edited text" do
mgmt_world
make_editor 'sed -i "s/two-linux/two-NEW/; s/^post_process:.*/post_process: [link]\nprerelease: true/" "$1"'
mgmt_run "" cmd_edit two
assert equal "$RC" "0"
assert_contains "$OUT" 'Updated two'
assert equal "$(diff_lines)" "$(printf -- '-    asset_matcher: two-linux\n-    post_process: [make_exec, link]\n+    asset_matcher: two-NEW\n+    post_process: [link]\n+    prerelease: true')"
assert equal "$(yq '.packages[1].prerelease' "$CONFIG_FILE")" "true"
end

it "keeps comments inside the edited block" do
mgmt_world
make_editor 'sed -i "s/one-linux/one-NEW/" "$1"'
mgmt_run "" cmd_edit one
assert_contains "$(cat "$CONFIG_FILE")" '- make_exec   # chmod'
assert_contains "$(cat "$CONFIG_FILE")" '#- slug: acme/disabled'
end

it "does nothing when the file is unchanged" do
mgmt_world
make_editor 'true'
mgmt_run "" cmd_edit two
assert_contains "$OUT" 'No changes.'
assert equal "$(diff_lines)" ""
assert equal "$([[ -e "$CONFIG_FILE.bak" ]] && echo bak || echo none)" "none"
end

it "refuses an invalid result and keeps the config" do
mgmt_world
make_editor 'sed -i "s/make_exec/frobnicate/" "$1"'
mgmt_run 'n\n' cmd_edit two
assert equal "$RC" "1"
assert_contains "$OUT" 'unknown post-processor "frobnicate"'
assert_contains "$OUT" 'Aborted; config unchanged.'
assert equal "$(diff_lines)" ""
end

it "lets you fix an invalid result and try again" do
mgmt_world
make_editor 'n=$(cat '"$TEST_SANDBOX"'/n 2>/dev/null || echo 0); echo $((n+1)) > '"$TEST_SANDBOX"'/n
if [ "$n" = 0 ]; then sed -i "s/make_exec/frobnicate/" "$1"; else sed -i "s/frobnicate/make_exec/; s/two-linux/two-FIXED/" "$1"; fi'
rm -f "$TEST_SANDBOX/n"
mgmt_run 'y\n' cmd_edit two
assert equal "$RC" "0"
assert_contains "$OUT" 'unknown post-processor "frobnicate"'
assert equal "$(yq '.packages[1].asset_matcher' "$CONFIG_FILE")" "two-FIXED"
end

it "refuses a result that is not a mapping" do
mgmt_world
make_editor 'echo "- just a list" > "$1"'
mgmt_run 'n\n' cmd_edit two
assert_contains "$OUT" 'must be a YAML mapping'
assert equal "$(diff_lines)" ""
end

it "rejects unknown packages and needs a terminal" do
mgmt_world
make_editor 'true'
mgmt_run "" cmd_edit nosuch
assert_contains "$OUT" 'Unknown package: nosuch'
OUT=$(cmd_edit two </dev/null 2>&1)
assert_contains "$OUT" 'needs a terminal'
end

it "reports a missing editor" do
mgmt_world
unset EDITOR VISUAL
# pretend no editor is installed
command() {
  if [[ "$1" == "-v" ]]; then
    case "$2" in editor | nano | vim | vi) return 1 ;; esac
  fi
  builtin command "$@"
}
mgmt_run "" cmd_edit two
unset -f command
assert_contains "$OUT" 'No editor found'
end
end

describe "add wizard helpers" do
it "suggests the linux x86_64 asset and skips checksums and other platforms" do
release_asset_names=("tool_1.0_darwin_arm64.tar.gz" "tool_1.0_checksums.txt" "tool_1.0_linux_arm64.tar.gz" "tool_1.0_linux_amd64.tar.gz" "tool_1.0_windows_amd64.zip")
release_asset_count=5
assert equal "$(suggest_asset_index)" "3"
end

it "suggests nothing when no asset looks right" do
release_asset_names=("notes.txt" "tool.exe")
release_asset_count=2
assert equal "$(suggest_asset_index)" ""
end

it "replaces the version in asset names by *" do
assert equal "$(generalize_asset_name "fq_0.18.0_linux_amd64.tar.gz" "v0.18.0")" "fq_*_linux_amd64.tar.gz"
assert equal "$(generalize_asset_name "tool-v1.2-linux" "v1.2")" "tool-*-linux"
assert equal "$(generalize_asset_name "tool-linux" "v1.2")" "tool-linux"
end

it "suggests post-processors per file type" do
assert equal "$(suggest_post_process x.deb "")" '["deb"]'
assert equal "$(suggest_post_process x.tar.gz bin)" '["gunzip", {"name": "tar", "asset_matcher": "bin"}, "make_exec", "link"]'
assert equal "$(suggest_post_process x.tar.xz bin)" '["xz", {"name": "tar", "asset_matcher": "bin"}, "make_exec", "link"]'
assert equal "$(suggest_post_process x.zip bin)" '[{"name": "unzip", "asset_matcher": "bin"}, "make_exec", "link"]'
assert equal "$(suggest_post_process x.gz "")" '["gunzip", "make_exec", "link"]'
assert equal "$(suggest_post_process x.AppImage "")" '["make_exec", "link"]'
end
end

# add_release <tag> <asset names...>: publish a release of acme/newtool with dummy assets
add_release() {
  local tag="$1" name
  shift
  for name in "$@"; do
    fake_script "$TEST_SANDBOX/rel/$name" "newtool $tag"
    fake_release acme/newtool "$tag" "$name" "$TEST_SANDBOX/rel/$name"
  done
  # latest.json lists only the last asset; rewrite it with all of them
  jq -n --arg tag "$tag" '{tag_name: $tag, prerelease: false, immutable: false, created_at: "2026-01-01T00:00:00Z", assets: []}' >"$GHRI_FAKE_DIR/acme/newtool/latest.json"
  for name in "$@"; do
    jq --arg n "$name" --arg d "sha256:$(sha256sum "$TEST_SANDBOX/rel/$name" | awk '{print $1}')" \
      '.assets += [{name: $n, digest: $d, browser_download_url: ("https://example.invalid/" + $n)}]' \
      "$GHRI_FAKE_DIR/acme/newtool/latest.json" >"$GHRI_FAKE_DIR/x.json"
    mv "$GHRI_FAKE_DIR/x.json" "$GHRI_FAKE_DIR/acme/newtool/latest.json"
  done
}

describe "slug_from_url" do
it "extracts owner/repo from github URLs" do
assert equal "$(slug_from_url https://github.com/a/b)" "a/b"
assert equal "$(slug_from_url http://www.github.com/a/b/)" "a/b"
assert equal "$(slug_from_url github.com/a/b.git)" "a/b"
assert equal "$(slug_from_url git@github.com:a/b.git)" "a/b"
assert equal "$(slug_from_url ssh://git@github.com/a/b.git)" "a/b"
assert equal "$(slug_from_url 'https://github.com/a/b/releases/tag/v1.0?x=1#y')" "a/b"
assert equal "$(slug_from_url a/b)" "a/b"
assert equal "$(slug_from_url https://gitlab.com/a/b)" "https://gitlab.com/a/b"
end
end

describe "add" do
it "walks through the wizard and appends a validated package" do
mgmt_world
add_release v1.2.3 newtool-v1.2.3-darwin-arm64.tar.gz newtool-v1.2.3-linux-amd64.tar.gz checksums.txt
# asset (default), matcher (default), name (default), archive file (default),
# testrun (default y), args (default), save (default y), install now: n
mgmt_run '\n\n\n\n\n\n\nn\n' cmd_add acme/newtool
assert equal "$RC" "0"
assert_contains "$OUT" 'Added acme/newtool'
assert equal "$(yq '.packages[3].slug' "$CONFIG_FILE")" "acme/newtool"
assert equal "$(yq '.packages[3].asset_matcher' "$CONFIG_FILE")" "newtool-*-linux-amd64.tar.gz"
assert equal "$(yq -o=json -I=0 '.packages[3].post_process' "$CONFIG_FILE")" '["gunzip",{"name":"tar","asset_matcher":"/(^|\\/)newtool$/"},"make_exec","link",{"name":"testrun","args":"--version"}]'
# nothing else changed
assert equal "$(diff_lines | grep -c '^-' || true)" "0"
assert_contains "$(cat "$CONFIG_FILE")" '#- slug: acme/disabled'
end

it "marks the suggested asset and lists all assets" do
mgmt_world
add_release v1.2.3 newtool-v1.2.3-darwin-arm64.tar.gz newtool-v1.2.3-linux-amd64.tar.gz
mgmt_run '\n\n\n\n\n\n\nn\n' cmd_add acme/newtool
assert_matches "$OUT" '\*  2\) newtool-v1\.2\.3-linux-amd64\.tar\.gz'
assert_matches "$OUT" '  1\) newtool-v1\.2\.3-darwin-arm64\.tar\.gz'
end

it "adds a deb package with just the deb step" do
mgmt_world
add_release v1.0 newtool_1.0_linux_amd64.deb
# asset, matcher, name, testrun n, save, install n
mgmt_run '\n\n\nn\n\nn\n' cmd_add acme/newtool
assert equal "$RC" "0"
assert equal "$(yq -o=json -I=0 '.packages[3].post_process' "$CONFIG_FILE")" '["deb"]'
assert equal "$(yq '.packages[3].asset_matcher' "$CONFIG_FILE")" "newtool_*_linux_amd64.deb"
end

it "uses a custom name and matcher and records the name" do
mgmt_world
add_release v1.0 newtool-v1.0-linux-amd64
# asset 1, matcher custom, name custom, testrun n, save, install n
mgmt_run '1\nnewtool-*-amd64\nnt\nn\n\nn\n' cmd_add acme/newtool
assert equal "$(yq '.packages[3].name' "$CONFIG_FILE")" "nt"
assert equal "$(yq '.packages[3].asset_matcher' "$CONFIG_FILE")" "newtool-*-amd64"
end

it "can install the new package right away" do
mgmt_world
add_release v1.0 newtool-v1.0-linux-amd64
# asset, matcher, name, testrun y, args, save, install y
mgmt_run '\n\n\n\n\n\n\ny\n' cmd_add acme/newtool
assert equal "$RC" "0"
assert_contains "$OUT" 'newtool installed (v1.0)'
assert equal "$("$symlink_path/newtool" --version)" "newtool v1.0"
end

it "lets you edit the generated package before saving" do
mgmt_world
add_release v1.0 newtool-v1.0-linux-amd64
make_editor 'echo "prerelease: true" >> "$1"'
# asset, matcher, name, testrun n, save: edit, (editor), install n
mgmt_run '\n\n\nn\ne\nn\n' cmd_add acme/newtool
assert equal "$RC" "0"
assert equal "$(yq '.packages[3].prerelease' "$CONFIG_FILE")" "true"
end

it "writes nothing when you answer n at the end" do
mgmt_world
add_release v1.0 newtool-v1.0-linux-amd64
mgmt_run '\n\n\nn\nn\n' cmd_add acme/newtool
assert equal "$RC" "1"
assert_contains "$OUT" 'nothing written'
assert equal "$(diff_lines)" ""
end

it "rejects a slug that is already configured" do
mgmt_world
mgmt_run "" cmd_add acme/two
assert equal "$RC" "1"
assert_contains "$OUT" 'already in the config'
end

it "rejects something that is not owner/repo" do
mgmt_world
mgmt_run "" cmd_add nonsense
assert equal "$RC" "1"
assert_contains "$OUT" 'not a repository slug'
end

it "accepts a github.com URL and extracts the slug" do
mgmt_world
mgmt_run "" cmd_add https://github.com/acme/two/releases/tag/v1
assert_contains "$OUT" 'acme/two is already in the config'
end

it "needs a terminal" do
mgmt_world
OUT=$(cmd_add acme/newtool </dev/null 2>&1)
assert_contains "$OUT" 'needs a terminal'
end

it "can continue by hand when the release cannot be fetched" do
mgmt_world
# release fetch fails (404): continue y, matcher, name, testrun n, save, install n
mgmt_run 'y\nmanual-linux\n\nn\n\nn\n' cmd_add acme/norelease
assert equal "$RC" "0"
assert equal "$(yq '.packages[3].asset_matcher' "$CONFIG_FILE")" "manual-linux"
end

it "stops when the release cannot be fetched and you decline" do
mgmt_world
mgmt_run 'n\n' cmd_add acme/norelease
assert equal "$RC" "1"
assert equal "$(diff_lines)" ""
end
end

describe "install command" do
it "takes any number of names, including add, edit and delete" do
parse_args install edit add delete
assert equal "$MODE|$INSTALL_ALL|${TARGETS[*]}" "install|false|edit add delete"
end

it "installs everything when no names follow" do
parse_args install
assert equal "$MODE|$INSTALL_ALL|${#TARGETS[@]}" "install|true|0"
end

it "treats only the first word as the command" do
parse_args install install
assert equal "$MODE|${TARGETS[*]}" "install|install"
end

it "combines with flags" do
FORCE=false QUIET=false
parse_args install --force -q tool
assert equal "$MODE|$FORCE|$QUIET|${TARGETS[*]}" "install|true|true|tool"
FORCE=false QUIET=false
end

it "installs a package that is named like a command" do
mgmt_world
publish_edit() {
  fake_script "$TEST_SANDBOX/rel/edit-linux" "edit v1"
  fake_release acme/edit v1 edit-linux "$TEST_SANDBOX/rel/edit-linux"
}
publish_edit
fake_config 'packages:
  - slug: acme/edit
    asset_matcher: edit-linux
    post_process: [make_exec, link]'
(
  SCRIPT_DIR="$TEST_SANDBOX/cfg"
  FAIL=0 FAILURES=()
  main install edit
) >"$TEST_SANDBOX/out.txt" 2>&1
assert equal "$?" "0"
assert_contains "$(cat "$TEST_SANDBOX/out.txt")" 'edit installed (v1)'
assert equal "$("$symlink_path/edit" --version)" "edit v1"
end

it "still treats a bare 'edit' as the edit command" do
mgmt_world
OUT=$(
  SCRIPT_DIR="$TEST_SANDBOX/cfg"
  main edit </dev/null 2>&1
)
assert_contains "$OUT" 'Usage: '
end
end
