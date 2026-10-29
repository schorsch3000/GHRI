# ghri: GitHub Release Installer

`ghri` keeps command line tools from GitHub releases up to date. You list the repositories in a YAML file; `ghri.sh` downloads the latest release of each, verifies it, unpacks it, and symlinks the binary into a directory on your `PATH`.

It is a single bash script (`ghri.sh`) driven by `ghri.yaml`.

```
$ ./ghri.sh install
✓ viu installed (v1.5.0 to v1.6.1)
✓ hcloud installed (v1.69.0 to v1.70.1)
✗ mago: no asset matches 'mago*x86_64*linux-gnu.tar.gz'
    ...log of the failing step...

2 installed, 39 up to date, 1 failed
```

## Features

- **One line per package.** Full output only for failures, or everywhere with `-v`.
- **Skips what is current.** The installed version is recorded, so a repeat run downloads nothing. `--force` reinstalls anyway.
- **Verified downloads.** The sha256 of every asset must match the digest GitHub records for it. For immutable releases the signed release attestation is verified too (`gh release verify-asset`).
- **Safe updates.** The new version is installed next to the old one. If any step fails, the previous symlink is restored and the old version is kept. Old versions are removed only after a successful update.
- **Rate-limit friendly.** API responses are cached and revalidated with ETags (a `304` costs no rate limit). `--no-cache` skips the cache for one run. Authenticate through `.env` or `gh auth login` for 5000 requests/hour.
- **Post-processing pipeline.** Decompress, extract archives, `chmod`, symlink, run a smoke test, install `.deb` files.
- **Pin versions** to an exact tag or a pattern such as `v1.*`.
- **Pre-flight check** of the config and of every external command, before anything is downloaded.
- **Robust runs.** One run at a time (lock file), time limits for API calls and downloads, and Ctrl-C or a kill leaves no partial downloads or temp files behind and restores the previous version if an update was cut short.
- **Scriptable.** `--outdated --json`, exit code 10 when something is not current, `--quiet` for cron.
- **Shell completion** for bash, zsh and fish.

## Requirements

Linux (GNU userland) with bash 4+ and:

| Tool | Debian package | Used for |
|---|---|---|
| `gh` | `gh` | GitHub API access and downloads |
| `yq` (Go version, v4) | `yq-go` | reading `ghri.yaml` (remove the Python `yq` first) |
| `jq` | `jq` | JSON handling |
| `sha256sum`, `timeout`, `awk`, `sed`, `grep`, `find`, `flock`, ... | `coreutils`, `gawk`, `sed`, `grep`, `findutils`, `util-linux` | the script itself |
| `tar`, `unzip`, `gunzip`, `bunzip2`, `xz` | `tar`, `unzip`, `gzip`, `bzip2`, `xz-utils` | only for the post-processors you use |
| `dpkg`, `sudo` | `dpkg`, `sudo` | only for the `deb` post-processor |

ghri supports Linux only (it relies on GNU `stat`, `date` and `realpath`); the asset suggestions of `ghri add` follow `uname -m` (x86_64, arm64, armv7, i386).

`apt-packages.txt` lists every package (including development tools); `make deps` installs them. `./ghri.sh --check` tells you what is missing and the `apt install` command for it.

## Quick start

```sh
# 1. create your config (ghri.yaml is not part of the repository, it is yours)
cp ghri.example.yaml ghri.yaml
$EDITOR ghri.yaml                        # or: ./ghri.sh add owner/repo

# 2. (optional) a token for a higher API rate limit, read from .env next to the script
echo 'GITHUB_TOKEN=ghp_...' > .env      # or: gh auth login

# 3. make sure symlink_path is on your PATH, then validate the config
export PATH="$PATH:$HOME/bin"
./ghri.sh --check

# 4. see what would change, then install
./ghri.sh --outdated
./ghri.sh install

# 5. optional: a short command and shell completion
ln -s "$PWD/ghri.sh" ~/bin/ghri                      # the config is found next to the real script
ghri completion bash > ~/.local/share/bash-completion/completions/ghri
```

## Usage

```
./ghri.sh install          install/update all packages
./ghri.sh install pex yt-dlp   only these packages (by name)
./ghri.sh --outdated       installed vs. latest version (aliases: --list, --dry-run, -o, -l, -n)
./ghri.sh --outdated --json machine-readable (name, slug, installed, latest, status, pinned, error)
./ghri.sh --check          validate the config and required tools, then exit
./ghri.sh install --force  reinstall even if the installed version is current
./ghri.sh install --no-cache  ask GitHub again instead of using cached API responses (-r, --refresh)
./ghri.sh install --quiet  only report changes and failures (good for cron)
./ghri.sh install --verbose  full output for every package
./ghri.sh --prune          remove installs, records and links of packages no longer in the config
./ghri.sh --yes            do not ask for confirmation (with --prune)
./ghri.sh add owner/repo    interactive wizard that adds a package to ghri.yaml
./ghri.sh edit NAME        edit one package's part of ghri.yaml in $EDITOR
./ghri.sh delete NAME      remove a package from ghri.yaml (asks first; --yes skips the question)
./ghri.sh completion bash|zsh|fish   print a shell completion script
./ghri.sh --version
GHRI_SYMLINK_PATH=~/bin ./ghri.sh install    override symlink_path for one run
```

Exit codes: `0` ok, `1` one or more failures, `2` usage error, `10` `--outdated` found packages that are not current.

`ghri.sh` reads `KEY=VALUE` lines from a `.env` file next to it (not sourced; variables already set in your environment win). Only one mutating run (`install`, `--prune`, `add`, `edit`, `delete`) can run at a time; a second one stops with a message.

### Shell completion

```sh
# bash
ghri completion bash > ~/.local/share/bash-completion/completions/ghri     # or: source <(ghri completion bash)
# zsh (fpath must contain ~/.zfunc, then compinit)
ghri completion zsh > ~/.zfunc/_ghri
# fish
ghri completion fish > ~/.config/fish/completions/ghri.fish
```

It completes commands, options and the package names from your config, for both `ghri` and `ghri.sh`.

## Configuration

`ghri.yaml` is looked up next to the real `ghri.sh` (symlinks are resolved), in `ghri/` next to it, and in `../ghri/`. Start from `ghri.example.yaml`.

```yaml
install_path: ./install        # downloads, one directory per package and version
symlink_path: /home/me/bin     # where binaries are linked; must be on PATH
cache_path: ./.cache          # cached GitHub API responses (safe to delete)
state_path: ./.state          # which version of each package is installed (keep this)
cache_lifetime_sec: 600        # API responses younger than this are used without a request
prerelease: false             # default for every package: true = newest release of any kind
timeout_sec: 60                # limit for each GitHub API call
download_timeout_sec: 900      # limit for each asset download
global_post_process:
  append:
    - check_in_path            # runs after every package's own steps

packages:
  - slug: atanunq/viu
    asset_matcher: viu-x86_64-unknown-linux-musl
    post_process:
      - make_exec
      - link
      - name: testrun
        args: --version

  - slug: hetznercloud/cli
    name: hcloud
    asset_matcher: hcloud-linux-amd64.tar.gz
    post_process:
      - gunzip
      - name: tar
        asset_matcher: hcloud   # which file to take from the archive
      - make_exec
      - link

  - slug: cli/cli
    name: gh
    asset_matcher: gh_*_linux_amd64.deb
    post_process:
      - deb
```

### Managing the config from the command line

You can edit `ghri.yaml` by hand, or let `ghri.sh` do it:

```
$ ./ghri.sh add sharkdp/fd
Fetching the latest release of sharkdp/fd ...
Latest release: v10.5.0
      ...
    * 17) fd-v10.5.0-x86_64-unknown-linux-gnu.tar.gz
      ...
Which asset? (number, or a glob; * marks the suggestion) [17]:
asset_matcher (glob, or /regex/; the version is replaced by *) [fd-*-x86_64-unknown-linux-gnu.tar.gz]:
Command name (symlink in /home/me/bin) [fd]:
...
New package:
    slug: sharkdp/fd
    asset_matcher: fd-*-x86_64-unknown-linux-gnu.tar.gz
    post_process:
      - gunzip
      ...
Save to ghri.yaml? [y]es / [e]dit first / [n]o [y]:
Install fd now? [Y/n]
```

- **`add owner/repo`** (or any github.com URL, e.g. `https://github.com/owner/repo/releases`) looks at the latest release, suggests the Linux x86_64 asset, turns its version into `*`, proposes the right post-processors for the file type (`.deb`, `.tar.gz`, `.zip`, a bare binary, ...) and an optional `testrun`. You can edit the result in `$EDITOR` before it is saved, and install it straight away.
- **`edit NAME`** opens only that package's block (comments included) in `$VISUAL`/`$EDITOR`. The result is validated like `--check` does; if it is wrong you can edit again, and nothing is written until it is valid.
- **`delete NAME`** shows the block and asks before removing it. Installed files stay until you run `--prune`.

Name or slug both work for `edit` and `delete`. Changes are spliced into the file as text: comments, blank lines and commented-out packages elsewhere stay exactly as they were, and the previous version is kept as `ghri.yaml.bak`. These commands need an interactive terminal (`delete --yes` does not). Because the first word is a command, nothing is ever installed implicitly: a bare `./ghri.sh` shows the help, and packages are installed with `./ghri.sh install [NAMES...]` (which also works for packages called `add`, `edit` or `delete`).

### Package keys

| Key | Default | Meaning |
|---|---|---|
| `slug` | required | `owner/repo` |
| `name` | repo name | name of the symlink and of the command; must be unique |
| `asset_matcher` | `*` | glob, or `/regex/`, matched against the release's asset names; the first match wins |
| `post_process` | none | steps to run, see below |
| `auto_install` | `true` | `false`: skipped by `./ghri.sh install` without names, still installable by name |
| `prerelease` | global `prerelease`, else `false` | `true`: always take the newest release of any kind (pre-release or not); overrides the global default |
| `version` | latest | exact tag (`v1.2.3`), or a glob / `/regex/` such as `v1.*` for the newest matching release |
| `desc` | | free text |

### Post-processors

Steps run in order: `global_post_process.prepend`, the package's own list, then `global_post_process.append`. A step is a name, or a map with `name` plus optional `asset_matcher`, `args` and `quiet`.

| Step | What it does |
|---|---|
| `gunzip`, `bz2`, `xz` | decompress a single file |
| `tar`, `unzip` | extract an archive, then continue with the one file matching the step's `asset_matcher` |
| `make_exec` | `chmod 0755` |
| `link` | symlink the file as `symlink_path/<name>` |
| `testrun` | run the command with `args` (a string or a list); a non-zero exit fails the install. Prints the first output line unless `quiet: true` |
| `check_in_path` | fail unless `<name>` resolves via `PATH` |
| `deb` | `sudo dpkg -i`. If that fails, asks whether to run `sudo apt-get -f install -y` and retry |

## How an update works

1. Fetch the release metadata (cached, revalidated with ETags).
2. If the recorded version matches and the command still works, skip the package.
3. Download the asset to `<name>.part` and verify its sha256 (and the attestation for immutable releases). Only then does it get its final name.
4. Run the post-processors in `install_path/<owner>_<repo>/<tag>/`.
5. On success: record the version and delete the package's other version directories. On failure: restore the previous symlink; the old version and its record stay untouched.

`.deb` installs are system-wide and cannot be rolled back.

`--force` and `--no-cache` are independent: `--force` reinstalls a package that is already at the latest version it knows, `--no-cache` makes sure "the latest version" is looked up on GitHub right now (a release published in the last `cache_lifetime_sec` seconds is otherwise not seen). Use both to reinstall the very latest: `./ghri.sh install --force --no-cache NAME`.

## Using ghri in a Docker image (without curl or wget)

Every release is also published as a `FROM scratch` image that contains only `ghri.sh` (at `/ghri.sh`) and `ghri.example.yaml`. It cannot run by itself; it exists so that `COPY --from` can bring ghri into any image, without `curl`, `wget` or a download step:

```dockerfile
FROM debian:13

# ghri needs gh, yq and jq; all three are in Debian 13, apt needs no curl either
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates gh yq-go jq \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/schorsch3000/ghri:latest /ghri.sh /opt/ghri/ghri.sh
COPY ghri.yaml /opt/ghri/ghri.yaml
ENV PATH="/opt/ghri/bin:$PATH"

# GITHUB_TOKEN raises the API rate limit; pass it as a build secret, it is not stored in the image
RUN --mount=type=secret,id=github_token,env=GITHUB_TOKEN \
    /opt/ghri/ghri.sh install
```

`ghri.yaml` is found next to the script, so it goes into `/opt/ghri/`; the default `symlink_path` (`./bin`) then is `/opt/ghri/bin`, which the `ENV` line puts on `PATH`. Pin the image to a version (`ghcr.io/schorsch3000/ghri:0.1.0`) for reproducible builds. Add the tools of the post-processors you use (`unzip`, `xz-utils`, ...) to the `apt-get install` line; `./ghri.sh --check` lists what is missing.

## Keeping things clean

Removing a package from `ghri.yaml` does not delete anything. `./ghri.sh --prune` lists what is left over (install directories, version records, symlinks) and deletes it after confirmation. Packages installed with `deb` stay installed; remove them with `apt`.

## License

MIT, see `LICENSE`. Changes are listed in `CHANGELOG.md`.

## Development

```
make help                 # all targets
make test                 # unit and end-to-end tests (sandboxed, fake gh, no network, no sudo)
make test-integration     # real .deb install in a pty (needs sudo and network; cleans up after itself)
make test-live            # smoke test against the real GitHub API and gh (network; token recommended)
make lint                 # shellcheck
make fmt / make fmt-check # shfmt
make all                  # lint + fmt-check + test + config check (same as make ci)
```

The tests use [shpec](https://github.com/rylnd/shpec) (vendored as `./shpec`) and a fake `gh` in `test/fakes/gh`, so they never touch the network or your real installs. `CLAUDE.md` documents the architecture in more detail.

`Dockerfile.az` builds a Debian 13 image with everything above installed.
