# lcc

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16-orange.svg)](#build)

One command to go from "I should work on PE-N" to a clean git worktree with `.env` symlinks and Claude Code already running.

```
$ lcc
  PE-42   H   In Progress   Migrate notification scheduler off Redis
  PE-51       Todo          Add Liquid Glass to settings sheet
> PE-47   M   Todo          Backfill missing receipt categories
  feature/pe-47-backfill-receipts — https://linear.app/…/PE-47/…
  3/165 · ↑↓ move · enter select · esc cancel
✓ Worktree created: /Users/me/Documents/Projects/Pantry/.lcc/worktrees/PE-47-backfill-receipts
✓ Linked .env
✓ Linked .env.local
[claude opens in worktree]
```

A single ~1.5 MB binary with no runtime. It shells out to `git`, `claude`, `open`, `du`, `defaults` and `plutil` — everything else is the Zig standard library plus macOS's own Security framework.

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
lcc setup            # configure startTaskCommand, worktreeTemplate, activeStates
lcc list             # list all worktrees
lcc open             # pick a worktree and resume Claude in it (--no-resume for fresh)
lcc open xcode       # pick a worktree and open it in Xcode instead
lcc remove           # pick a worktree, remove it + its branch + Xcode build data
lcc clean            # reclaim build data left by worktrees that no longer exist
lcc auth             # log in
lcc auth --status    # who am I, when does the token expire
lcc auth --logout    # clear the token from the Keychain
```

`ls`, `o` and `rm` are accepted as aliases for `list`, `open` and `remove`.

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

## Xcode build data

A worktree that gets built in Xcode leaves a DerivedData folder behind, and removing the worktree does not remove it. `lcc remove` matches folders to the worktree by the `WorkspacePath` recorded in each `info.plist`, shows their size in the confirmation, and deletes them along with the worktree. `--keep-derived-data` skips that.

`lcc clean` handles the backlog: every DerivedData folder whose project no longer exists on disk, sorted biggest first, with a checkbox list so you choose what goes. Folders without an `info.plist` — Xcode's own shared caches — are never touched, and deletion refuses any path that is not a direct child of the DerivedData root.

Set `LCC_DERIVED_DATA` to override the location; otherwise `lcc` honours Xcode's own `IDECustomDerivedDataLocation` when it is absolute.

## Configuration

`~/.config/lcc/config.json`, written by `lcc setup`:

| Key | Default | Meaning |
|---|---|---|
| `worktreeTemplate` | `{repoRoot}/.lcc/worktrees/{branchLeaf}` | Where worktrees go. Placeholders: `{repoRoot}`, `{repoParent}`, `{repoName}`, `{branch}`, `{branchLeaf}` |
| `activeStates` | `["Todo", "In Progress"]` | Which Linear states to offer, in this order |
| `startTaskCommand` | `""` | Passed to `claude` as its first argument. Placeholders: `{identifier}`, `{branch}`, `{url}` |
| `envPatterns` | `[".env", ".env.*"]` | Which root files to symlink into the worktree |
| `envExclude` | `[".env.example", ".env.sample", ".env.template"]` | Which of those to skip |
| `clientId` | built-in | Linear OAuth application. Override with `LCC_CLIENT_ID` or `lcc auth setup --client-id <id>` |

`{repoRoot}` and `{repoParent}` always resolve against the **main** worktree, so running `lcc` from inside a worktree puts the next one beside its siblings instead of nesting it one level deeper.

A worktree nested inside the repo is added to `.git/info/exclude`, so it never shows up as untracked.

## Layout

```
build.zig             build, run and test steps
src/main.zig          argv parsing and dispatch
src/commands/         one file per command
src/linear.zig        GraphQL over std.http.Client
src/oauth.zig         PKCE, callback listener, token refresh
src/keychain.zig      Security.framework SecItem*
src/prompt.zig        raw-mode search, confirm, checkbox, input
src/git.zig           worktrees, branches, branch disposition
src/fold.zig          case folding for ASCII, Latin-1, Cyrillic
src/derived_data.zig  DerivedData discovery and reclamation
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
