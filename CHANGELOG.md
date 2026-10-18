# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-10-18

First release.

### Added
- `ghri.sh install [NAMES...]`: download the latest release of the packages in `ghri.yaml`,
  verify it, run the post-processors and symlink the result. Nothing is installed without
  the `install` command.
- Verification of every download: sha256 against the digest GitHub records, plus the signed
  release attestation for immutable releases.
- Safe updates: the previous symlink is restored when an update fails or is interrupted;
  old versions are removed only after a successful update.
- Skipping of packages that are already current, `--force` to reinstall.
- `--outdated` (aliases `--list`, `--dry-run`) with `--json` and `--quiet`; exit code 10 when
  something is not current.
- `--check` and a pre-flight check of the config and of every external command.
- `--prune` to remove files of packages that left the config.
- `add` (interactive wizard), `edit` and `delete` commands that change `ghri.yaml` as text and
  keep a `.bak`.
- Version pinning by exact tag or by pattern (`v1.*`, `/regex/`).
- Post-processors: `gunzip`, `bz2`, `xz`, `tar`, `unzip`, `make_exec`, `link`, `testrun`,
  `check_in_path`, `deb`.
- API access through `gh`, with caching and ETag revalidation, per-call time limits
  (`timeout_sec`, `download_timeout_sec`) and a lock against concurrent runs.
- Shell completion for bash, zsh and fish (`ghri completion <shell>`).
- `ghri.example.yaml`, MIT license, `make` targets for tests, lint and format, a fake `gh` for
  offline tests and an opt-in live smoke test.

### Notes
- Linux only (GNU tools are assumed).
- Installed versions are recorded in `state_path` (default `./.state`). Records from older
  development versions in `cache_path` are migrated automatically.
