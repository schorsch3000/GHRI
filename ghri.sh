#!/usr/bin/env bash
# ghri.sh — GitHub Release Installer (bash rewrite)
# Replaces ghri.php. Drop-in compatible with existing ghri.yaml.
set -o pipefail

# ─── Globals ──────────────────────────────────────────────────────────────────
FAIL=0
FAILURES=()
VERBOSE=false          # -v: show full per-package output instead of one line each
FORCE=false            # -f: reinstall even if the installed version is current
NO_CACHE=false         # --no-cache: ask GitHub again, ignore cached API responses
QUIET=false            # -q: only report changes and failures
ASSUME_YES=false       # -y: do not ask before --prune deletes
OUTDATED_COUNT=0       # packages --outdated found not current (exit code 10)
EXPLICIT_INSTALL=false # set by the `install` command; nothing is installed without it
JSON=false             # --json: machine-readable --outdated
VERSION="0.1.0"
gh_timeout=60        # timeout_sec: limit for each GitHub API call
download_timeout=900 # download_timeout_sec: limit for each asset download
TMP_DIR=""           # per-run temp dir (init_run)
CURRENT_PART=""      # partial download to remove on exit
PENDING_LINK=""      # symlink being updated, restored on exit if the update is cut short
PENDING_PREV=""
LAST_ERROR="" # message of the most recent err() call
# Directory of the real script (symlinks such as ~/bin/ghri are resolved), where ghri.yaml and .env live
SCRIPT_DIR="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"
CONFIG_FILE=""
CURRENT_ASSET="" # File the post-processor pipeline is currently working on (updated by processors that change it)

# Color placeholders (set by color_init)
C_RED="" C_YELLOW="" C_GREEN="" C_CYAN="" C_RESET=""

# ─── Color System ─────────────────────────────────────────────────────────────
color_init() {
  if tput setaf 0 >/dev/null 2>&1; then
    C_RED=$(tput setaf 1)
    C_YELLOW=$(tput setaf 3)
    C_GREEN=$(tput setaf 2)
    C_CYAN=$(tput setaf 6)
    C_RESET=$(tput sgr0)
  fi
}

log() { printf '%s\n' "${C_RESET}${*}${C_RESET}"; }
err() {
  LAST_ERROR="$*"
  printf '%s\n' "${C_RED}ERROR${C_RESET}: ${C_YELLOW}${*}${C_RESET}" >&2
}
warn() { printf '%s\n' "${C_YELLOW}Warning${C_RESET}: ${C_RESET}${*}"; }
info() { printf '%s\n' "${C_CYAN}${*}${C_RESET}"; }
ok() { printf '%s\n' "${C_GREEN}✓${C_RESET} ${C_RESET}${*}"; }

# ─── yq Check ─────────────────────────────────────────────────────────────────
# Find the config file — search script dir and common subdirs
find_config() {
  # Look for ghri.yaml in script dir first, then common locations
  if [[ -f "${SCRIPT_DIR}/ghri.yaml" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/ghri.yaml"
  elif [[ -f "${SCRIPT_DIR}/ghri/ghri.yaml" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/ghri/ghri.yaml"
  elif [[ -f "${SCRIPT_DIR}/../ghri/ghri.yaml" ]]; then
    CONFIG_FILE="${SCRIPT_DIR}/../ghri/ghri.yaml"
  else
    err "Config file not found. Copy ghri.example.yaml to ghri.yaml (next to $(basename "$0")'s real location, or in a ghri/ subdirectory) and edit it."
    exit 1
  fi
}

detect_yq() {
  if ! command -v yq >/dev/null 2>&1; then
    err "yq (Go version) not found. Install with:"
    err "  apt install yq-go"
    exit 1
  fi

  local ver_line
  ver_line=$(yq --version 2>&1)

  # Extract major version number from any yq --version output
  local major_ver=""
  # Try "version v4.x" or "version 4.x" patterns
  if [[ "$ver_line" =~ version[[:space:]]+v?([0-9]+) ]]; then
    major_ver="${BASH_REMATCH[1]}"
  fi
  # Try "yq v4.x" pattern
  if [[ -z "$major_ver" ]] && [[ "$ver_line" =~ yq[[:space:]]+v?([0-9]+) ]]; then
    major_ver="${BASH_REMATCH[1]}"
  fi
  if [[ -n "$major_ver" ]] && [[ "$major_ver" -ge 4 ]]; then
    return 0
  fi
  err "yq v4.x (Go version) required, found $ver_line"
  err "Install with: apt install yq-go"
  err "Then remove the old yq: apt remove yq"
  exit 1
}

# Commands ghri.sh itself needs, as "command:debian package". Checked up front so a
# missing tool is reported before anything is downloaded.
REQUIRED_TOOLS=(
  yq:yq-go gh:gh jq:jq
  sha256sum:coreutils stat:coreutils mktemp:coreutils realpath:coreutils readlink:coreutils
  date:coreutils cut:coreutils head:coreutils tr:coreutils touch:coreutils chmod:coreutils
  ln:coreutils mv:coreutils rm:coreutils cat:coreutils mkdir:coreutils basename:coreutils
  dirname:coreutils
  awk:gawk sed:sed grep:grep find:findutils
  flock:util-linux timeout:coreutils uname:coreutils
)

# Report every missing required tool at once (with its install hint), then exit 1
detect_tools() {
  local entry tool pkg missing=0
  for entry in "${REQUIRED_TOOLS[@]}"; do
    tool="${entry%%:*}"
    pkg="${entry#*:}"
    if ! command -v "$tool" >/dev/null 2>&1; then
      err "Required tool '$tool' not found. Install with: apt install $pkg"
      missing=1
    fi
  done
  [[ $missing -eq 0 ]] || exit 1

  # GNU stat/date/realpath are assumed throughout
  if [[ "$(uname -s)" != "Linux" && -z "${GHRI_ALLOW_UNSUPPORTED:-}" ]]; then
    err "ghri supports Linux only (it relies on GNU tools); found $(uname -s). Set GHRI_ALLOW_UNSUPPORTED=1 to try anyway."
    exit 1
  fi
}

# ─── YAML Helpers ─────────────────────────────────────────────────────────────
# The config is converted to JSON by yq once and then queried with jq (queries
# use plain jq syntax, e.g. `.packages[0].slug`).
CONFIG_JSON=""
_CONFIG_SIG=""

# (Re)load CONFIG_JSON when CONFIG_FILE changed. Returns 1 if the file cannot be parsed.
# Note: a first load inside $(...) is lost to the parent shell; load_config primes it.
load_config_json() {
  local sig
  sig="$CONFIG_FILE:$(stat -c '%Y:%s' "$CONFIG_FILE" 2>/dev/null)"
  [[ "$sig" == "$_CONFIG_SIG" ]] && return 0
  if ! CONFIG_JSON=$(yq -o=json '.' "$CONFIG_FILE" 2>/dev/null) || [[ -z "$CONFIG_JSON" ]]; then
    CONFIG_JSON="{}"
    _CONFIG_SIG=""
    return 1
  fi
  _CONFIG_SIG="$sig"
}

# Run a jq query against the config (raw output)
cfg_query() {
  load_config_json || true
  jq -r "$1" <<<"$CONFIG_JSON" 2>/dev/null
}

# Strip quotes and nulls from query output
clean_val() {
  local result="$1"
  case "$result" in
    "" | "null" | "~" | "NULL")
      printf ''
      return
      ;;
  esac
  # Strip surrounding quotes
  result="${result#\"}"
  result="${result%\"}"
  result="${result#\'}"
  result="${result%\'}"
  [[ -z "$result" ]] && result=""
  printf '%s' "$result"
}

# Read a scalar field from the config
yaml_field() {
  local result
  result=$(cfg_query "$1") || true
  clean_val "$result"
}

# Read with default value
yaml_field_default() {
  local query="$1" default="$2"
  local result
  result=$(cfg_query "${query} // ${default}") || true
  clean_val "$result"
}

# Get array length
yaml_array_length() {
  local result
  result=$(cfg_query "$1")
  result=$(clean_val "$result")
  [[ -z "$result" ]] && echo 0 || echo "$result"
}

# ─── Config Loading ───────────────────────────────────────────────────────────
load_config() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    err "Config file not found: $CONFIG_FILE"
    exit 1
  fi

  if ! load_config_json; then
    err "Cannot parse config file: $CONFIG_FILE"
    exit 1
  fi

  # One jq call for all scalar settings (one line each), one for the global processors
  local -a settings
  mapfile -t settings < <(cfg_query '[.install_path // "./install", .cache_path // "./.cache", .state_path // "./.state",
      .symlink_path // "./bin", .cache_lifetime_sec // "600", .timeout_sec // "60", .download_timeout_sec // "900"] | .[] | tostring')
  install_path=$(clean_val "${settings[0]:-}")
  cache_path=$(clean_val "${settings[1]:-}")
  state_path=$(clean_val "${settings[2]:-}")
  symlink_path=$(clean_val "${settings[3]:-}")
  cache_lifetime=$(clean_val "${settings[4]:-}")
  gh_timeout=$(clean_val "${settings[5]:-}")
  download_timeout=$(clean_val "${settings[6]:-}")

  # Resolve to absolute paths (handle already-absolute paths), one realpath call for all
  [[ -n "$install_path" ]] || install_path="./install"
  [[ -n "$cache_path" ]] || cache_path="./.cache"
  [[ -n "$state_path" ]] || state_path="./.state"
  [[ -n "$symlink_path" ]] || symlink_path="./bin"
  [[ "$install_path" == /* ]] || install_path="$SCRIPT_DIR/$install_path"
  [[ "$cache_path" == /* ]] || cache_path="$SCRIPT_DIR/$cache_path"
  [[ "$state_path" == /* ]] || state_path="$SCRIPT_DIR/$state_path"
  [[ "$symlink_path" == /* ]] || symlink_path="$SCRIPT_DIR/$symlink_path"
  # Env var override for symlink_path
  [[ -z "${GHRI_SYMLINK_PATH:-}" ]] || symlink_path="$GHRI_SYMLINK_PATH"
  local -a resolved
  mapfile -t resolved < <(realpath -m "$install_path" "$cache_path" "$state_path" "$symlink_path")
  install_path="${resolved[0]}"
  cache_path="${resolved[1]}"
  state_path="${resolved[2]}"
  symlink_path="${resolved[3]}"

  [[ -z "$cache_lifetime" ]] && cache_lifetime=600
  [[ "$gh_timeout" =~ ^[0-9]+$ ]] || gh_timeout=60
  [[ "$download_timeout" =~ ^[0-9]+$ ]] || download_timeout=900

  # Global post-process prepend/append
  global_prepend=()
  global_append=()

  local kind val
  while IFS=$'\t' read -r kind val; do
    [[ -n "$val" ]] || continue
    if [[ "$kind" == "p" ]]; then global_prepend+=("$val"); else global_append+=("$val"); fi
  done < <(cfg_query '(.global_post_process.prepend // [] | .[] | "p\t\(.)"), (.global_post_process.append // [] | .[] | "a\t\(.)")')
}

# ─── Package Extraction ──────────────────────────────────────────────────────
get_pkg_count() {
  yaml_array_length '.packages | length'
}

get_pkg_field() {
  yaml_field ".packages[$1].${2}"
}

# Get package name (derived from slug if not set)
get_pkg_name() {
  local name
  name=$(yaml_field ".packages[$1].name")
  if [[ -z "$name" ]]; then
    # Derive from slug: second part of owner/repo
    local slug
    slug=$(yaml_field ".packages[$1].slug")
    name="${slug##*/}"
  fi
  printf '%s' "$name"
}

# Get auto_install with default true
get_pkg_auto_install() {
  local val
  val=$(yaml_field ".packages[$1].auto_install")
  [[ -z "$val" ]] && val="true"
  printf '%s' "$val"
}

# Get prerelease with default false
get_pkg_prerelease() {
  local val
  val=$(yaml_field ".packages[$1].prerelease")
  [[ -z "$val" ]] && val=$(yaml_field ".prerelease")
  [[ -z "$val" ]] && val="false"
  printf '%s' "$val"
}

# Get pinned version (release tag) or empty for "latest"
get_pkg_version() {
  yaml_field ".packages[$1].version"
}

# Read every field of package $1 with a single jq call.
# Sets PKG_SLUG PKG_NAME PKG_PRERELEASE PKG_ASSET_MATCHER PKG_VERSION PKG_AUTO_INSTALL
# shellcheck disable=SC2016  # $root is a jq variable
PKG_JQ_FIELDS='[
      (.slug // ""),
      (.name // (.slug // "" | split("/") | last)),
      (if .prerelease != null then .prerelease elif $root.prerelease != null then $root.prerelease else false end | tostring),
      (.asset_matcher // "*"),
      (.version // ""),
      (if .auto_install == null then true else .auto_install end | tostring)
    ] | join("\u001f")'
_PKG_LINES=()
_PKG_PRELOADED=false

# Read the fields of every package with one jq call; load_package then needs no process of its
# own until clear_package_preload. Loops over all packages (install, outdated) use this.
preload_packages() {
  load_config_json || true
  mapfile -t _PKG_LINES < <(jq -r ". as \$root | .packages // [] | .[] | $PKG_JQ_FIELDS" <<<"$CONFIG_JSON" 2>/dev/null)
  _PKG_PRELOADED=true
}

clear_package_preload() {
  _PKG_LINES=()
  _PKG_PRELOADED=false
}

load_package() {
  local line US=$'\x1f'
  if [[ "$_PKG_PRELOADED" == "true" && -n "${_PKG_LINES[$1]:-}" ]]; then
    line="${_PKG_LINES[$1]}"
  else
    line=$(cfg_query ". as \$root | .packages[$1] | $PKG_JQ_FIELDS")
  fi
  IFS="$US" read -r PKG_SLUG PKG_NAME PKG_PRERELEASE PKG_ASSET_MATCHER PKG_VERSION PKG_AUTO_INSTALL <<<"$line"
}

# Get asset_matcher with default *
get_pkg_asset_matcher() {
  local val
  val=$(yaml_field ".packages[$1].asset_matcher")
  [[ -z "$val" ]] && val="*"
  printf '%s' "$val"
}

# Get post_process as array of names (handles scalars and objects)
# Output: newline-separated names
get_post_process_names() {
  cfg_query ".packages[$1].post_process // [] | .[] | if type == \"string\" then . else .name end"
}

# Get post_process config for a specific processor (scalar entries have none)
get_pp_config() {
  local i="$1" j="$2" config_key="$3"
  local result
  result=$(cfg_query ".packages[$i].post_process[$j] | if type == \"object\" then .${config_key} else null end | if type == \"array\" then join(\" \") else . end")
  clean_val "$result"
}

# ─── Post-Processors (M4-M6) ──────────────────────────────────────────────────
# Get post-processor count
get_pp_count() {
  yaml_array_length ".packages[$1].post_process | length"
}

# Emit one line per package post-processor: name, asset_matcher, quiet, args... separated by
# the ASCII unit separator (0x1f). `args` may be a list or a single string.
get_pp_specs() {
  cfg_query ".packages[$1].post_process // [] | .[]
    | if type == \"string\" then {name: .} else . end
    | [.name, (.asset_matcher // \"\"), (if .quiet == null then false else .quiet end | tostring)] + ([.args // empty] | flatten | map(tostring))
    | join(\"\\u001f\")"
}

# Run all post-processors for a package.
# Processor contract: pp_<name> asset_file package_name working_dir asset_matcher quiet [args...]
# A processor that changes the file sets CURRENT_ASSET to the new file; the next
# processor receives it as asset_file. Returns non-zero on failure.
run_post_processors() {
  local i="$1" working_dir="$2" asset_file="$3" package_name="$4"

  CURRENT_ASSET="$asset_file"

  # Full chain: global_prepend + package + global_append, as "source<US>name<US>matcher<US>args..."
  local US=$'\x1f'
  local chain=() pp spec
  for pp in "${global_prepend[@]}"; do
    chain+=("global_prepend${US}${pp}${US}${US}")
  done
  while IFS= read -r spec; do
    [[ -n "$spec" ]] && chain+=("package${US}${spec}")
  done < <(get_pp_specs "$i")
  for pp in "${global_append[@]}"; do
    chain+=("global_append${US}${pp}${US}${US}")
  done

  local entry source pp_name matcher quiet fields pp_func
  for entry in "${chain[@]}"; do
    IFS="$US" read -r -a fields <<<"$entry"
    source="${fields[0]}"
    pp_name="${fields[1]}"
    matcher="${fields[2]:-*}"
    quiet="${fields[3]:-false}"
    [[ -z "$pp_name" ]] && continue

    pp_func="pp_$pp_name"
    if [[ "$(type -t "$pp_func" 2>/dev/null)" != "function" ]]; then
      err "  Post-processor $pp_name not found for $package_name"
      FAIL=$((FAIL + 1))
      FAILURES+=("$package_name (processor $pp_name not found)")
      return 1
    fi

    printf "  %-20s " "[$source/$pp_name]..."
    if ! $pp_func "$CURRENT_ASSET" "$package_name" "$working_dir" "$matcher" "$quiet" "${fields[@]:4}"; then
      echo "❌ failed"
      err "  Post-processor $pp_name failed for $package_name"
      FAIL=$((FAIL + 1))
      FAILURES+=("$package_name ($pp_name)")
      return 1
    fi
    ok ok
  done

  return 0
}

# ─── Post-Processor: make_exec (M4) ──────────────────────────────────────────
pp_make_exec() {
  chmod 0755 "$1" 2>/dev/null
}

# ─── Post-Processor: link (M4) ───────────────────────────────────────────────
pp_link() {
  local asset_file="$1" package_name="$2"
  local link_path="$symlink_path/$package_name"

  # Resolve the target (what we're linking to)
  local target
  target=$(realpath "$asset_file" 2>/dev/null)

  if [[ -z "$target" ]]; then
    err "  Cannot resolve target for $asset_file"
    return 1
  fi

  # Create symlink directory if needed
  mkdir -p "$symlink_path"

  # Remove existing symlink or file
  [[ -L "$link_path" ]] && rm -f "$link_path"
  [[ -f "$link_path" ]] && rm -f "$link_path"

  # Create symlink
  ln -sf "$target" "$link_path" 2>/dev/null
}

# ─── Post-Processor: check_in_path (M4) ──────────────────────────────────────
pp_check_in_path() {
  local asset_file="$1" package_name="$2"

  # Command must be resolvable via PATH (symlink_path or system dirs, e.g. after dpkg -i)
  if ! command -v "$package_name" >/dev/null 2>&1; then
    err "  Command '$package_name' not found in PATH"
    return 1
  fi

  return 0
}

# ─── Post-Processor: deb (M6) ────────────────────────────────────────────────
# Runs `sudo dpkg -i`. If that fails (typically missing dependencies) and we are
# interactive, ask before attempting `apt-get -f install` and retry once.
pp_deb() {
  local asset_file="$1"

  echo ""
  echo "  Installing $asset_file ..."
  if sudo dpkg -i "$asset_file" 2>&1; then
    return 0
  fi

  warn "dpkg -i failed for $asset_file (often missing dependencies)."
  if [[ ! -t 0 ]]; then
    warn "Not interactive; fix manually, e.g.: sudo apt-get -f install"
    return 1
  fi

  # Talk to the terminal directly: stdout/stderr may be captured for the one-line-per-package view
  local answer
  printf "  %s: dpkg -i failed. Try to fix with 'sudo apt-get -f install -y' and retry? [y/N] " "$asset_file" >/dev/tty
  read -r answer </dev/tty
  [[ "$answer" =~ ^[Yy] ]] || return 1

  sudo apt-get -f install -y 2>&1 || return 1
  sudo dpkg -i "$asset_file" 2>&1
}

# ─── Post-Processor: testrun (M6) ────────────────────────────────────────────
# Runs the package binary with the processor's args and prints the first output line (unless quiet: true).
pp_testrun() {
  local asset_file="$1" package_name="$2"
  local quiet="${5:-false}"
  local test_args=("${@:6}")
  local link_path="$symlink_path/$package_name"

  local cmd
  if [[ -L "$link_path" ]]; then
    cmd="$link_path"
  elif cmd=$(command -v "$package_name" 2>/dev/null) && [[ -n "$cmd" ]]; then
    : # e.g. installed via deb, resolved through PATH
  else
    cmd="$asset_file"
    [[ "$cmd" == */* ]] || cmd="./$cmd"
  fi

  local output res
  output=$("$cmd" "${test_args[@]}" 2>&1 </dev/null)
  res=$?

  if [[ $res -ne 0 ]]; then
    err "  testrun failed: $cmd ${test_args[*]} (exit code $res)"
    return 1
  fi

  [[ "$quiet" == "true" ]] || echo "$output" | head -1
}

# ─── Archive Extractors (M5) ─────────────────────────────────────────────────
# Shared helper for archive processors: find single matching file after extraction
find_single_match() {
  local pattern="$1"
  local matches=()

  while IFS= read -r -d '' file; do
    local relpath="${file#./}"
    if match_asset "$relpath" "$pattern"; then
      matches+=("$relpath")
    fi
  done < <(find . -type f -print0)

  if [[ ${#matches[@]} -eq 1 ]]; then
    printf '%s' "${matches[0]}"
    return 0
  elif [[ ${#matches[@]} -gt 1 ]]; then
    err "  Multiple matching files: ${matches[*]}"
    return 1
  else
    err "  No matching file found"
    return 1
  fi
}

# Single-file decompressors: replace the compressed file, set CURRENT_ASSET to the result
pp_gunzip() {
  local asset_file="$1"

  gunzip -f -k "$asset_file" || return 1
  rm -f "$asset_file"
  CURRENT_ASSET="${asset_file%.gz}"
}

pp_bz2() {
  local asset_file="$1"

  bunzip2 -k -f "$asset_file" || return 1
  rm -f "$asset_file"
  CURRENT_ASSET="${asset_file%.bz2}"
}

pp_xz() {
  local asset_file="$1"

  xz -d --force "$asset_file" || return 1
  CURRENT_ASSET="${asset_file%.xz}"
}

# Archive extractors: extract, drop the archive (avoids false matches), then pick the
# single file matching asset_matcher ($4) as the new CURRENT_ASSET
pp_tar() {
  local asset_file="$1" matcher="${4:-*}"

  tar -xf "$asset_file" || return 1
  rm -f "$asset_file"

  local result
  result=$(find_single_match "$matcher") || return 1
  CURRENT_ASSET="$result"
}

pp_unzip() {
  local asset_file="$1" matcher="${4:-*}"

  unzip -qq -o "$asset_file" || return 1
  rm -f "$asset_file"

  local result
  result=$(find_single_match "$matcher") || return 1
  CURRENT_ASSET="$result"
}

# ─── Installed State ──────────────────────────────────────────────────────────
# One record per installed package at state_path/<owner>_<repo>/release.dat, written only
# after all post-processors succeeded: tag_name, prerelease, asset_name, download_url.
# (Records used to live in cache_path; state_read migrates them on first access.)

# Convert slug to a directory name: owner/repo → owner_repo
slug_to_dir() {
  printf '%s' "${1//\//_}"
}

# Get the record path for a package
state_file() {
  printf '%s/%s/release.dat' "$state_path" "${1//\//_}"
}

# Where the record of a package was kept before state_path existed
legacy_state_file() {
  printf '%s/%s/release.dat' "$cache_path" "${1//\//_}"
}

# Read the record into state_tag and state_prerelease; fails if the package is not recorded
# shellcheck disable=SC2034  # state_prerelease is part of the record API
state_read() {
  local dir="${1//\//_}"
  local file="$state_path/$dir/release.dat"

  state_tag=""
  state_prerelease=""

  if [[ ! -f "$file" && -f "$cache_path/$dir/release.dat" ]]; then
    mkdir -p "$state_path/$dir" && mv "$cache_path/$dir/release.dat" "$file"
    rmdir "$cache_path/$dir" 2>/dev/null
  fi
  [[ -f "$file" ]] || return 1

  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      tag_name) state_tag="$value" ;;
      prerelease) state_prerelease="$value" ;;
    esac
  done <"$file"

  [[ -n "$state_tag" ]]
}

# Write the record for a slug
state_write() {
  local slug="$1" tag="$2" is_prerelease="$3" asset_name="$4" url="$5"
  local file
  file=$(state_file "$slug")

  mkdir -p "$(dirname "$file")"

  cat >"$file" <<STATEEOF
tag_name=$tag
prerelease=$is_prerelease
asset_name=$asset_name
download_url=$url
STATEEOF
}

# ─── Release Fetching (M2) ────────────────────────────────────────────────────
# Run gh with a time limit of $1 seconds (exit status 124 means it timed out)
gh_run() {
  local limit="$1"
  shift
  timeout "$limit" gh "$@"
}

# Temp file inside the per-run temp directory (removed on exit, also after Ctrl-C)
mktmp() {
  mktemp -p "${TMP_DIR:-${TMPDIR:-/tmp}}" "${1:-ghri.XXXXXX}"
}

# Per-run setup: temp dir and signal handling
init_run() {
  TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/ghri.XXXXXX") || exit 1
  exec 3>&2 # the real stderr: output of install_package may be captured, but interrupts must be visible
  trap cleanup_run EXIT
  trap 'warn "Interrupted" >&3; exit 130' INT
  trap 'warn "Terminated" >&3; exit 143' TERM
}

# Runs on every exit: undo a half-finished update, drop partial downloads and temp files
cleanup_run() {
  trap - EXIT
  if [[ -n "$PENDING_LINK" ]]; then
    rollback_link "$PENDING_LINK" "$PENDING_PREV" >&3 2>&3
    PENDING_LINK=""
  fi
  [[ -n "$CURRENT_PART" ]] && rm -f "$CURRENT_PART"
  [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]] && rm -rf "$TMP_DIR"
  return 0
}

# One mutating run at a time (install, prune and the config commands share a lock)
acquire_lock() {
  mkdir -p "$state_path" || return 1
  exec 9>"$state_path/ghri.lock" || return 1
  if ! flock -n 9; then
    err "Another ghri run is in progress (lock: $state_path/ghri.lock)"
    return 1
  fi
}

# GET a GitHub API path through `gh api` (auth: GH_TOKEN/GITHUB_TOKEN or `gh auth login`).
# A fresh cache entry (younger than cache_lifetime) makes no request. A stale one is
# revalidated with If-None-Match; a 304 does not count against the rate limit.
# Prints the body on stdout; returns 1 on failure (reason reported via err).
# True if a cached response for API path $1 is younger than cache_lifetime (and --no-cache is off)
api_cache_fresh() {
  local cache_json="$cache_path/api/${1//[^A-Za-z0-9._-]/_}.json"
  [[ "$NO_CACHE" != "true" && -s "$cache_json" ]] || return 1
  local mtime now
  mtime=$(stat -c %Y "$cache_json" 2>/dev/null) || return 1
  printf -v now '%(%s)T' -1
  ((now - mtime < cache_lifetime))
}

api_get() {
  local path="$1"
  local cache_key="${path//[^A-Za-z0-9._-]/_}"
  local cache_json="$cache_path/api/$cache_key.json"
  local cache_etag="$cache_path/api/$cache_key.etag"

  if api_cache_fresh "$path"; then
    cat "$cache_json"
    return 0
  fi

  local args=(api -i -H "Accept: application/vnd.github+json")
  [[ "$NO_CACHE" != "true" && -s "$cache_json" && -s "$cache_etag" ]] && args+=(-H "If-None-Match: $(<"$cache_etag")")
  args+=("$path")

  local errfile raw status headers body rc
  errfile=$(mktmp) || return 1
  raw=$(gh_run "$gh_timeout" "${args[@]}" 2>"$errfile")
  rc=$?
  raw="${raw//$'\r'/}"
  status=$(awk 'NR==1 {print $2}' <<<"$raw")
  headers="${raw%%$'\n\n'*}"
  body="${raw#*$'\n\n'}"

  if [[ $rc -eq 124 ]]; then
    err "GitHub API request timed out after ${gh_timeout}s (timeout_sec): $path"
    rm -f "$errfile"
    return 1
  fi

  case "$status" in
    304)
      rm -f "$errfile"
      touch "$cache_json"
      cat "$cache_json"
      return 0
      ;;
    200)
      rm -f "$errfile"
      mkdir -p "$(dirname "$cache_json")"
      printf '%s' "$body" >"$cache_json"
      grep -i '^etag:' <<<"$headers" | head -1 | cut -d' ' -f2- >"$cache_etag"
      printf '%s' "$body"
      return 0
      ;;
    403 | 429)
      if grep -qi '^x-ratelimit-remaining: 0' <<<"$headers"; then
        local reset
        reset=$(grep -i '^x-ratelimit-reset:' <<<"$headers" | awk '{print $2}')
        err "GitHub API rate limit exceeded (resets $(date -d "@$reset" '+%H:%M:%S' 2>/dev/null)). Set GITHUB_TOKEN/GH_TOKEN or run 'gh auth login' (60 -> 5000 req/h)."
        rm -f "$errfile"
        return 1
      fi
      ;;
  esac

  err "GitHub API request failed for $path (HTTP ${status:-no response}): $(head -1 "$errfile")"
  rm -f "$errfile"
  return 1
}

# Like api_get but stores the body in the variable named by $1 and runs in the current
# shell, so err() messages stay visible in LAST_ERROR
api_get_var() {
  local -n _api_out="$1"
  local tmp
  if api_cache_fresh "$2"; then
    _api_out=$(<"$cache_path/api/${2//[^A-Za-z0-9._-]/_}.json")
    return 0
  fi
  tmp=$(mktmp) || return 1
  if api_get "$2" >"$tmp"; then
    _api_out=$(<"$tmp")
    rm -f "$tmp"
  else
    rm -f "$tmp"
    return 1
  fi
}

# True if a pinned version is a glob or /regex/ rather than one exact tag
is_version_pattern() {
  [[ "$1" == *[\*\?\[]* || "$1" =~ ^/.*/[a-zA-Z]*$ ]]
}

# Fetch a release from GitHub. With $3 (a tag, glob or /regex/) that release, else the latest
# (or newest pre-release when $2 is true).
# Sets: release_tag, release_is_prerelease, release_immutable, release_asset_names,
#       release_asset_urls, release_asset_digests, release_asset_count
fetch_release() {
  local slug="$1" prerelease="$2" version="${3:-}"
  local json data

  if is_version_pattern "$version"; then
    # Version glob (or /regex/): newest release whose tag matches
    api_get_var json "/repos/$slug/releases?per_page=100" || return 1
    local tag found=""
    while IFS= read -r tag; do
      if match_asset "$tag" "$version"; then
        found="$tag"
        break
      fi
    done < <(jq -r --arg pre "$prerelease" '[.[] | select(.draft | not) | select($pre == "true" or (.prerelease | not))] | sort_by(.created_at) | reverse | .[].tag_name' <<<"$json" 2>/dev/null)
    if [[ -z "$found" ]]; then
      err "No release of $slug matches version pattern '$version'"
      return 1
    fi
    data=$(jq -c --arg t "$found" '.[] | select(.tag_name == $t)' <<<"$json" 2>/dev/null)
  elif [[ -n "$version" ]]; then
    api_get_var json "/repos/$slug/releases/tags/$version" || return 1
    data="$json"
  elif [[ "$prerelease" == "true" ]]; then
    # Pre-release mode: get all releases, pick the latest by created_at
    api_get_var json "/repos/$slug/releases" || return 1
    data=$(jq -c '[.[] | select(.draft | not)] | sort_by(.created_at) | last' <<<"$json" 2>/dev/null)
  else
    # Normal mode: latest release (excludes pre-releases)
    api_get_var json "/repos/$slug/releases/latest" || return 1
    data="$json"
  fi

  if [[ -z "$data" || "$data" == "null" ]]; then
    err "No release found for $slug"
    return 1
  fi

  # One jq call: tag, prerelease and immutable on the first three lines, then one
  # name/url/digest line (unit separator) per asset
  local lines line US=$'\x1f' name url digest
  mapfile -t lines < <(jq -r '.tag_name, .prerelease, (.immutable // false),
    (.assets[] | [.name, .browser_download_url, (.digest // "")] | join("\u001f"))' <<<"$data" 2>/dev/null)
  release_tag="${lines[0]:-}"
  release_is_prerelease="${lines[1]:-}"
  release_immutable="${lines[2]:-false}"
  release_asset_names=() release_asset_urls=() release_asset_digests=()
  for line in "${lines[@]:3}"; do
    IFS="$US" read -r name url digest <<<"$line"
    release_asset_names+=("$name")
    release_asset_urls+=("$url")
    release_asset_digests+=("$digest")
  done
  release_asset_count=${#release_asset_names[@]}

  if [[ -z "$release_tag" || "$release_tag" == "null" ]]; then
    err "Release of $slug has no tag"
    return 1
  fi
}

# ─── Asset Matching (M2) ──────────────────────────────────────────────────────
# Match an asset name against a pattern (fnmatch or regex)
match_asset() {
  local name="$1" pattern="$2"

  # Check if pattern is a regex (starts and ends with /)
  if [[ "$pattern" =~ ^/.*/[a-zA-Z]*$ ]]; then
    # Regex mode
    local regex="${pattern:1}"
    regex="${regex%/}" # Strip trailing /
    [[ "$name" =~ $regex ]]
  else
    # fnmatch mode (bash [[ == supports glob patterns)
    # shellcheck disable=SC2053
    [[ "$name" == $pattern ]]
  fi
}

# Find the matching asset index for a package
# Sets: found_asset_name, found_asset_url, found_asset_digest
find_matching_asset() {
  local pattern="$1"
  found_asset_name=""
  found_asset_url=""
  found_asset_digest=""

  for ((idx = 0; idx < release_asset_count; idx++)); do
    if match_asset "${release_asset_names[$idx]}" "$pattern"; then
      found_asset_name="${release_asset_names[$idx]}"
      found_asset_url="${release_asset_urls[$idx]}"
      found_asset_digest="${release_asset_digests[$idx]:-}"
      return 0
    fi
  done

  return 1
}

# ─── Args Parsing ─────────────────────────────────────────────────────────────
show_help() {
  cat <<HELPEOF
Usage: $(basename "$0") install [NAMES...]    Install/update all packages, or only NAMES
       $(basename "$0") add <owner/repo>      Interactive wizard: add a package to ghri.yaml
       $(basename "$0") edit <name>           Edit one package's part of ghri.yaml in \$EDITOR
       $(basename "$0") delete <name>         Remove a package from ghri.yaml (asks first; --yes skips)
       $(basename "$0") list [-v]             List configured packages (-v: markdown with GitHub descriptions)
       $(basename "$0") [--outdated | --check | --prune]   Inspect or clean up (see options)
       $(basename "$0") completion <bash|zsh|fish>  Print a shell completion script

Install or update GitHub release binaries. Downloads the latest release
of configured packages (verified against GitHub's digests/attestations),
post-processes them, and symlinks to your PATH. Packages that are already
up to date are skipped.

Options:
  --outdated, -o    Show installed vs. latest version (aliases: --list, -l, --dry-run, -n)
  --check, -c       Validate the config and required tools, then exit
  --force, -f       (install) Reinstall even if the installed version is current
  --no-cache, -r    Do not use cached GitHub API responses (always ask GitHub; alias: --refresh)
  --quiet, -q       Only report changes and failures (good for cron)
  --json            Machine-readable output for --outdated
  --prune           Remove installs, records and links of packages no longer in the config
  --yes, -y         Do not ask for confirmation (--prune)
  --verbose, -v     Show full output per package instead of one line each
  --version         Show the version
  --help, -h        Show this help message

Examples:
  $(basename "$0") install                  Install/update all packages
  $(basename "$0") install pex yt-dlp       Install/update specific packages
  $(basename "$0") --outdated       Show what would be updated
  $(basename "$0") --check          Validate ghri.yaml

Exit codes: 0 ok, 1 failures, 2 usage error, 10 --outdated found packages that are not current

Config:
  GHRI_SYMLINK_PATH=~/bin ./$(basename "$0")   Override symlink path at runtime
  GITHUB_TOKEN / GH_TOKEN (e.g. in .env)       Authenticate gh (higher API rate limit)

HELPEOF
}

parse_args() {
  MODE="install"
  INSTALL_ALL=true
  TARGETS=()
  SUBARG=""
  EXPLICIT_INSTALL=false

  # Subcommands: the first word. add/edit/delete take one package name or slug; `install`
  # takes any number of names (so packages called add, edit or delete can still be installed).
  local sub=""
  case "${1:-}" in
    add | edit | install | completion | list) sub="$1" ;;
    delete | remove | rm) sub="delete" ;;
  esac
  [[ -n "$sub" ]] && shift
  [[ "$sub" == "install" ]] && EXPLICIT_INSTALL=true

  local arg
  for arg in "$@"; do
    case "$arg" in
      --outdated | -o | --list | -l | --dry-run | -n)
        MODE="outdated"
        ;;
      --check | -c)
        MODE="check"
        ;;
      --force | -f)
        FORCE=true
        ;;
      --no-cache | --refresh | -r)
        NO_CACHE=true
        ;;
      --quiet | -q)
        QUIET=true
        ;;
      --json)
        JSON=true
        ;;
      --names)
        MODE="names"
        ;;
      --prune)
        MODE="prune"
        ;;
      --yes | -y)
        ASSUME_YES=true
        ;;
      --verbose | -v)
        VERBOSE=true
        ;;
      --help | -h)
        show_help
        exit 0
        ;;
      --version)
        echo "$(basename "$0") $VERSION"
        exit 0
        ;;
      -*)
        err "Unknown option: $arg (see --help)"
        exit 2
        ;;
      *)
        TARGETS+=("$arg")
        ;;
    esac
  done

  [[ ${#TARGETS[@]} -gt 0 ]] && INSTALL_ALL=false

  if [[ "$sub" == "list" ]]; then
    if [[ ${#TARGETS[@]} -ne 0 ]]; then
      err "Usage: $(basename "$0") list [-v]"
      exit 2
    fi
    MODE="list"
  elif [[ -n "$sub" && "$sub" != "install" ]]; then
    if [[ ${#TARGETS[@]} -ne 1 ]]; then
      local what="name"
      [[ "$sub" == add ]] && what="owner/repo"
      [[ "$sub" == completion ]] && what="bash|zsh|fish"
      err "Usage: $(basename "$0") $sub <$what>"
      exit 2
    fi
    MODE="$sub"
    SUBARG="${TARGETS[0]}"
    TARGETS=()
    INSTALL_ALL=true
  fi
  return 0
}

# Is package $1 (index) named $2 selected by the command line? Optional $3: its auto_install value.
# `install` without names selects every package except `auto_install: false` ones.
package_selected() {
  local i="$1" name="$2" auto="${3:-}" t
  if [[ "$INSTALL_ALL" == "true" ]]; then
    [[ -n "$auto" ]] || auto=$(get_pkg_auto_install "$i")
    [[ "$auto" != "false" ]]
    return
  fi
  for t in "${TARGETS[@]}"; do
    [[ "$t" == "$name" ]] && return 0
  done
  return 1
}

# Every package named on the command line must exist in the config
check_targets() {
  local t name found rc=0 names
  mapfile -t names < <(cfg_query '.packages // [] | .[] | (.name // (.slug // "" | split("/") | last))')
  for t in "${TARGETS[@]}"; do
    found=false
    for name in "${names[@]}"; do
      [[ "$name" == "$t" ]] && found=true
    done
    if [[ "$found" == "false" ]]; then
      err "Unknown package: $t"
      rc=1
    fi
  done
  return $rc
}

# ─── Config Check ─────────────────────────────────────────────────────────────
# jq program printing one finding per line: E:<error>, W:<warning>, P:<processor name>,
# M:<where><US><asset_matcher> (matchers are regex-checked in bash).
# shellcheck disable=SC2016  # jq program, not shell
CHECK_JQ='
def isstr: type == "string";
def warn_unknown($allowed; $ctx): keys[] | select(. as $k | $allowed | index($k) | not) | "W:\($ctx): unknown key \"\(.)\"";
def processors($ctx):
  if type == "array" then
    to_entries[] | .key as $j | .value as $e | "\($ctx) post_process[\($j)]" as $c |
    if ($e | isstr) then "P:\($e)"
    elif ($e | type) == "object" then
      ($e | warn_unknown(["name", "asset_matcher", "args", "quiet"]; $c)),
      (if ($e.name | isstr) then "P:\($e.name)" else "E:\($c): \"name\" must be a string" end),
      (if ($e.asset_matcher != null) then (if ($e.asset_matcher | isstr) then "M:\($c)\u001f\($e.asset_matcher)" else "E:\($c): asset_matcher must be a string" end) else empty end),
      (if ($e.quiet != null) and (($e.quiet | type) != "boolean") then "E:\($c): quiet must be true or false" else empty end),
      (if ($e.args != null) and (($e.args | type) as $t | ["string", "number", "array"] | index($t) | not) then "E:\($c): args must be a string or a list" else empty end)
    else "E:\($c): must be a processor name or a mapping" end
  elif . == null then empty
  else "E:\($ctx): post_process must be a list" end;
if type != "object" then "E:config root must be a mapping" else
  (warn_unknown(["install_path", "symlink_path", "cache_path", "state_path", "cache_lifetime_sec", "timeout_sec", "download_timeout_sec", "global_post_process", "prerelease", "packages"]; "config")),
  (if (.prerelease != null) and ((.prerelease | type) != "boolean") then "E:prerelease must be true or false" else empty end),
  (["cache_lifetime_sec", "timeout_sec", "download_timeout_sec"][] as $k | if (.[$k] != null) and ((.[$k] | type) != "number") then "E:\($k) must be a number" else empty end),
  (if (.global_post_process | type) == "object" then
     (.global_post_process | warn_unknown(["prepend", "append"]; "global_post_process")),
     (["prepend", "append"][] as $w | (.global_post_process[$w] // [])[] |
        if isstr then "P:\(.)" else "E:global_post_process.\($w): entries must be processor names" end)
   elif .global_post_process != null then "E:global_post_process must be a mapping" else empty end),
  (if ((.packages | type) != "array") or ((.packages | length) == 0) then "E:packages must be a non-empty list" else
     (.packages | to_entries[] | .key as $i | .value as $p |
       "packages[\($i)]\(if ($p | type) == "object" and ($p.slug | isstr) then " (\($p.slug))" else "" end)" as $c |
       if ($p | type) != "object" then "E:\($c): must be a mapping" else
         ($p | warn_unknown(["slug", "name", "desc", "asset_matcher", "post_process", "auto_install", "prerelease", "version"]; $c)),
         (if ($p.slug | isstr) | not then "E:\($c): slug is required (owner/repo)"
          elif ($p.slug | test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$") | not) then "E:\($c): slug must look like owner/repo" else empty end),
         (["name", "version"][] as $k | if ($p[$k] != null) and (($p[$k] | isstr) | not) then "E:\($c): \($k) must be a string" else empty end),
         (["auto_install", "prerelease"][] as $k | if ($p[$k] != null) and (($p[$k] | type) != "boolean") then "E:\($c): \($k) must be true or false" else empty end),
         (if ($p.asset_matcher != null) then (if ($p.asset_matcher | isstr) then "M:\($c)\u001f\($p.asset_matcher)" else "E:\($c): asset_matcher must be a string" end) else empty end),
         ($p.post_process | processors($c))
       end)
   end)
end
'

# Tools needed by a post-processor as "command:debian package" (space separated), if any
processor_tools() {
  case "$1" in
    gunzip) echo gunzip:gzip ;;
    bz2) echo bunzip2:bzip2 ;;
    xz) echo xz:xz-utils ;;
    tar) echo tar:tar ;;
    unzip) echo unzip:unzip ;;
    deb) echo "dpkg:dpkg sudo:sudo" ;;
  esac
}

# Validate config and environment. $1=true also prints warnings.
# Sets CHECK_ERRORS / CHECK_WARNINGS; returns 0 when there are no errors.
check_config() {
  local show_warnings="${1:-false}"
  CHECK_ERRORS=0
  CHECK_WARNINGS=0

  if ! load_config_json; then
    err "Cannot parse config file: $CONFIG_FILE"
    CHECK_ERRORS=1
    return 1
  fi

  local -A used=()
  local line msg where pattern rc
  local US=$'\x1f'
  while IFS= read -r line; do
    msg="${line:2}"
    case "${line:0:2}" in
      E:)
        err "config: $msg"
        CHECK_ERRORS=$((CHECK_ERRORS + 1))
        ;;
      W:)
        CHECK_WARNINGS=$((CHECK_WARNINGS + 1))
        [[ "$show_warnings" == "true" ]] && warn "config: $msg"
        ;;
      P:) used["$msg"]=1 ;;
      M:)
        where="${msg%%"$US"*}"
        pattern="${msg#*"$US"}"
        if [[ "$pattern" =~ ^/.*/[a-zA-Z]*$ ]]; then
          pattern="${pattern:1}"
          pattern="${pattern%/*}"
          printf "" | grep -Eq -- "$pattern"
          rc=$? # 2 = invalid regex
          if [[ $rc -eq 2 ]]; then
            err "config: $where: invalid regex asset_matcher /$pattern/"
            CHECK_ERRORS=$((CHECK_ERRORS + 1))
          fi
        fi
        ;;
    esac
  done < <(jq -r "$CHECK_JQ" <<<"$CONFIG_JSON" 2>/dev/null)

  # Processors must exist and their tools must be installed
  local pp tool entry
  for pp in "${!used[@]}"; do
    if [[ "$(type -t "pp_$pp" 2>/dev/null)" != "function" ]]; then
      err "config: unknown post-processor \"$pp\""
      CHECK_ERRORS=$((CHECK_ERRORS + 1))
      continue
    fi
    for entry in $(processor_tools "$pp"); do
      tool="${entry%%:*}"
      if ! command -v "$tool" >/dev/null 2>&1; then
        err "config: post-processor \"$pp\" needs '$tool', which is not installed (apt install ${entry#*:})"
        CHECK_ERRORS=$((CHECK_ERRORS + 1))
      fi
    done
    # the deb fix prompt (optional) uses apt-get
    if [[ "$pp" == deb ]] && ! command -v apt-get >/dev/null 2>&1; then
      CHECK_WARNINGS=$((CHECK_WARNINGS + 1))
      [[ "$show_warnings" == "true" ]] && warn "config: apt-get not found; the deb dependency fix prompt will not work"
    fi
  done

  # Package names must be unique (they select packages and name the symlinks)
  local dups
  dups=$(cfg_query '[.packages[]? | (.name // (.slug // "" | split("/") | last))] | group_by(.)[] | select(length > 1) | .[0]')
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    err "config: duplicate package name \"$line\""
    CHECK_ERRORS=$((CHECK_ERRORS + 1))
  done <<<"$dups"

  # check_in_path / testrun resolve commands via PATH
  if [[ ":$PATH:" != *":$symlink_path:"* ]]; then
    CHECK_WARNINGS=$((CHECK_WARNINGS + 1))
    [[ "$show_warnings" == "true" ]] && warn "symlink_path $symlink_path is not in PATH; check_in_path/testrun for linked packages will fail"
  fi

  [[ $CHECK_ERRORS -eq 0 ]]
}

# ─── Commands ─────────────────────────────────────────────────────────────────
# True if the installed tag recorded for the package equals $release_tag and the
# command is still usable (symlink or PATH). Needs fetch_release to have run.
is_up_to_date() {
  local slug="$1" name="$2"
  state_read "$slug" || return 1
  [[ "$state_tag" == "$release_tag" ]] || return 1
  [[ -d "$install_path/${slug//\//_}/$release_tag" ]] || return 1
  [[ -e "$symlink_path/$name" ]] || command -v "$name" >/dev/null 2>&1
}

# Show installed vs. latest version for every selected package (--json: machine-readable)
do_outdated() {
  local PKG_COUNT i
  PKG_COUNT=$(get_pkg_count)
  local rows=()

  if [[ "$JSON" != "true" && "$QUIET" != "true" ]]; then
    printf '%-24s %-16s %-16s %s\n' "NAME" "INSTALLED" "LATEST" "STATUS"
  fi
  preload_packages
  for ((i = 0; i < PKG_COUNT; i++)); do
    load_package "$i"
    local slug="$PKG_SLUG" name="$PKG_NAME" prerelease="$PKG_PRERELEASE" version="$PKG_VERSION"
    package_selected "$i" "$name" "$PKG_AUTO_INSTALL" || continue

    local installed="-"
    state_read "$slug" && installed="$state_tag"

    local code latest text error=""
    if ! fetch_release "$slug" "$prerelease" "$version" 2>/dev/null; then
      code="error"
      latest="?"
      error="$LAST_ERROR"
      text="${C_RED}error${C_RESET}: $error"
      FAIL=$((FAIL + 1))
      FAILURES+=("$name (release fetch failed)")
    else
      latest="$release_tag"
      if [[ "$installed" == "-" ]]; then
        code="not-installed"
        text="${C_YELLOW}not installed${C_RESET}"
      elif [[ "$installed" != "$release_tag" ]]; then
        code="update-available"
        text="${C_YELLOW}update available${C_RESET}"
      elif ! is_up_to_date "$slug" "$name"; then
        code="needs-reinstall"
        text="${C_YELLOW}needs reinstall (command missing)${C_RESET}"
      else
        code="up-to-date"
        text="${C_GREEN}up to date${C_RESET}"
      fi
      [[ "$code" == "up-to-date" ]] || OUTDATED_COUNT=$((OUTDATED_COUNT + 1))
    fi
    [[ -n "$version" ]] && text="$text (pinned)"
    [[ "$QUIET" == "true" && "$code" == "up-to-date" ]] && continue

    if [[ "$JSON" == "true" ]]; then
      rows+=("$(jq -nc --arg name "$name" --arg slug "$slug" --arg installed "$installed" \
        --arg latest "$latest" --arg status "$code" --arg pinned "$version" --arg error "$error" \
        '{name: $name, slug: $slug,
          installed: (if $installed == "-" then null else $installed end),
          latest: (if $latest == "?" then null else $latest end),
          status: $status,
          pinned: (if $pinned == "" then null else $pinned end)}
         + (if $error == "" then {} else {error: $error} end)')")
    else
      printf '%-24s %-16s %-16s %s\n' "$name" "$installed" "$latest" "$text"
    fi
  done
  clear_package_preload

  if [[ "$JSON" == "true" ]]; then
    if [[ ${#rows[@]} -eq 0 ]]; then
      echo "[]"
    else
      printf '%s\n' "${rows[@]}" | jq -s '.'
    fi
  fi
}

# ─── Download (M3) ────────────────────────────────────────────────────────────
# Escape glob metacharacters so `gh release download --pattern` matches one exact name
glob_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\*/\\*}"
  s="${s//\?/\\?}"
  s="${s//\[/\\[}"
  printf '%s' "$s"
}

# Download one release asset with gh into $dest. The file only appears at $dest once verified:
#  1. sha256 must equal the digest GitHub records for the asset (warning if none is recorded)
#  2. for immutable releases, `gh release verify-asset` checks the signed release attestation
download_asset() {
  local slug="$1" tag="$2" name="$3" dest="$4" digest="${5:-}" immutable="${6:-false}"
  local part="$dest.part" rc

  rm -f "$part"
  CURRENT_PART="$part"
  echo "  Downloading $name ..."
  gh_run "$download_timeout" release download "$tag" -R "$slug" -p "$(glob_escape "$name")" -O "$part" 2>&1
  rc=$?
  if [[ $rc -ne 0 ]]; then
    if [[ $rc -eq 124 ]]; then
      err "  Download of $name timed out after ${download_timeout}s (download_timeout_sec)"
    else
      err "  Download failed: $name"
    fi
    rm -f "$part"
    CURRENT_PART=""
    return 1
  fi

  if [[ "$digest" == sha256:* ]]; then
    local want="${digest#sha256:}" got
    got=$(sha256sum "$part" | awk '{print $1}')
    if [[ "$got" != "$want" ]]; then
      err "  Checksum mismatch for $name (expected $want, got $got)"
      rm -f "$part"
      CURRENT_PART=""
      return 1
    fi
    info "  Verified sha256 ${got:0:16}..."
  else
    warn "  GitHub published no sha256 digest for $name; integrity not verified"
  fi

  if [[ "$immutable" == "true" ]]; then
    if ! gh_run "$gh_timeout" release verify-asset "$tag" "$part" -R "$slug" >/dev/null 2>&1; then
      err "  Release attestation verification failed for $name"
      rm -f "$part"
      CURRENT_PART=""
      return 1
    fi
    info "  Verified release attestation"
  fi

  mv -f "$part" "$dest"
  CURRENT_PART=""
}

# ─── Install (M3) ─────────────────────────────────────────────────────────────
# Record a failed package (counted in the final summary / exit code)
fail_package() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1 ($2)")
  PKG_NOTE="$2"
}

# Remove every version directory in a package dir except the one just installed
cleanup_old_versions() {
  local pkg_dir="$1" keep_tag="$2"
  [[ -n "$pkg_dir" && -n "$keep_tag" && -d "$pkg_dir" && "$pkg_dir" == "$install_path"/* ]] || return 0

  local dir
  for dir in "$pkg_dir"/*/; do
    [[ -d "$dir" ]] || continue
    dir="${dir%/}"
    [[ "${dir##*/}" == "$keep_tag" ]] && continue
    info "  Removing old version: ${dir##*/}"
    rm -rf -- "$dir"
  done
}

# Put the package symlink back after a failed update: restore the previous target,
# or remove a link that was only just created
rollback_link() {
  local link_path="$1" prev_target="$2"
  if [[ -n "$prev_target" ]]; then
    ln -sfn "$prev_target" "$link_path"
    warn "Rolled back $link_path to $prev_target"
  elif [[ -L "$link_path" ]]; then
    rm -f "$link_path"
    warn "Removed $link_path (installation failed)"
  fi
}

# Install or update one package (config index $1).
# Sets PKG_RESULT (installed|current|failed) and PKG_NOTE (short description).
install_package() {
  local i="$1"
  load_package "$i"
  local slug="$PKG_SLUG" name="$PKG_NAME" prerelease="$PKG_PRERELEASE"
  local asset_matcher="$PKG_ASSET_MATCHER" version="$PKG_VERSION"
  PKG_RESULT="failed"
  PKG_NOTE=""

  info "  Slug: $slug"
  local prev_tag=""
  state_read "$slug" && prev_tag="$state_tag"

  if ! fetch_release "$slug" "$prerelease" "$version"; then
    fail_package "$name" "release fetch failed"
    PKG_NOTE="$LAST_ERROR"
    return 1
  fi

  if [[ "$FORCE" != "true" ]] && is_up_to_date "$slug" "$name"; then
    info "  Up to date ($release_tag)"
    PKG_RESULT="current"
    PKG_NOTE="$release_tag"
    return 0
  fi

  if ! find_matching_asset "$asset_matcher"; then
    err "  No matching asset for pattern '$asset_matcher' in $slug"
    fail_package "$name" "no asset matches '$asset_matcher'"
    return 1
  fi

  local pkg_dir version_dir asset_file="$found_asset_name"
  pkg_dir="$install_path/$(slug_to_dir "$slug")"
  version_dir="$pkg_dir/$release_tag"
  mkdir -p "$version_dir"
  if ! cd "$version_dir"; then
    err "  Cannot cd to $version_dir"
    fail_package "$name" "cannot enter install dir"
    return 1
  fi

  if ! download_asset "$slug" "$release_tag" "$asset_file" "$asset_file" "$found_asset_digest" "$release_immutable"; then
    fail_package "$name" "download failed"
    return 1
  fi

  info "  Asset: $asset_file"
  info "  Tag: $release_tag"
  info "  Install dir: $version_dir"

  # Remember the current symlink so a failed update can be rolled back
  local link_path="$symlink_path/$name" prev_target=""
  [[ -L "$link_path" ]] && prev_target=$(readlink "$link_path")

  # an interrupt during post-processing restores the previous link (see cleanup_run)
  PENDING_LINK="$link_path"
  PENDING_PREV="$prev_target"
  if run_post_processors "$i" "$version_dir" "$asset_file" "$name"; then
    PENDING_LINK=""
    state_write "$slug" "$release_tag" "$release_is_prerelease" "$asset_file" "$found_asset_url"
    cleanup_old_versions "$pkg_dir" "$release_tag"
    PKG_RESULT="installed"
    PKG_NOTE="$release_tag"
    [[ -n "$prev_tag" && "$prev_tag" != "$release_tag" ]] && PKG_NOTE="$prev_tag to $release_tag"
    return 0
  fi

  rollback_link "$link_path" "$prev_target"
  PENDING_LINK=""
  local last="${FAILURES[${#FAILURES[@]} - 1]}"
  PKG_NOTE="post-processing failed: ${last#"$name "}"
  return 1
}

do_install() {
  local PKG_COUNT i
  PKG_COUNT=$(get_pkg_count)
  local n_installed=0 n_current=0 n_failed=0
  local start_dir="$PWD" log

  preload_packages
  for ((i = 0; i < PKG_COUNT; i++)); do
    load_package "$i"
    local name="$PKG_NAME"
    package_selected "$i" "$name" "$PKG_AUTO_INSTALL" || continue

    log=$(mktmp)
    if [[ "$VERBOSE" == "true" ]]; then
      echo "Working on $name..."
      install_package "$i"
    else
      install_package "$i" >"$log" 2>&1
    fi
    cd "$start_dir" || true

    case "$PKG_RESULT" in
      installed)
        n_installed=$((n_installed + 1))
        printf '%s %s %s\n' "${C_GREEN}✓${C_RESET}" "$name" "installed ($PKG_NOTE)"
        ;;
      current)
        n_current=$((n_current + 1))
        [[ "$QUIET" == "true" ]] || printf '%s %s %s\n' "=" "$name" "up to date ($PKG_NOTE)"
        ;;
      *)
        n_failed=$((n_failed + 1))
        printf '%s %s: %s\n' "${C_RED}✗${C_RESET}" "$name" "$PKG_NOTE"
        [[ "$VERBOSE" == "true" ]] || sed 's/^/    /' "$log" >&2
        ;;
    esac
    rm -f "$log"
  done
  clear_package_preload

  if [[ "$QUIET" != "true" || $((n_installed + n_failed)) -gt 0 ]]; then
    printf '\n%d installed, %d up to date, %d failed\n' "$n_installed" "$n_current" "$n_failed"
  fi
}

# ─── Config Management (add / edit / delete) ──────────────────────────────────
# These commands edit ghri.yaml as text (splicing whole "- slug: ..." blocks), so comments,
# blank lines and commented-out packages elsewhere in the file are left untouched. Every
# change is validated first and the previous file is kept as ghri.yaml.bak.

# Interactive means stdin is a terminal (GHRI_TEST_INTERACTIVE is a hook for the tests)
is_interactive() {
  [[ -t 0 || -n "${GHRI_TEST_INTERACTIVE:-}" ]]
}

# ask <prompt> [default] [hide]: reads a line into REPLY (empty answer or EOF gives the default).
# The default is shown as " [default]" unless a third argument is given (the prompt marks it itself).
ask() {
  local prompt="$1" default="${2:-}" answer=""
  if [[ -n "$default" && -z "${3:-}" ]]; then
    printf '%s [%s]: ' "$prompt" "$default" >&2
  else
    printf '%s: ' "$prompt" >&2
  fi
  IFS= read -r answer || answer=""
  REPLY="${answer:-$default}"
}

# ask_yn <question> <y|n default>: succeeds for yes
ask_yn() {
  local hint="[y/N]" answer=""
  [[ "$2" == "y" ]] && hint="[Y/n]"
  printf '%s %s ' "$1" "$hint" >&2
  IFS= read -r answer || answer=""
  answer="${answer:-$2}"
  [[ "$answer" =~ ^[Yy] ]]
}

# Run $EDITOR ($VISUAL first; falls back to editor/nano/vim/vi) on file $1
run_editor() {
  local editor="${VISUAL:-${EDITOR:-}}" candidate
  if [[ -z "$editor" ]]; then
    for candidate in editor nano vim vi; do
      if command -v "$candidate" >/dev/null 2>&1; then
        editor="$candidate"
        break
      fi
    done
  fi
  if [[ -z "$editor" ]]; then
    err "No editor found; set \$EDITOR"
    return 1
  fi
  local -a cmd
  read -r -a cmd <<<"$editor"
  "${cmd[@]}" "$1"
}

# Index of the package whose name or slug is $1 (empty if none)
find_package_index() {
  load_config_json || true
  jq -r --arg q "$1" '.packages // [] | to_entries[]
    | select((.value.name // (.value.slug // "" | split("/") | last)) == $q or .value.slug == $q)
    | .key' <<<"$CONFIG_JSON" 2>/dev/null | head -1
}

# Locate the text block of package $1 in the config file.
# Sets BLK_START/BLK_END (1-based, inclusive; trailing blank and comment lines excluded),
# BLK_PREFIX (text before the first key, e.g. "  - ") and BLK_COL (its width).
pkg_block_range() {
  local idx="$1" i l
  local -a starts lines
  mapfile -t lines <"$CONFIG_FILE"
  # Item start lines are found textually (yq's line numbers drift in files like this one)
  local in_packages=false item_indent="" total
  total=$(cfg_query '.packages // [] | length')
  for ((i = 0; i < ${#lines[@]}; i++)); do
    l="${lines[i]}"
    if [[ "$in_packages" == "false" ]]; then
      [[ "$l" =~ ^packages:[[:space:]]*(#.*)?$ ]] && in_packages=true
      continue
    fi
    [[ -z "${l//[[:space:]]/}" || "$l" =~ ^[[:space:]]*# ]] && continue
    [[ "$l" =~ ^[^[:space:]] ]] && break
    if [[ -z "$item_indent" ]]; then
      [[ "$l" =~ ^([[:space:]]*)-[[:space:]] ]] || break
      item_indent="${BASH_REMATCH[1]}"
    fi
    [[ "$l" == "$item_indent"-[[:space:]]* ]] && starts+=($((i + 1)))
  done
  if [[ ${#starts[@]} -ne ${total:-0} ]]; then
    err "Unsupported layout of 'packages' in $CONFIG_FILE (found ${#starts[@]} list items, expected ${total:-0}); expected block style '- slug: ...'"
    return 1
  fi
  BLK_START="${starts[$idx]}"

  l="${lines[BLK_START - 1]}"
  if [[ ! "$l" =~ ^([[:space:]]*-[[:space:]]+) ]]; then
    err "Unsupported layout at line $BLK_START of $CONFIG_FILE (expected '- key: value')"
    return 1
  fi
  BLK_PREFIX="${BASH_REMATCH[1]}"
  BLK_COL=${#BLK_PREFIX}

  local end="${#lines[@]}"
  if ((idx + 1 < ${#starts[@]})); then
    end=$((starts[idx + 1] - 1))
  else
    # last package: it ends before the next top-level key, if any
    for ((i = BLK_START; i < ${#lines[@]}; i++)); do
      l="${lines[i]}"
      [[ -z "${l//[[:space:]]/}" || "$l" =~ ^[[:space:]]*# ]] && continue
      if [[ "$l" =~ ^[^[:space:]] ]]; then
        end=$i
        break
      fi
    done
  fi
  while ((end > BLK_START)); do
    l="${lines[end - 1]}"
    if [[ -z "${l//[[:space:]]/}" || "$l" =~ ^[[:space:]]*# ]]; then
      end=$((end - 1))
    else
      break
    fi
  done
  BLK_END=$end
}

# Package block as a standalone mapping (what the editor shows)
pkg_block_text() {
  local line n=0
  while IFS= read -r line; do
    if ((n == 0)); then
      printf '%s\n' "${line#"$BLK_PREFIX"}"
    else
      local pad="${line%%[![:space:]]*}"
      if ((${#pad} >= BLK_COL)); then
        printf '%s\n' "${line:BLK_COL}"
      else
        printf '%s\n' "${line#"$pad"}"
      fi
    fi
    n=$((n + 1))
  done < <(sed -n "${BLK_START},${BLK_END}p" "$CONFIG_FILE")
}

# Print a standalone mapping file as a list item: $2 before the first line, $3 spaces after
render_item() {
  local file="$1" prefix="$2" col="$3" line n=0 pad
  printf -v pad '%*s' "$col" ''
  while IFS= read -r line || [[ -n "$line" ]]; do
    if ((n == 0)); then
      printf '%s%s\n' "$prefix" "$line"
    elif [[ -z "$line" ]]; then
      printf '\n'
    else
      printf '%s%s\n' "$pad" "$line"
    fi
    n=$((n + 1))
  done <"$file"
}

# New temp file next to the config with the config's permissions
new_candidate() {
  local cand
  cand=$(mktmp ghri-candidate.XXXXXX) || return 1
  printf '%s' "$cand"
}

# candidate_replace <idx> <node file>: config with package idx replaced; prints the new file
candidate_replace() {
  local idx="$1" node="$2" cand
  pkg_block_range "$idx" || return 1
  cand=$(new_candidate) || return 1
  {
    head -n $((BLK_START - 1)) "$CONFIG_FILE"
    render_item "$node" "$BLK_PREFIX" "$BLK_COL"
    tail -n +$((BLK_END + 1)) "$CONFIG_FILE"
  } >"$cand"
  printf '%s' "$cand"
}

# candidate_delete <idx>: config without package idx; prints the new file
candidate_delete() {
  local idx="$1" cand
  pkg_block_range "$idx" || return 1
  cand=$(new_candidate) || return 1
  {
    head -n $((BLK_START - 1)) "$CONFIG_FILE"
    tail -n +$((BLK_END + 1)) "$CONFIG_FILE"
  } >"$cand"
  printf '%s' "$cand"
}

# candidate_append <node file>: config with the package added after the last one
candidate_append() {
  local node="$1" cand count
  cand=$(new_candidate) || return 1
  count=$(cfg_query '.packages // [] | length')
  if [[ "${count:-0}" -gt 0 ]]; then
    pkg_block_range $((count - 1)) || return 1
    {
      head -n "$BLK_END" "$CONFIG_FILE"
      render_item "$node" "$BLK_PREFIX" "$BLK_COL"
      tail -n +$((BLK_END + 1)) "$CONFIG_FILE"
    } >"$cand"
  else
    # no packages yet: let yq create the list (formatting of the file is normalized)
    yq '.packages = [load("'"$node"'")]' "$CONFIG_FILE" >"$cand"
  fi
  printf '%s' "$cand"
}

# The candidate must be valid YAML and pass check_config (errors only). With $2=yaml-only
# just the YAML syntax is checked (deleting the last package is allowed).
validate_candidate() {
  local cand="$1" mode="${2:-full}" saved="$CONFIG_FILE" rc=0
  if ! yq -e '.' "$cand" >/dev/null 2>&1; then
    err "Result is not valid YAML"
    return 1
  fi
  if [[ "$mode" != "yaml-only" ]]; then
    CONFIG_FILE="$cand"
    _CONFIG_SIG=""
    check_config false || rc=1
    CONFIG_FILE="$saved"
    _CONFIG_SIG=""
  fi
  return $rc
}

# Replace the config with the candidate, keeping the old one as <config>.bak
commit_candidate() {
  local staged="$CONFIG_FILE.new.$$"
  cp -p "$CONFIG_FILE" "$CONFIG_FILE.bak" || return 1
  if ! {
    cp "$1" "$staged" && chmod --reference="$CONFIG_FILE" "$staged" 2>/dev/null
    mv -f "$staged" "$CONFIG_FILE"
  }; then
    rm -f "$staged"
    return 1
  fi
  _CONFIG_SIG=""
  info "Saved $CONFIG_FILE (previous version: $CONFIG_FILE.bak)"
}

require_interactive() {
  if ! is_interactive; then
    err "'$1' needs a terminal (stdin is not interactive)"
    return 1
  fi
}

# ghri delete <name>
cmd_delete() {
  local query="$1" idx
  idx=$(find_package_index "$query")
  if [[ -z "$idx" ]]; then
    err "Unknown package: $query"
    return 1
  fi
  pkg_block_range "$idx" || return 1
  echo "Package to delete (lines $BLK_START-$BLK_END of $CONFIG_FILE):"
  sed -n "${BLK_START},${BLK_END}p" "$CONFIG_FILE" | sed 's/^/    /'

  if [[ "$ASSUME_YES" != "true" ]]; then
    require_interactive delete || return 1
    ask_yn "Delete '$query' from the config?" n || {
      echo "Aborted."
      return 0
    }
  fi

  local cand
  cand=$(candidate_delete "$idx") || return 1
  if ! validate_candidate "$cand" yaml-only; then
    rm -f "$cand"
    return 1
  fi
  commit_candidate "$cand" || return 1
  ok "Deleted $query from the config"
  info "Installed files stay until you run: $(basename "$0") --prune"
}

# Edit a standalone mapping file in $EDITOR until the result is valid.
# $1 node file, rest: command building the candidate config (given the node file as last arg),
# e.g. candidate_replace <idx> or candidate_append. If EDIT_ORIGINAL is set and the file is
# unchanged after the first edit, returns 2. On success sets EDIT_CAND and returns 0;
# returns 1 if the user gives up. (Not run in a subshell: the editor needs the terminal.)
edit_until_valid() {
  local node="$1" first=true
  shift
  local cand
  EDIT_CAND=""
  while true; do
    run_editor "$node" || return 1
    if [[ "$first" == "true" && -n "${EDIT_ORIGINAL+x}" && "$(cat "$node")" == "$EDIT_ORIGINAL" ]]; then
      return 2
    fi
    first=false
    if ! yq -e 'tag == "!!map"' "$node" >/dev/null 2>&1; then
      err "The package must be a YAML mapping (slug: ..., asset_matcher: ...)"
    elif cand=$("$@" "$node") && validate_candidate "$cand"; then
      EDIT_CAND="$cand"
      return 0
    else
      [[ -n "${cand:-}" ]] && rm -f "$cand"
      cand=""
    fi
    ask_yn "Edit again?" y || return 1
  done
}

# ghri edit <name>
cmd_edit() {
  local query="$1" idx node rc
  require_interactive edit || return 1
  idx=$(find_package_index "$query")
  if [[ -z "$idx" ]]; then
    err "Unknown package: $query"
    return 1
  fi
  pkg_block_range "$idx" || return 1
  node=$(mktmp ghri-edit.XXXXXX.yaml)
  pkg_block_text >"$node"

  # The editor shows only this package; the config is written only once the result validates
  EDIT_ORIGINAL=$(<"$node")
  edit_until_valid "$node" candidate_replace "$idx"
  rc=$?
  unset EDIT_ORIGINAL
  rm -f "$node"
  case $rc in
    0) ;;
    2)
      echo "No changes."
      return 0
      ;;
    *)
      echo "Aborted; config unchanged."
      return 1
      ;;
  esac
  commit_candidate "$EDIT_CAND" || return 1
  ok "Updated $query"
}

# ─── Add wizard helpers ───────────────────────────────────────────────────────
# Regexes for the host CPU, tab separated: "<matches this arch>	<matches other archs>"
# (GHRI_ARCH overrides uname -m)
arch_patterns() {
  local good bad
  case "${GHRI_ARCH:-$(uname -m)}" in
    x86_64 | amd64)
      good='(amd64|x86_64|x64)'
      bad='(arm|aarch|386|i686|i386)'
      ;;
    aarch64 | arm64)
      good='(arm64|aarch64)'
      bad='(amd64|x86_64|x64|386|i686|i386|armv[67]|armhf|armel)'
      ;;
    armv7* | armhf)
      good='(armv7|armhf|arm)'
      bad='(amd64|x86_64|x64|386|i686|i386|arm64|aarch64)'
      ;;
    i?86)
      good='(386|i686|i386)'
      bad='(amd64|x86_64|x64|arm|aarch)'
      ;;
    *) # unknown CPU: no preference
      good='^$'
      bad='^$'
      ;;
  esac
  printf '%s\t%s' "$good" "$bad"
}

# Best guess for the Linux asset matching this CPU: prints an index into release_asset_names (or nothing)
suggest_asset_index() {
  local i n score best=-1 best_score=0 good bad
  IFS=$'\t' read -r good bad <<<"$(arch_patterns)"
  for ((i = 0; i < release_asset_count; i++)); do
    n="${release_asset_names[$i],,}"
    [[ "$n" =~ (\.sha256|\.sha512|\.sig|\.asc|\.pem|\.sbom|\.txt|\.json|\.sum|checksums|\.md5|\.crt|\.minisig|\.jsonl) ]] && continue
    [[ "$n" =~ (darwin|macos|apple|windows|\.exe|\.msi|\.dmg|\.pkg|freebsd|openbsd|netbsd|s390x|ppc64|riscv|mips) ]] && continue
    [[ "$n" =~ $bad ]] && continue
    score=0
    [[ "$n" == *linux* ]] && score=$((score + 4))
    [[ "$n" =~ $good ]] && score=$((score + 3))
    [[ "$n" =~ (\.tar\.gz|\.tar\.xz|\.tar\.bz2|\.zip|\.deb)$ ]] && score=$((score + 1))
    if ((score > best_score)); then
      best_score=$score
      best=$i
    fi
  done
  ((best >= 0)) && printf '%s' "$best"
}

# Replace the release tag (with and without a leading v) in an asset name by *
generalize_asset_name() {
  local name="$1" tag="$2" bare="${2#v}"
  name="${name//"$tag"/*}"
  [[ -n "$bare" && "$bare" != "$tag" ]] && name="${name//"$bare"/*}"
  printf '%s' "$name"
}

# Escape regex metacharacters
regex_escape() {
  printf '%s' "$1" | sed 's/[][\.*^$+?(){}|\/]/\\&/g'
}

# post_process steps (JSON array) for an asset ($1 = asset file name); $2 = file to take out of archives
suggest_post_process() {
  local lower="${1,,}" inner="$2" matcher_json
  matcher_json=$(jq -n --arg m "$inner" '$m')
  case "$lower" in
    *.deb) printf '["deb"]' ;;
    *.tar.gz) printf '["gunzip", {"name": "tar", "asset_matcher": %s}, "make_exec", "link"]' "$matcher_json" ;;
    *.tar.bz2) printf '["bz2", {"name": "tar", "asset_matcher": %s}, "make_exec", "link"]' "$matcher_json" ;;
    *.tar.xz) printf '["xz", {"name": "tar", "asset_matcher": %s}, "make_exec", "link"]' "$matcher_json" ;;
    *.zip) printf '[{"name": "unzip", "asset_matcher": %s}, "make_exec", "link"]' "$matcher_json" ;;
    *.gz) printf '["gunzip", "make_exec", "link"]' ;;
    *.bz2) printf '["bz2", "make_exec", "link"]' ;;
    *.xz) printf '["xz", "make_exec", "link"]' ;;
    *) printf '["make_exec", "link"]' ;;
  esac
}

# Normalize a github.com URL (https, http, git@, ssh://, www., trailing path,
# .git, query, fragment) to owner/repo. Anything else is echoed unchanged.
slug_from_url() {
  local s="$1"
  s="${s%%[?#]*}"
  case "$s" in
    git@github.com:* | ssh://git@github.com/* | *://github.com/* | *://www.github.com/* | github.com/* | www.github.com/*)
      s="${s#*github.com[/:]}"
      local owner rest repo
      owner="${s%%/*}"
      rest="${s#*/}"
      [[ "$s" == */* ]] || {
        printf '%s\n' "$1"
        return
      }
      repo="${rest%%/*}"
      repo="${repo%.git}"
      s="$owner/$repo"
      ;;
  esac
  printf '%s\n' "$s"
}

# ghri add <owner/repo | github.com URL>: interactive wizard
cmd_add() {
  local slug
  slug=$(slug_from_url "$1")
  require_interactive add || return 1

  if [[ ! "$slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]]; then
    err "'$1' is not a repository slug or GitHub URL (expected owner/repo)"
    return 1
  fi
  if [[ -n "$(find_package_index "$slug")" ]]; then
    err "$slug is already in the config (use: $(basename "$0") edit ${slug##*/})"
    return 1
  fi

  # Release info (optional: without it the matcher is typed in by hand)
  local have_release=true
  info "Fetching the latest release of $slug ..."
  if ! fetch_release "$slug" false ""; then
    have_release=false
    ask_yn "Continue without release information?" n || return 1
    release_tag="" release_asset_names=() release_asset_count=0
  fi

  local asset_name="" matcher=""
  if [[ "$have_release" == "true" ]]; then
    echo "Latest release: $release_tag"
    local i suggested mark
    suggested=$(suggest_asset_index)
    for ((i = 0; i < release_asset_count; i++)); do
      mark=" "
      [[ "$suggested" == "$i" ]] && mark="*"
      printf '  %s %2d) %s\n' "$mark" "$((i + 1))" "${release_asset_names[$i]}" >&2
    done
    local default_choice=""
    [[ -n "$suggested" ]] && default_choice=$((suggested + 1))
    ask "Which asset? (number, or a glob; * marks the suggestion)" "$default_choice"
    if [[ "$REPLY" =~ ^[0-9]+$ ]] && ((REPLY >= 1 && REPLY <= release_asset_count)); then
      asset_name="${release_asset_names[$((REPLY - 1))]}"
      matcher=$(generalize_asset_name "$asset_name" "$release_tag")
    else
      matcher="$REPLY"
      asset_name="$REPLY"
    fi
  fi
  ask "asset_matcher (glob, or /regex/; the version is replaced by *)" "$matcher"
  matcher="$REPLY"
  if [[ -z "$matcher" ]]; then
    err "asset_matcher is required"
    return 1
  fi
  [[ -n "$asset_name" ]] || asset_name="$matcher"

  local name="${slug##*/}"
  ask "Command name (symlink in $symlink_path)" "$name"
  name="$REPLY"

  # Archives usually wrap the binary in a directory, so the default matches ".../<name>" or "<name>"
  local inner="$name"
  case "${asset_name,,}" in
    *.tar.* | *.zip)
      inner="/(^|\\/)$(regex_escape "$name")\$/"
      ask "File to take out of the archive (glob, or /regex/)" "$inner"
      inner="$REPLY"
      ;;
  esac

  local pp
  pp=$(suggest_post_process "$asset_name" "$inner")
  if ask_yn "Add a testrun step (runs the command to check it works)?" y; then
    ask "Arguments for the test run" "--version"
    pp=$(jq -c --arg a "$REPLY" '. + [{"name": "testrun", "args": $a}]' <<<"$pp")
  fi

  local node
  node=$(mktmp ghri-add.XXXXXX.yaml)
  jq -n --arg slug "$slug" --arg name "$name" --arg repo "${slug##*/}" --arg matcher "$matcher" --argjson pp "$pp" \
    '{slug: $slug} + (if $name != $repo then {name: $name} else {} end)
     + {asset_matcher: $matcher, post_process: $pp}' | yq -p json -o yaml -P '.' >"$node"

  echo
  echo "New package:"
  sed 's/^/    /' "$node"
  echo

  local cand choice=""
  while true; do
    ask "Save to $CONFIG_FILE? [Y]es / [e]dit first / [n]o" "y" hide
    choice="${REPLY,,}"
    case "$choice" in
      y | yes)
        cand=$(candidate_append "$node") || {
          rm -f "$node"
          return 1
        }
        if validate_candidate "$cand"; then
          break
        fi
        rm -f "$cand"
        echo "The generated package is invalid; choose [e]dit or [n]o." >&2
        ;;
      e | edit)
        if edit_until_valid "$node" candidate_append; then
          cand="$EDIT_CAND"
          break
        fi
        ;;
      n | no)
        echo "Aborted; nothing written."
        rm -f "$node"
        return 1
        ;;
    esac
  done
  rm -f "$node"
  commit_candidate "$cand" || return 1
  ok "Added $slug"

  if ask_yn "Install $name now?" y; then
    INSTALL_ALL=false
    TARGETS=("$name")
    do_install
    [[ $FAIL -eq 0 ]]
  fi
}

# ─── List ─────────────────────────────────────────────────────────────────────
# `ghri list`: one line per package (name, slug). `list -v`: a markdown document with each
# package's GitHub "About" text, shown through a markdown viewer when one is installed.
do_list() {
  local n i name slug
  n=$(cfg_query '.packages // [] | length')
  if [[ "$VERBOSE" != "true" ]]; then
    for ((i = 0; i < n; i++)); do
      load_package "$i"
      printf '%-20s %s\n' "$PKG_NAME" "$PKG_SLUG"
    done
    return 0
  fi

  local doc="" json desc viewer
  for ((i = 0; i < n; i++)); do
    load_package "$i"
    name="$PKG_NAME" slug="$PKG_SLUG"
    desc=""
    if api_get_var json "/repos/$slug"; then
      desc=$(jq -r '.description // ""' <<<"$json" 2>/dev/null)
    else
      warn "No GitHub info for $slug: ${LAST_ERROR:-request failed}" >&2
    fi
    [[ -n "$desc" ]] || desc=$(cfg_query ".packages[$i].desc // \"\"")
    [[ -n "$desc" ]] || desc="**No description.**"
    doc+="# $slug \`$name\`"$'\n\n'"$desc"$'\n\n'
  done

  if [[ -t 1 ]]; then
    for viewer in glow mdcat mdless; do
      if command -v "$viewer" >/dev/null 2>&1; then
        [[ "$viewer" == glow ]] && viewer="glow -"
        $viewer <<<"$doc"
        return 0
      fi
    done
    for viewer in bat batcat; do
      if command -v "$viewer" >/dev/null 2>&1; then
        "$viewer" -l markdown --paging=never <<<"$doc"
        return 0
      fi
    done
  fi
  # Plain markdown, paragraphs wrapped for readability
  local line
  while IFS= read -r line; do
    if [[ "$line" == "#"* ]]; then printf '%s\n' "$line"; else fold -s -w 78 <<<"$line"; fi
  done <<<"${doc%$'\n\n'}"
}

# ─── Shell Completion ─────────────────────────────────────────────────────────
# `ghri completion bash|zsh|fish` prints a completion script. Package names come from
# `ghri --names` (reads the config, no network).
print_completion() {
  case "$1" in
    bash) completion_bash ;;
    zsh) completion_zsh ;;
    fish) completion_fish ;;
    *)
      err "Unknown shell '$1' (expected bash, zsh or fish)"
      return 2
      ;;
  esac
}

completion_bash() {
  cat <<'COMPEOF'
# bash completion for ghri; load with: source <(ghri completion bash)
_ghri() {
  local cur="${COMP_WORDS[COMP_CWORD]}" first="${COMP_WORDS[1]:-}" cmd="${COMP_WORDS[0]}"
  local commands="install add edit delete rm remove list completion"
  local opts="--outdated --list --dry-run --check --force --no-cache --refresh --quiet --verbose --prune --yes --json --version --help -o -l -n -c -f -r -q -v -y -h"
  local names
  COMPREPLY=()
  if [[ $COMP_CWORD -eq 1 ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$commands $opts" -- "$cur")
    return
  fi
  case "$first" in
    install | edit | delete | rm | remove)
      if [[ "$cur" == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
      else
        names=$("$cmd" --names 2>/dev/null)
        mapfile -t COMPREPLY < <(compgen -W "$names" -- "$cur")
      fi
      ;;
    completion)
      mapfile -t COMPREPLY < <(compgen -W "bash zsh fish" -- "$cur")
      ;;
    add) ;; # an owner/repo slug: nothing to suggest
    *)
      if [[ "$cur" == -* ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$opts" -- "$cur")
      else
        names=$("$cmd" --names 2>/dev/null)
        mapfile -t COMPREPLY < <(compgen -W "$names" -- "$cur")
      fi
      ;;
  esac
}
complete -F _ghri ghri ghri.sh
COMPEOF
}

completion_zsh() {
  cat <<'COMPEOF'
#compdef ghri ghri.sh
# zsh completion for ghri; save as _ghri in a directory of your $fpath, e.g.
#   ghri completion zsh > ~/.zfunc/_ghri     (with: fpath=(~/.zfunc $fpath); autoload -Uz compinit; compinit)
_ghri() {
  local -a commands opts names
  commands=(
    'install:install or update packages'
    'add:add a package with a wizard'
    'edit:edit a package in $EDITOR'
    'delete:remove a package from the config'
    'rm:remove a package from the config'
    'remove:remove a package from the config'
    'list:list configured packages'
    'completion:print a shell completion script'
  )
  opts=(
    '(-o --outdated --list -l --dry-run -n)'{-o,--outdated,--list,-l,--dry-run,-n}'[show installed vs. latest version]'
    '(-c --check)'{-c,--check}'[validate the config and required tools]'
    '(-f --force)'{-f,--force}'[reinstall even if current]'
    '(-r --no-cache --refresh)'{-r,--no-cache,--refresh}'[do not use cached GitHub API responses]'
    '(-q --quiet)'{-q,--quiet}'[only report changes and failures]'
    '(-v --verbose)'{-v,--verbose}'[full output per package]'
    '--prune[remove files of packages no longer in the config]'
    '(-y --yes)'{-y,--yes}'[do not ask for confirmation]'
    '--json[machine-readable output for --outdated]'
    '--version[show the version]'
    '(-h --help)'{-h,--help}'[show help]'
  )
  if (( CURRENT == 2 )); then
    _describe -t commands 'command' commands
    _arguments -s $opts
    return
  fi
  case $words[2] in
    install | edit | delete | rm | remove)
      names=(${(f)"$($words[1] --names 2>/dev/null)"})
      _arguments -s $opts '*:package:(${names})'
      ;;
    completion)
      _values 'shell' bash zsh fish
      ;;
    add)
      _arguments -s $opts '1:repository (owner/repo): '
      ;;
    *)
      names=(${(f)"$($words[1] --names 2>/dev/null)"})
      _arguments -s $opts '*:package:(${names})'
      ;;
  esac
}
_ghri "$@"
COMPEOF
}

completion_fish() {
  cat <<'COMPEOF'
# fish completion for ghri; save as ~/.config/fish/completions/ghri.fish:
#   ghri completion fish > ~/.config/fish/completions/ghri.fish
function __ghri_names
    set -l cmd (commandline -poc)[1]
    $cmd --names 2>/dev/null
end

for prog in ghri ghri.sh
    set -l commands install add edit delete rm remove list completion
    complete -c $prog -f
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a install -d "install or update packages"
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a add -d "add a package with a wizard"
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a edit -d "edit a package in \$EDITOR"
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a delete -d "remove a package from the config"
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a rm -d "remove a package from the config"
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a remove -d "remove a package from the config"
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a list -d "list configured packages"
    complete -c $prog -n "not __fish_seen_subcommand_from $commands" -a completion -d "print a shell completion script"
    complete -c $prog -n "__fish_seen_subcommand_from install edit delete rm remove" -a "(__ghri_names)"
    complete -c $prog -n "__fish_seen_subcommand_from completion" -a "bash zsh fish"
    complete -c $prog -s o -l outdated -d "show installed vs. latest version"
    complete -c $prog -l list -d "same as --outdated"
    complete -c $prog -l dry-run -d "same as --outdated"
    complete -c $prog -s c -l check -d "validate the config and required tools"
    complete -c $prog -s f -l force -d "reinstall even if current"
    complete -c $prog -s r -l no-cache -d "do not use cached GitHub API responses"
    complete -c $prog -l refresh -d "same as --no-cache"
    complete -c $prog -s q -l quiet -d "only report changes and failures"
    complete -c $prog -s v -l verbose -d "full output per package"
    complete -c $prog -l prune -d "remove files of packages no longer in the config"
    complete -c $prog -s y -l yes -d "do not ask for confirmation"
    complete -c $prog -l json -d "machine-readable output for --outdated"
    complete -c $prog -l version -d "show the version"
    complete -c $prog -s h -l help -d "show help"
end
COMPEOF
}

# ─── Prune ────────────────────────────────────────────────────────────────────
# Print what belongs to packages that are no longer in the config, one "kind<TAB>path"
# per line: install (version dirs), record (installed-state cache), link (symlink into install_path)
find_orphans() {
  local -A keep=()
  local slug d l target rel
  while IFS= read -r slug; do
    [[ -n "$slug" ]] && keep["$(slug_to_dir "$slug")"]=1
  done < <(cfg_query '.packages[]? | .slug // empty')

  for d in "$install_path"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    [[ -n "${keep[${d##*/}]:-}" ]] || printf 'install\t%s\n' "$d"
  done

  for d in "$state_path"/*/ "$cache_path"/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    [[ "${d##*/}" == "api" ]] && continue
    [[ -n "${keep[${d##*/}]:-}" ]] || printf 'record\t%s\n' "$d"
  done

  for l in "$symlink_path"/*; do
    [[ -L "$l" ]] || continue
    target=$(readlink "$l")
    [[ "$target" == "$install_path"/* ]] || continue
    rel="${target#"$install_path"/}"
    [[ -n "${keep[${rel%%/*}]:-}" ]] || printf 'link\t%s\n' "$l"
  done
}

# List orphans and delete them after confirmation (or with --yes).
# System-wide deb installs are never uninstalled.
do_prune() {
  local orphans=() line kind path
  mapfile -t orphans < <(find_orphans)

  if [[ ${#orphans[@]} -eq 0 ]]; then
    ok "Nothing to prune"
    return 0
  fi

  echo "No longer in the config:"
  for line in "${orphans[@]}"; do
    printf '  %-8s %s\n' "${line%%$'\t'*}" "${line#*$'\t'}"
  done
  echo "(packages installed with the deb post-processor stay installed; remove them with apt)"

  if [[ "$ASSUME_YES" != "true" ]]; then
    if [[ ! -t 0 ]]; then
      warn "Not interactive; nothing deleted. Re-run with --yes to delete."
      return 0
    fi
    local answer
    read -r -p "Delete these ${#orphans[@]} item(s)? [y/N] " answer
    [[ "$answer" =~ ^[Yy] ]] || {
      echo "Aborted."
      return 0
    }
  fi

  for line in "${orphans[@]}"; do
    kind="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    case "$kind" in
      install) [[ "$path" == "$install_path"/* ]] && rm -rf -- "$path" ;;
      record) [[ "$path" == "$state_path"/* || "$path" == "$cache_path"/* ]] && rm -rf -- "$path" ;;
      link) [[ "$path" == "$symlink_path"/* ]] && rm -f -- "$path" ;;
    esac
  done
  ok "Pruned ${#orphans[@]} item(s)"
}

# ─── Main ─────────────────────────────────────────────────────────────────────
# Load KEY=VALUE pairs from a .env file next to the script (or $1).
# Not sourced (no code execution); existing environment variables win.
# shellcheck disable=SC2120  # optional path argument (tests pass one)
load_env() {
  local env_file="${1:-$SCRIPT_DIR/.env}"
  [[ -f "$env_file" ]] || return 0

  local line key value
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    [[ "$line" == *=* ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi
    [[ -z "${!key+x}" ]] && export "$key=$value"
  done <"$env_file"
}

main() {
  load_env
  color_init
  parse_args "$@"

  # Installing is never implicit: a bare run shows the help, loose names are an error
  if [[ "$MODE" == "install" && "$EXPLICIT_INSTALL" != "true" ]]; then
    if [[ $# -eq 0 ]]; then
      show_help
      return 0
    fi
    err "Nothing to do. To install, use the install command: $(basename "$0") install ${TARGETS[*]}"
    return 2
  fi
  if [[ "$MODE" == "completion" ]]; then
    print_completion "$SUBARG"
    return $?
  fi

  init_run
  find_config
  detect_tools
  detect_yq
  load_config

  if [[ "$MODE" == "names" ]]; then
    cfg_query '.packages[]? | (.name // (.slug // "" | split("/") | last))'
    return 0
  fi

  if [[ "$MODE" == "list" ]]; then
    do_list
    return $?
  fi

  if [[ "$MODE" == "check" ]]; then
    if check_config true; then
      ok "Config OK ($CHECK_WARNINGS warning(s))"
      return 0
    fi
    err "$CHECK_ERRORS error(s) in config"
    return 1
  fi

  # One mutating run at a time
  case "$MODE" in
    install | prune | add | edit | delete) acquire_lock || return 1 ;;
  esac

  # Config commands work on ghri.yaml itself (it may be broken while being fixed)
  case "$MODE" in
    add | edit | delete)
      "cmd_$MODE" "$SUBARG"
      return $?
      ;;
  esac

  # Pre-flight: abort before touching the network on config problems
  if ! check_config "$VERBOSE"; then
    err "Config check failed ($CHECK_ERRORS error(s)); fix ghri.yaml or run with --check"
    return 1
  fi
  check_targets || return 1

  case "$MODE" in
    outdated)
      do_outdated
      ;;
    install)
      do_install
      ;;
    prune)
      do_prune
      ;;
  esac

  # Summary
  if [[ $FAIL -gt 0 ]]; then
    err ""
    err "$FAIL package(s) failed:"
    local f
    for f in "${FAILURES[@]}"; do
      err "  - $f"
    done
    return 1
  fi

  # --outdated: 10 when something is not current (cron/scripts can act on it)
  if [[ "$MODE" == "outdated" && $OUTDATED_COUNT -gt 0 ]]; then
    return 10
  fi
}

# Only run main when executed directly, not when sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
  exit $?
fi
