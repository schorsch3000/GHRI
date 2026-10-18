# fake_gh.sh - helpers to drive ghri.sh against test/fakes/gh (no network)
# shellcheck shell=bash

FAKE_BIN_DIR="$GHRI_DIR/test/fakes"

fake_gh_setup() {
  export GHRI_FAKE_DIR="$TEST_SANDBOX/fake"
  rm -rf "$GHRI_FAKE_DIR"
  mkdir -p "$GHRI_FAKE_DIR"
  case ":$PATH:" in
    *":$FAKE_BIN_DIR:"*) ;;
    *) PATH="$FAKE_BIN_DIR:$PATH" ;;
  esac
  FAIL=0
  FAILURES=()
}

# fake_release <owner/repo> <tag> <asset name> <file with content> [immutable] [digest override] [created_at] [prerelease]
# Creates latest.json, tags/<tag>.json and the downloadable asset.
fake_release() {
  local slug="$1" tag="$2" name="$3" src="$4" immutable="${5:-false}" digest="${6:-}"
  local created="${7:-2026-01-01T00:00:00Z}" pre="${8:-false}"
  local base="$GHRI_FAKE_DIR/$slug"
  mkdir -p "$base/tags" "$base/assets/$tag"
  cp "$src" "$base/assets/$tag/$name"
  [[ -n "$digest" ]] || digest="sha256:$(sha256sum "$src" | awk '{print $1}')"
  jq -n --arg tag "$tag" --arg name "$name" --arg digest "$digest" --argjson imm "$immutable" \
    --arg created "$created" --argjson pre "$pre" \
    '{tag_name: $tag, prerelease: $pre, immutable: $imm, created_at: $created,
      assets: [{name: $name, digest: $digest, browser_download_url: ("https://example.invalid/" + $name)}]}' \
    > "$base/tags/$tag.json"
  [[ "$pre" == "true" ]] || cp "$base/tags/$tag.json" "$base/latest.json"
  jq -s . "$base"/tags/*.json > "$base/list.json"
}

# fake_script <path> <version output> [exit code]: an executable that prints its version
fake_script() {
  printf '#!/bin/sh\necho "%s"\nexit %s\n' "$2" "${3:-0}" > "$1"
}

# fake_config <yaml body for packages...>: writes a ghri.yaml into the sandbox and loads it
fake_config() {
  mkdir -p "$TEST_SANDBOX/cfg"
  CONFIG_FILE="$TEST_SANDBOX/cfg/ghri.yaml"
  cat > "$CONFIG_FILE" <<YAML
install_path: $install_path
symlink_path: $symlink_path
cache_path: $cache_path
state_path: $state_path
cache_lifetime_sec: 0
$1
YAML
  _CONFIG_SIG=""
  load_config
  cache_lifetime=0
}

fake_calls() { cat "$GHRI_FAKE_DIR/calls.log" 2>/dev/null; }
