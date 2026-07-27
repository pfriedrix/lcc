# lcc

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16-orange.svg)](#build)

One command to go from "I should work on PE-N" to a clean git worktree with your gitignored files symlinked in and Claude Code already running.

```
$ lcc
  PE-42   H   In Progress   Migrate notification scheduler off Redis
  PE-51       Todo          Add Liquid Glass to settings sheet
> PE-47   M   Todo          Backfill missing receipt categories
  feature/pe-47-backfill-receipts — https://linear.app/…/PE-47/…
  3/165 · ↑↓ move · enter select · esc cancel
✓ Worktree created: /Users/me/Documents/Projects/Pantry/.lcc/worktrees/PE-47-backfill-receipts
✓ Linked .claude/settings.local.json
✓ Linked .env
✓ Linked .env.local
[claude opens in worktree]
```

A single ~1.5 MB binary with no runtime. It shells out to `git`, `claude`, `gh`, `open`, `du`, `defaults` and `plutil` — everything else is the Zig standard library plus macOS's own Security framework.

## Build

Requires [Zig 0.16](https://ziglang.org/download/) and macOS.

```bash
git clone https://github.com/pfriedrix/lcc ~/Documents/Projects/lcc
cd ~/Documents/Projects/lcc
zig build -Doptimize=ReleaseFast
ln -sf "$PWD/zig-out/bin/lcc" /opt/homebrew/bin/lcc
```

```bash
zig build test           # unit tests
zig build run -- list    # run without installing
```

Editing anything under `src/` changes nothing on your `PATH` until you re-run `zig build -Doptimize=ReleaseFast`. A plain `zig build` installs a debug binary to the same path — slower, and noisier on unexpected errors.

`.github/workflows/ci.yml` runs both of those on every pull request into `master` and is a required status check, so a red suite blocks the merge button. It pins the Zig version and the runner image on purpose — the gate should only ever go red because of a change in this repo, never because a toolchain or runner image rolled forward underneath it. Both pins are one-line bumps.

## Authenticate

```bash
lcc auth
# Browser opens → click Authorize → done.
```

`lcc` uses OAuth 2.0 with PKCE — like `gh auth login`. No API keys pasted into the terminal, no shell history secrets. The token is stored in the macOS Keychain and refreshed automatically when it expires. The callback listener gives up after five minutes if you never finish in the browser.

For headless machines, `lcc auth --token <pat>` stores a Linear personal API token instead.

## Usage

```bash
lcc                  # pick an issue, bootstrap worktree, launch Claude
lcc --all            # ignore the activeStates filter
lcc setup            # configure startTaskCommand, worktreeTemplate, activeStates, linkPatterns
lcc list             # dashboard of every worktree (--local to skip the network columns)
lcc open             # pick a worktree and resume Claude in it (--no-resume for fresh)
lcc open xcode       # pick a worktree and open it in Xcode instead
lcc remove           # pick a worktree, remove it + its branch + Xcode build data
lcc remove --merged  # bulk: every worktree and branch whose work already landed
lcc clean            # reclaim build data and transcripts left by worktrees that are gone
lcc auth             # log in
lcc auth --status    # who am I, when does the token expire
lcc auth --logout    # clear the token from the Keychain
```

`ls`, `o` and `rm` are accepted as aliases for `list`, `open` and `remove`.

### The dashboard

`lcc list` is the "what am I in the middle of" view — one row per worktree:

```
$ lcc list
BRANCH                   STATUS   SYNC   AGE  PR          LINEAR       PATH
feature/pe-256-app-hangs 3 dirty  ↑2 ↓0  2h   #412 open   In Progress  ~/…/pe-256-app-hangs
feature/pe-247-exc-bad   clean    ↑0 ↓14 6d   #398 merged In Build     ~/…/pe-247-exc-bad
feature/pe-224-history   clean    gone   11d  —           In Review    ~/…/pe-224-history
```

| Column | Where it comes from |
|---|---|
| `STATUS` | `git status --porcelain` in the worktree — entry count, or `missing` when the directory is gone |
| `SYNC` | `%(upstream:track)` — `↑ahead ↓behind`, `unpushed` with no upstream, `gone` once the remote branch is deleted |
| `AGE` | how long ago the branch tip was committed |
| `PR` | `gh pr list` for the repo, matched on head branch; open beats merged beats closed |
| `LINEAR` | the state of the issue the branch names, e.g. `PE-256` out of `feature/pe-256-…` |

Everything local is two `git` calls plus one `git status` per worktree — about 0.2s on a large iOS repo with five worktrees. `PR` and `LINEAR` are one batched request each and are the whole rest of the cost: roughly 1.9s in total, more on the first call of the day while Linear warms up. `--local` drops both columns, as does a missing `gh` or an expired Linear token — those print a hint and leave the rest of the table intact.

### Picking

Type to filter. Every whitespace-separated word has to appear somewhere in the row — identifier, title, branch, state, assignee or team — and matching is case-insensitive across Latin and Cyrillic alike.

Results are ordered by *where* the match landed: the start of the identifier ranks above the start of a word, which ranks above something buried mid-word. Typing `log` therefore surfaces `logout()` and `logAllValues()` ahead of issues that merely sit in `Backlog`. Rows scoring the same keep their original order — your `activeStates` order first, most recently updated first within each state.

`↑`/`↓` move, `enter` selects, `esc` or `Ctrl-C` cancels with exit code 130.

### `lcc open xcode`

Uses the same worktree picker, then launches Xcode instead of Claude. It looks for the shallowest `.xcworkspace`, `.xcodeproj`, or `Package.swift` in the worktree (workspace > project > package when several sit at the same depth) and opens it with `open -a Xcode`.

## Branch cleanup

`lcc remove` deletes the branch along with the worktree — but only when the commits survive somewhere else. Two things count as safe:

- The branch is an ancestor of the default branch (an ordinary merge).
- The branch was pushed and its upstream is now `[gone]` — what a squash-merged PR looks like locally, where ancestry can never prove the commits survived.

Anything else is kept, and `lcc` reports how many unmerged commits it found and prints the `git branch -D` you would need. `--keep-branch` skips the check entirely.

`lcc remove --merged` runs that check across the whole repo and offers everything that passes in one checkbox list — including branches that outlived their worktree, which nothing else ever cleans up:

```
$ lcc remove --merged
? Select what to remove (space toggles, enter confirms):
❯ ◉ feature/pe-101-shipped  merged       2.4 GB   ~/…/.lcc/worktrees/pe-101-shipped
  ◉ feature/pe-103-squashed remote gone  —        branch only — no worktree left
  3/3 selected · space toggles · enter confirms · esc cancel
```

A branch checked out anywhere — including the main worktree — is never offered, and a worktree with uncommitted changes is reported and skipped rather than forced. `-y` takes everything without asking; `--force`, `--keep-branch` and `--keep-derived-data` mean the same as they do for a single removal.

## Xcode build data

A worktree that gets built in Xcode leaves a DerivedData folder behind, and removing the worktree does not remove it. `lcc remove` matches folders to the worktree by the `WorkspacePath` recorded in each `info.plist`, shows their size in the confirmation, and deletes them along with the worktree. `--keep-derived-data` skips that.

Folders without an `info.plist` — Xcode's own shared caches — are never touched, and deletion refuses any path that is not a direct child of the DerivedData root.

Set `LCC_DERIVED_DATA` to override the location; otherwise `lcc` honours Xcode's own `IDECustomDerivedDataLocation` when it is absolute.

## Claude Code session transcripts

`~/.claude/projects` grows a directory per working directory Claude Code was launched in, and worktrees make a lot of those — a few hundred MB of transcripts for worktrees deleted months ago is normal.

Claude Code names each directory after a flattened cwd, and that flattening is lossy: `/` and `.` both become `-`, so the original path cannot be recovered from the name. `lcc` reads the `cwd` field out of a transcript instead, which records the real path. A directory whose transcripts never name one is left out entirely — `lcc` cannot tell whether its worktree still exists, so it never offers to delete it.

Transcripts are treated as more valuable than build data, because they are: a DerivedData folder comes back on the next build and a transcript is what `claude --resume` replays. So `lcc remove` **lists** the matching folders in its confirmation and keeps them; `--sessions` is what actually deletes them.

Set `LCC_CLAUDE_PROJECTS` to override the location.

## `lcc clean`

The backlog of both: every DerivedData folder and every session directory whose worktree no longer exists on disk, biggest first, in one checkbox list.

```
$ lcc clean
› Measuring 31 orphaned folders…
14 GB in 31 folders whose worktree no longer exists.
Session transcripts are what `claude --resume` replays — check before deleting.
? Select what to delete (space toggles, enter confirms):
❯ ◉  2.4 GB  build data  LocationTracker-fmqzbi…  ~/…/pe-224-history-empty-states
  ◉   12 MB  sessions    -Users-…-pe-224-history  ~/…/pe-224-history-empty-states
```

`--build-data` and `--sessions` narrow it to one category; `-y` takes everything without asking.

## Configuration

`~/.config/lcc/config.json`, written by `lcc setup`:

| Key | Default | Meaning |
|---|---|---|
| `worktreeTemplate` | `{repoRoot}/.lcc/worktrees/{branchLeaf}` | Where worktrees go. Placeholders: `{repoRoot}`, `{repoParent}`, `{repoName}`, `{branch}`, `{branchLeaf}` |
| `activeStates` | `["Todo", "In Progress"]` | Which Linear states to offer, in this order |
| `startTaskCommand` | `""` | Passed to `claude` as its first argument. Placeholders: `{identifier}`, `{branch}`, `{url}` |
| `linkPatterns` | `[".env", ".env.*", ".claude/settings.local.json"]` | Which files to symlink into each worktree |
| `linkExclude` | `[".env.example", ".env.sample", ".env.template"]` | Which of those to skip |
| `clientId` | built-in | Linear OAuth application. Override with `LCC_CLIENT_ID` or `lcc auth setup --client-id <id>` |

A worktree nested inside the repo is added to `.git/info/exclude`, so it never shows up as untracked.

### Link patterns

A pattern is a path relative to the repo root whose every segment may glob, so it reaches things that do not sit at the top level:

| Pattern | Matches |
|---|---|
| `.env` | a root-level `.env`, and nothing in a subdirectory |
| `.env.*` | `.env.local`, `.env.production` |
| `.claude/settings.local.json` | exactly that file |
| `*/credentials.plist` | `Config/credentials.plist`, but not `a/b/credentials.plist` |

`*` and `?` never cross a `/`, so a pattern only ever opens the directories it names — nothing walks the repository. Missing parent directories are created in the worktree, an existing entry of any kind is left alone (the worktree's own file wins), and a pattern that is absolute or contains `..` is skipped rather than clamped.

`.claude/settings.local.json` is in the defaults because it holds the permission allowlist: without it, every new worktree re-asks for approvals already granted in the main checkout. Linking it means one allowlist shared by every worktree.

`envPatterns` and `envExclude` are the pre-nested-path names for these two keys. An existing config keeps working; `linkPatterns`/`linkExclude` win when both are present, and `lcc setup` rewrites the old key to the new one.

## Layout

```
build.zig                build, run and test steps
src/main.zig             argv parsing and dispatch
src/commands/            one file per command
src/linear.zig           GraphQL over std.http.Client
src/oauth.zig            PKCE, callback listener, token refresh
src/keychain.zig         Security.framework SecItem*
src/github.zig           pull-request state via the `gh` CLI
src/prompt.zig           raw-mode search, confirm, checkbox, input
src/git.zig              worktrees, branches, branch disposition, drift
src/fold.zig             case folding for ASCII, Latin-1, Cyrillic
src/link.zig             pattern matching and symlinking into a worktree
src/disk.zig             path containment and batched `du`
src/derived_data.zig     DerivedData discovery and reclamation
src/claude_projects.zig  ~/.claude/projects discovery and reclamation
```

`src/keychain.zig` deliberately `@cImport`s five narrow CoreFoundation/Security headers rather than the umbrella ones: on the macOS 26.5 SDK, `CoreFoundation/CoreFoundation.h` drags in mach headers whose bitfield structs translate-c turns opaque (tripping their own `_Static_assert`s), and `Security/Security.h` drags in `xpc.h`, which puts nullability attributes on the non-pointer `uuid_t`.

## Scope

macOS only. The Keychain layer talks to Security.framework directly, so Linux (libsecret) and Windows (Credential Manager) would each need their own backend.

Pinned to Zig 0.16. That release moved `std.fs.File` to `std.Io.File`, threads an `Io` parameter through every I/O call, and changed the `main` signature — expect edits on the next Zig release.

Case folding covers ASCII, Latin-1 Supplement and Cyrillic. Latin Extended-A is left out on purpose: its case pairs are irregular and some foldings are multi-codepoint, so covering it half-correctly would be worse than not covering it.

## History

Everything up to 0.1.0 was TypeScript on Node, built on `@linear/sdk`, `@inquirer/prompts`, `@napi-rs/keyring`, `commander`, `execa`, `open` and `picocolors`. It was replaced wholesale by this implementation after a command-by-command parity check, then deleted. `git log` still has it.

## License

MIT
