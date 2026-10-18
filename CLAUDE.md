# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Environment

Isolated dev environment (image built from `Dockerfile.az` from `apt-packages.txt`: Debian 13 with gh, yq-go, jq, git, make, shellcheck, shfmt, zsh, fish, ...). If tools are missing, talk to the human. `sudo` works without a password. Permanent changes (Dockerfile, user config) need the human's OK.

## What this is

GHRI: GitHub Release Installer. Single bash script `ghri.sh` downloads the latest release of each GitHub repo configured in `ghri.yaml`, verifies it, post-processes the asset, and symlinks it into `symlink_path` (which must be in `PATH`; `/home/heilig/bin` here). It replaced an older PHP implementation (`ghri.php`, phar/composer tooling, all gone).

Runtime deps: `gh` (all GitHub API access and downloads; it replaced curl), `yq` (Go version v4, `apt install yq-go`; remove the Python `yq` first), `jq`, bash >= 4, standard Unix tools (`tar`, `unzip`, `bunzip2`, `gunzip`, `xz`, `find`, `sha256sum`, `chmod`, `ln`, `realpath`). `dpkg`, `sudo` only for the `deb` post-processor. Every command the script uses is listed in `REQUIRED_TOOLS` (command:package) and checked up front by `detect_tools`, which reports all missing ones at once with an `apt install` hint; tools needed by configured processors are checked by `check_config` (`processor_tools`).

## Commands

```
make help                  # list targets
make deps                  # apt-install everything in apt-packages.txt (sudo)
make test                  # unit + e2e tests, sandboxed, fake gh, no network/sudo
make test-integration      # real deb install test (sudo + network, cleans up after itself)
make test-live             # smoke test against the real GitHub API + real gh (GHRI_LIVE=1; needs network)
make lint                  # shellcheck
make fmt / make fmt-check  # shfmt -i 2 -ci
make check                 # ghri.sh --check
make all (= make ci)       # lint + fmt-check + test + check
make outdated | prune      # wrappers (outdated treats exit 10 as success)

./ghri.sh                  # prints the help: nothing is installed without the install command
./ghri.sh install          # install/update all auto_install packages (one line per package)
./ghri.sh install pex yt-dlp   # specific packages (by name)
./ghri.sh --outdated | -o  # installed vs latest (aliases: --list/-l, --dry-run/-n); --json for scripts
./ghri.sh completion bash|zsh|fish   # print a completion script (package names via hidden --names)
./ghri.sh --version
./ghri.sh --check | -c     # validate config + tools, then exit
./ghri.sh install --force | -f   # reinstall even if current
./ghri.sh install --no-cache | -r   # ignore cached API responses (alias --refresh); independent of --force
./ghri.sh install --quiet | -q   # only changes and failures (cron friendly)
./ghri.sh --prune [--yes]  # remove installs/records/links of packages no longer in the config
./ghri.sh add owner/repo    # interactive wizard (also: edit NAME, delete NAME [--yes]); text-splices ghri.yaml
./ghri.sh --verbose | -v   # full per-package output
GHRI_SYMLINK_PATH=~/bin ./ghri.sh install   # override symlink_path

./shpec test/shpec/cache_shpec.sh   # single test file
```

Exit codes: 0 ok, 1 failures, 2 usage error, 10 `--outdated` found packages that are not current.

Run with `/home/heilig/bin` in `PATH`, otherwise `check_in_path`/`testrun` fail for linked packages.

## GitHub auth / `.env`

`ghri.sh` loads `KEY=VALUE` lines from `.env` next to the script (`load_env`: not sourced, no code execution, existing env vars win). Put `GITHUB_TOKEN=...` (or `GH_TOKEN`) there, or use `gh auth login`: unauthenticated API access is 60 req/h, which a full install exceeds. `.env` is not in git (there is no repo here; add it to `.gitignore` if that changes).

## Config (`ghri.yaml`)

`SCRIPT_DIR` is the directory of the real script (symlinks like `~/bin/ghri` are resolved via `realpath`), so config and `.env` are found next to `ghri.sh`, not next to the link. Found by `find_config` in `SCRIPT_DIR/ghri.yaml`, `SCRIPT_DIR/ghri/ghri.yaml`, `SCRIPT_DIR/../ghri/ghri.yaml` (first wins).

| Key | Default | Notes |
|---|---|---|
| `install_path` | `./install` | Downloads live here. Relative to script dir. |
| `symlink_path` | `./bin` | Symlinks to binaries. Relative to script dir. Env `GHRI_SYMLINK_PATH` overrides. |
| `cache_path` | `./.cache` | Cached API responses (`api/`); safe to delete. Relative to script dir. |
| `state_path` | `./.state` | Installed-version records and the run lock. Keep it. |
| `timeout_sec` / `download_timeout_sec` | 60 / 900 | Time limits (`timeout`) for each `gh api` call / each asset download. |
| `cache_lifetime_sec` | 600 | Age below which cached API responses are used without any request. |
| `global_post_process.prepend` / `.append` | [] | Processor names run before / after every package's own list. |
| `packages[].slug` | required | `owner/repo` |
| `packages[].name` | second part of slug | Symlink and command name. For deb packages it must equal the installed command (`check_in_path`, `testrun` use it). Unique. |
| `packages[].desc` | | Info only. |
| `packages[].asset_matcher` | `*` | Glob or regex (`/pattern/`) against release asset names. First match wins. |
| `packages[].post_process` | [] | Processors; each is a string or a map with `name`, optional `asset_matcher`, optional `args` (list or single string). |
| `packages[].auto_install` | true | `false` skips the package in `install` without names (still installable by name). |
| `packages[].prerelease` | false | Accept pre-releases (newest by `created_at` from `/releases`). |
| `packages[].version` | latest | Pin an exact release tag (`/releases/tags/<tag>`), or a glob / `/regex/` (e.g. `v1.*`): newest non-draft release whose tag matches (pre-releases only if `prerelease: true`). |

Adding a package: at minimum `slug` and `asset_matcher`. A bare binary needs:

```yaml
- slug: owner/repo
  name: binary-name       # optional if second slug part matches
  asset_matcher: "some-pattern"
  post_process:
    - make_exec
    - link
    - name: testrun       # optional but recommended
      args: --version
```

## Architecture

`ghri.sh` is one file organized in banner-delimited sections. `main` flow: `load_env`, `color_init`, `parse_args`, `find_config`, `detect_tools`, `detect_yq` (version >= 4), `load_config`; mode `check` runs `check_config` and exits; otherwise `check_config` runs as a pre-flight (errors abort before any network access), `check_targets` verifies named packages exist, then `do_outdated` or `do_install`. `main` only runs when executed directly, not when sourced; this is what makes the functions testable. Processing is sequential.

- **Config access**: `load_config_json` converts the YAML to JSON once (`yq -o=json`) into `CONFIG_JSON`; `cfg_query`/`yaml_field`/`get_pkg_*` run `jq` against it (paths are indexed by package position `$i`). Loops use `load_package` (one jq call -> `PKG_SLUG`, `PKG_NAME`, `PKG_PRERELEASE`, `PKG_ASSET_MATCHER`, `PKG_VERSION`, `PKG_AUTO_INSTALL`). A first load inside `$(...)` is lost to the parent shell, so `load_config` primes it. Paths in config resolve relative to script dir via `realpath -m`.
- **Config check** (`check_config`, `CHECK_JQ`): one jq program emits findings (types, slug format, unknown keys as warnings, processor names, regex matchers), bash adds processor existence + required tools, duplicate names, `symlink_path` in `PATH`. Warnings are shown only in `--check`/`--verbose`; errors always abort.
- **API + cache**: `fetch_release` -> `api_get_var` -> `api_get` -> `gh api -i`. Cached bodies live in `cache_path/api/<path>.json` with an `.etag`. Younger than `cache_lifetime_sec`: no request. Older: conditional request (`If-None-Match`), a 304 costs no rate limit. Rate-limit errors print the reset time. `api_get_var` exists so `err()` messages stay in `LAST_ERROR` (no subshell). `--no-cache` (`NO_CACHE`) skips both the TTL check and the conditional request: always a full request, result still written to the cache.
- **Download + verification** (`download_asset`): `gh release download <tag> -p <exact name> -O name.part`; sha256 must equal the asset `digest` GitHub records (warning if none); for `immutable` releases `gh release verify-asset` additionally checks the signed attestation. Only then is `.part` renamed into place.
- **Installed state**: per slug `state_path/<owner>_<repo>/release.dat` (`state_read`/`state_write`; records that older versions kept in `cache_path` are migrated on first read) (`tag_name`, `prerelease`, `asset_name`, `download_url`) is written only after all post-processors succeeded. `is_up_to_date` (recorded tag == release tag, version dir exists, symlink or `PATH` command resolves) makes a run skip the package entirely; `--force` overrides.
- **Install flow** (`install_package`): fetch release, up-to-date check, find asset, download+verify into `install_path/<owner>_<repo>/<tag>/`, run post-processors; on success write `release.dat` and `cleanup_old_versions` (deletes every other version dir of the package). On failure `rollback_link` restores the previous symlink (or removes a fresh one); the old version dir and `release.dat` are untouched. deb installs cannot be rolled back. Failures are recorded via `fail_package`/`FAILURES`; processing continues and the run exits 1 at the end.
- **Output**: `do_install` runs `install_package` with stdout/stderr captured into a temp log and prints one line per package (`✓` installed, `=` up to date, `✗` failed, with the log dumped on failure); `-v` shows everything live. Anything that must reach the user in quiet mode (the `deb` prompt) talks to `/dev/tty` directly.
- **Config management** (`cmd_add`, `cmd_edit`, `cmd_delete`; first CLI word, handled in `main` before the pre-flight so a broken config can still be fixed): ghri.yaml is edited as text, not through `yq -i` (which re-indents and drops blank lines and comments). `pkg_block_range` finds a package's lines by scanning from `packages:` (yq's `line` numbers drift in long files; the item count must match `yq length`, only block-style `- key: value` lists are supported), trailing blank/comment lines are not part of the block. `candidate_replace/delete/append` build a temp file next to the config, `validate_candidate` runs YAML + `check_config` (errors only) on it, `commit_candidate` keeps `ghri.yaml.bak` and moves it into place. `edit_until_valid` runs `$VISUAL`/`$EDITOR` (not in a subshell, the editor needs the terminal). The `add` wizard (`suggest_asset_index`, `generalize_asset_name` replacing the tag by `*`, `suggest_post_process`; archive inner file defaults to regex `/(^|\/)name$/` because archives often wrap the binary in a directory) renders the new package via jq + `yq -p json -o yaml -P`. Prompts go through `ask`/`ask_yn`; `is_interactive` is stdin-is-a-tty (tests set `GHRI_TEST_INTERACTIVE`). The first CLI word is a command (`add`, `edit`, `delete`/`rm`/`remove`, `install`). Installing is never implicit: `main` prints the help for a bare run and exits 2 for loose names or install-only flags (`EXPLICIT_INSTALL`); `install` takes any number of names, so packages called add/edit/delete stay installable.
- **Prune** (`find_orphans`, `do_prune`): install dirs, installed-state records and symlinks (pointing into `install_path`) whose package slug is no longer configured; asks (or `--yes`), never uninstalls deb packages, never touches the `api` cache or unrelated links.
- **Run safety**: `init_run` (in `main`) makes a per-run temp dir (`mktmp`) and installs traps; `cleanup_run` (EXIT) removes it and any `CURRENT_PART`, and restores the previous symlink if an update was cut short (`PENDING_LINK`/`PENDING_PREV`, set around post-processing). Interrupt messages go to fd 3 (the real stderr) because per-package output is captured. `acquire_lock` takes `flock` on `state_path/ghri.lock` for install, prune and the config commands. `gh_run` wraps every `gh` call in `timeout` (exit 124 is reported as a timeout).
- **Output formats**: `do_outdated` builds rows once; `--json` prints a JSON array (`status` is one of error, not-installed, update-available, needs-reinstall, up-to-date), `--quiet` drops current packages. Hidden `--names` prints package names for the completion scripts, which `completion_bash/zsh/fish` print as quoted heredocs.
- **Platform**: `detect_tools` rejects non-Linux (override `GHRI_ALLOW_UNSUPPORTED=1`). `arch_patterns`/`suggest_asset_index` pick the asset for `uname -m` (override `GHRI_ARCH`).
- **Asset selection**: `match_asset` does fnmatch globs, or regex when the pattern looks like `/.../`. The per-processor `asset_matcher` is reused for picking files inside extracted archives (`find_single_match`).
- **Post-processors** (`run_post_processors`): chain is `global_post_process.prepend` + package `post_process` + `global_post_process.append`. Contract: `pp_<name> asset_file package_name working_dir asset_matcher quiet [args...]`; return 0/non-zero; a processor that changes the file sets `CURRENT_ASSET` (the only shared state), which the runner passes to the next one. Existing: `make_exec` (chmod 0755), `link` (symlink to resolved asset), `check_in_path` (only `command -v <name>`), `deb` (`sudo dpkg -i`; on failure asks via `/dev/tty` whether to run `sudo apt-get -f install -y` and retry, non-interactive just fails), `testrun` (runs linked binary / PATH command with args, exit != 0 fails, prints first output line unless `quiet: true`; no `eval`), `gunzip`, `bz2`, `xz`, `tar`, `unzip`. To add one: write `pp_<name>` per the contract, add its tools to `processor_tools`, then use it in `ghri.yaml`.

## Tests

shpec (vendored `./shpec`), files `test/shpec/*_shpec.sh`; `helpers.sh` sources `ghri.sh` and creates a throwaway sandbox (`$TEST_SANDBOX`, with `install_path`/`cache_path`/`symlink_path` inside it, removed on exit), so nothing outside it is touched. `test/run_tests.sh` (used by `make test`) exits non-zero on failures.

- `test/fakes/gh` is a fake `gh` (canned releases from `$GHRI_FAKE_DIR`, ETags/304, rate limiting, downloads, `verify-asset`, call log); `test/shpec/fake_gh.sh` has the fixtures (`fake_release`, `fake_config`, ...). `install_e2e_shpec.sh` drives `do_install`/`do_outdated`/`api_get` against it: install, up to date, update + cleanup, checksum mismatch, attestation, rollback, pin, archives, failures, rate limit.
- `release_features_shpec.sh` (version, example config, `--json`, arch, time limits, lock, real-process interrupt tests via `setsid` + SIGTERM, state migration), `completion_shpec.sh` (bash functional, fish functional and zsh syntax when those shells are installed), `state_shpec.sh`.
- `live_shpec.sh` is opt-in (`GHRI_LIVE=1`, `make test-live`): the real `gh` and API against small public releases (jq, viu, cli/cli attestation) in the sandbox.
- `config_mgmt_shpec.sh` covers add/edit/delete (stdin answers via `mgmt_run`, a fake `$EDITOR` script, byte-for-byte checks that only the target block changed, validation loop, wizard flows incl. install-now).
- `config_check_shpec.sh` covers `check_config`/`check_targets`; the rest are unit tests per area.
- `deb_integration_shpec.sh` is opt-in (`GHRI_INTEGRATION=1`, `make test-integration`): downloads `toilet` (missing deps) from the Debian mirror, runs `pp_deb` in a pty via `script` with `sudo`, answers the fix prompt `y`/`n`, purges what it added. Needs passwordless sudo, `script`, network.
- Pitfall: shpec's `assert grep` takes (text, pattern) and is vacuously true when used with a here-string. Use `assert_contains <text> <literal>` / `assert_matches <text> <regex>` from `helpers.sh`.

## Layout notes

- `install/` (downloads), `.cache/` (API cache) and `.state/` (installed records, lock) are runtime output, not source (all in `.gitignore`). Tests write only into their sandbox.
- `apt-packages.txt` is the single list of Debian packages (runtime, dev tooling, extras) used by `Dockerfile.az` and `make deps`; a test checks it covers `REQUIRED_TOOLS` and `processor_tools`.
- `Dockerfile.az` is the dev-environment image, not a ghri deliverable. `.github/workflows/ci.yml` runs `make ci` in a `debian:13` container (written without being able to run it; adjust or delete if CI lives elsewhere).
