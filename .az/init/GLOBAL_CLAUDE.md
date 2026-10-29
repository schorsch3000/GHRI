# Environment

You run inside an isolated, disposable dev container. Nothing here
is precious: the container is rebuilt from a Dockerfile regularly.

## What this means

- You are a non-root user without sudo. You cannot install system packages yourself.
- Network egress is restricted to an allowlist (package registries, git host,
  model API). A blocked connection is expected policy, not a bug. Do not try to bypass it.
  If you feel you need it: ask the human to add it to the allowlist, and explain why.
- Only the workspace directory (your cwd) persists. Anything else may vanish.
- No host secrets are available. Do not search for credentials.


## Working style
- Run tests and linters yourself before declaring work done.
- Commit to a feature branch; never push to main/master, whatever it is.

## stray files
- `.az/` contains the files that build the container and configure the agent.
- `Dockerfile.az`, `Dockerfile.az.dockerignore` and `aicatraz.yaml` also configuring your container.

ignore them!



## Task tracking with git-bug

Tasks for this project are tracked with git-bug, stored inside the git repo. You can use it to create, list, comment, and close tasks.

Only applicable if there is a .git directory.


### Identity for `git bug`
You act as "Bender Bending Rodríguez" <bender@shnbk.de>.
Never create other identities and never
use the human's identity.

The identity ony applies to git-bug, not to git commits. Use the configured git identity.

### Workflow
- if `git bug` with any subcommand hangs for more than 2 seconds scream at the human to close the UI.
  - using `timeout 2` for this will not work, you need `timeout -s9 2` for this to actually come back.
  - if you need stream, please try to use notifications.
- Before starting, check existing work: `git bug bug status:open`
  (full text search: `git bug bug "some words"`).
- Create a task for anything non-trivial:
  `git bug bug new --non-interactive -t "Short title" -m "What and why, acceptance criteria"`
- Always pass `--non-interactive` and `-m`/`-t`, or `-F -` to read from stdin.
  Never run commands that open an editor, `termui` or `webui`: you cannot use them.
- Bug IDs: use the short human ID from `git bug bug -f plain` (e.g. `0105a13`).
- Progress notes and decisions: `git bug bug comment new <ID> --non-interactive -m "..."`
- Labels for state: `git bug bug label new <ID> status:in-progress`
- Labels for types: `git bug bug label new <ID> type:research` (or `type:bug`, `type:feature`, `type:task`).
  (remove with `label rm`). Use `status:todo`, `status:in-progress`, `status:blocked`.
- Done: comment with a short result (commit hash), then `git bug bug status closed <ID> --non-interactive -m "Done, see commit <hash>"`.
- Reference the bug ID in commit messages, e.g. `Fix parser crash (git-bug 0105a13)`.
- Rename: `git bug bug title edit <ID> -t "New title"`.
- Machine-readable output: `-f json` (list, show) or `-f id`.

Attention: one thing about `git but`: you cant create a Ticket in an empty repo, there MUST be a commit prior. 

### Rules
- Do not delete bugs (`bug rm`) unless asked.
- Do not run `git bug push`/`pull` or configure bridges unless asked. Sync
  to a remote is the human's decision.
- If a command fails, run `git bug <command> --help`
- Keep tasks small and concrete; one task per unit of work.
- Syncing is deliberately off by default. Only `git bug push`/`pull` to a remote if the human asks you to.

## Tools

### Actions

If you need a tool that is missing (compiler, CLI, language or need some host on the allow list), ask me. Say:
1. what you need and why,
2. the exact installation command or Debian package name if you know
3. what you tried instead.
   Don't work around a missing tool with fragile hacks. Asking is faster and safer.

User-space installs inside the workspace are fine without asking, eg. `uv venv`, `uv pip install`, `npm install` (project-local) `composer install` (project-local). Don't install system packages.



### Already installed