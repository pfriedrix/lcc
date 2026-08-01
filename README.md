# lcc

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/zig-0.16-orange.svg)](#build)

One command to go from "I should work on PE-N" to a clean git worktree with your gitignored files symlinked in and Claude Code already running.

```
$ lcc start
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
lcc                  # print the command list
lcc start            # pick an issue, bootstrap worktree, launch Claude
lcc start PE-256     # that issue, no picker
lcc start PE-256 --json   # resolve it and print the result instead of launching Claude
lcc start --all      # ignore the activeStates filter
lcc setup            # configure startTaskCommand, worktreeTemplate, activeStates, linkPatterns
lcc list             # dashboard of every worktree (--local to skip the network columns)
lcc stats            # what each worktree has spent on Claude Code (--models for the breakdown)
lcc open             # pick a worktree and resume Claude in it, if it has sessions (--no-resume for fresh)
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
BRANCH                   STATUS   SYNC   AGE  TOKENS  PR          LINEAR       PATH
feature/pe-256-app-hangs 3 dirty  ↑2 ↓0  2h   53M     #412 open   In Progress  ~/…/pe-256-app-hangs
feature/pe-247-exc-bad   clean    ↑0 ↓14 6d   8.0M    #398 merged In Build     ~/…/pe-247-exc-bad
feature/pe-224-history   clean    gone   11d  —       —           In Review    ~/…/pe-224-history
```

| Column | Where it comes from |
|---|---|
| `STATUS` | `git status --porcelain` in the worktree — entry count, or `missing` when the directory is gone |
| `SYNC` | `%(upstream:track)` — `↑ahead ↓behind`, `unpushed` with no upstream, `gone` once the remote branch is deleted |
| `AGE` | how long ago the branch tip was committed |
| `TOKENS` | context tokens the worktree's Claude Code sessions have read — see [token usage](#token-usage) |
| `PR` | `gh pr list` for the repo, matched on head branch; open beats merged beats closed |
| `LINEAR` | the state of the issue the branch names, e.g. `PE-256` out of `feature/pe-256-…` |

Everything local is two `git` calls plus one `git status` per worktree — about 0.2s on a large iOS repo with five worktrees. `PR` and `LINEAR` are one batched request each and are the whole rest of the cost: roughly 1.9s in total, more on the first call of the day while Linear warms up. `--local` drops both columns, as does a missing `gh` or an expired Linear token — those print a hint and leave the rest of the table intact. `--no-tokens` drops the transcript read behind `TOKENS`.

### Picking

Type to filter. Every whitespace-separated word has to appear somewhere in the row — identifier, title, branch, state, assignee or team — and matching is case-insensitive across Latin and Cyrillic alike.

Results are ordered by *where* the match landed: the start of the identifier ranks above the start of a word, which ranks above something buried mid-word. Typing `log` therefore surfaces `logout()` and `logAllValues()` ahead of issues that merely sit in `Backlog`. Rows scoring the same keep their original order — your `activeStates` order first, most recently updated first within each state.

`↑`/`↓` move, `enter` selects, `esc` or `Ctrl-C` cancels with exit code 130.

### Naming the issue

`lcc start PE-256` skips the picker. The issue is fetched by identifier rather than filtered out of your assigned list, so `activeStates` and the assignee do not apply — naming an issue is a more specific answer than either. `--base <ref>` cuts a new branch from `<ref>` instead of asking.

### Which repository

An identifier names work without naming a checkout, and nothing in Linear closes that gap: the team is one team, the project is a release, and `branchName` is derived from the title. Answering it with the current directory alone is right until you are standing somewhere else — and then lcc cuts a branch and builds a worktree that look entirely correct in a repo that has nothing to do with the issue, which is noticed only once the first file is nowhere to be found.

So the question is answered in order of how much each answer can be trusted:

| | |
|---|---|
| `--repo <path>` | said outright, and nothing else is consulted |
| what lcc remembers | the answer this issue got last time, which is why `lcc start PE-256` works from any directory at all — including one that is not a repository |
| where the work already is | a branch for `PE-256` in a repository lcc knows *is* the answer: that is where the commits are |
| the question | a picker over the repositories lcc knows, plus the ones sitting beside the current checkout, so the first run has something to offer instead of demanding a path |

Never a guess from the issue text. The words in a title are exactly the words that turn up in unrelated repositories — this repo's own README mentions `logAllValues`, which is enough to attract an issue that belongs to an iOS app.

Answers are kept in `~/.config/lcc/repos.json` (override with `LCC_REPOS`) and written once a worktree exists, so the picker appears once per issue and never again. `lcc start --json` never falls back to the current directory: with nothing remembered and no branch anywhere, it fails with `repo_unconfirmed` rather than creating a worktree somewhere plausible.

Work the issue already has is reused rather than duplicated, at two levels. A worktree is found by exact branch name first, then by the `PE-N` in it; failing that, a *branch* carrying the same `PE-N` under an older name is checked out instead of a second one being cut beside it — Linear changes what it suggests when an issue is renamed, while the commits stay where they were. Both reuses are reported (`matched_by`, `renamed`, `created: reused_local`), and the most recently committed branch wins when a rename happened more than once.

Running `lcc start PE-256` twice therefore opens the same worktree twice, whatever the template or the title has done since.

### `lcc start --json`

Machine mode, for a caller that is already inside Claude Code — a `/start-task` slash command that owns the issue tracker can use it instead of probing git for the branch and the worktree itself. It requires an identifier, asks nothing (a new branch comes off `--base` or the default branch), and does not launch Claude Code, so it is safe to call from inside a session lcc itself started.

```bash
$ lcc start PE-256 --json
{
  "issue":     { "id": "…", "identifier": "PE-256", "title": "…", "url": "…",
                 "state": "In Review", "state_type": "started", "team": "PE", "assignee": "…" },
  "branch":    { "name": "feature/pe-256-…", "suggested": "feature/pe-256-…", "renamed": false,
                 "upstream": "origin/feature/…", "pushed": true,
                 "ahead": 0, "behind": 0, "current": true },
  "worktree":  { "path": "/Users/me/…/App.worktrees/pe-256-…", "status": "existing",
                 "matched_by": "branch", "created": null, "base": null,
                 "is_main_checkout": false, "is_cwd": true },
  "repo":      { "root": "/Users/me/…/App", "default_branch": "main" },
  "links":     { "linked": [".env"], "skipped": [".claude/settings.local.json"] },
  "start_task_command": "/start-task PE-256",
  "mcp":       { "config": "/Users/me/.config/lcc/mcp/-Users-me-Projects-App.json",
                 "servers": ["linear-server", "xcode"] }
}
```

Every key is always present; absent values are `null`, never dropped.

| Field | Meaning |
|---|---|
| `branch.name` | the branch to use — the one with the commits |
| `branch.suggested` / `renamed` | what Linear's `branchName` implies today, and whether it has drifted from `name` |
| `branch.pushed` / `upstream` | false until the branch has an upstream; while it is, Linear's GitHub integration cannot see the branch and will not auto-transition the issue |
| `worktree.status` | `created` or `existing` |
| `worktree.matched_by` | how an existing worktree was recognised — `branch` (exact name) or `issue` (the `PE-N` matched, i.e. the issue was renamed). `null` for one this run created |
| `worktree.is_cwd` | whether this very process is standing in it, which is what tells a caller there is nothing left to open |
| `worktree.created` / `base` | the strategy (`new`, `reused_local`, `tracking_remote`) and what a new branch was cut from; `null` when the worktree already existed |
| `mcp` | the local-scope MCP servers a session launched through lcc would get, and the file passed as `--mcp-config`; `null` when there are none to carry, including when `mcpCarry` filters them all. A caller that is already running cannot be handed servers retroactively — this is here so it can tell whether a missing server is one lcc would have supplied |

Failures come back in the same shape, on stdout, with exit code 1:

```json
{ "error": { "code": "issue_not_found", "message": "No issue PE-999 in Linear." } }
```

Codes: `usage`, `not_authenticated`, `auth_failed`, `bad_identifier`, `issue_not_found`, `linear_failed`, `worktree_path_exists`, `git_failed`, `bad_repo`, `repo_unconfirmed` — the last one is the picker above in a mode with nobody to ask: pass `--repo <path>`, or run it once interactively and the answer is remembered. Progress lines and the human-readable error go to stderr, so stdout holds nothing but the payload — including git's own output, which is captured rather than inherited in this mode.

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
❯ ◉ feature/pe-101-shipped  merged       2.4 GB   53M      ~/…/.lcc/worktrees/pe-101-shipped
  ◉ feature/pe-103-squashed remote gone  —        —        branch only — no worktree left
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

## Token usage

Those transcripts record what every assistant message cost — the `usage` block the API returned, plus the model that produced it. Since a project directory is keyed on the cwd Claude Code ran in, and lcc already maps directories to worktrees by the `cwd` a transcript records, the same data answers "what has this task spent".

It shows up wherever you touch a worktree, not only when you ask:

```
$ lcc open
› Launching Claude Code in ~/…/pe-47-backfill-receipts feature/pe-47-backfill-receipts
  Spent here: 3.6M context · 18k output · 2 sessions · 36m ago · ~$2.54
```

`lcc list` carries it as a column, `lcc start` prints it when the worktree already exists, and both removal paths show it — the single confirmation as a line, `--merged` as a column next to the reclaimable bytes. A transcript's size on disk says nothing about the work it holds, and `--sessions` deletes it for good.

`lcc stats` is the detailed view, with `--models` for the breakdown that explains the money:

```
$ lcc stats --models
WORKTREE                         SESS  MSGS  CONTEXT  OUTPUT  ~USD    ACTIVE  LAST  ORIGIN
feature/pe-47-backfill-receipts  2     6     3.6M     18k     2.54    12m     36m
  opus-5                               5     3.6M     17k     2.54
  haiku-4-5                            1     50       900     0.00
main                             17    1198  257M     1.0M    180.14  9h35m   now   main
feature/pe-51-liquid-glass       —     —     —        —       —       —       —     lcc
TOTAL                            19    1204  261M     1.0M    182.68  9h47m
```

`ACTIVE` is how long the work actually took, which is not how long the task has been open. Messages less than 15 minutes apart are one stretch of work and the gap between them counts — that gap is thinking, tool calls, and reading the answer. A longer gap is a break and contributes nothing. The two answers are not close: measured on this repo's own branch, 13.8 days elapsed and 9h35m of it was worked.

It undercounts, deliberately. The first message of a stretch is credited with nothing, because whatever went into asking for it happened before the transcript recorded anything, and a session of one message reads as `0m`. A number meant to be weighed against a working day is more useful as a floor than as a flattering estimate. The threshold is `idle_gap_seconds` in `src/usage.zig`, and `--json` reports it alongside the counts so the numbers stay interpretable.

The gaps are measured across the worktree's whole message stream rather than per transcript, because a subagent runs *alongside* the conversation that spawned it. Summing each transcript's own stretches would bill the same wall clock once per agent, so a pipeline running five of them in parallel could report several times the time it actually took. Merged and sorted first, the stretches cannot add up to more than the span they happened in.

`ORIGIN` says where a worktree came from — `main` for the checkout itself, `lcc` for one lcc created under the configured prefix, blank for one made by hand somewhere else. The column is only drawn when there is something to put in it.

`--json` prints the same numbers with the cache split intact, for anything that wants to keep its own history.

**`CONTEXT` is the number that matters.** It counts fresh input plus cache writes and cache reads, and on a long session the cache reads dominate everything else by two orders of magnitude — the 3.6M above is 3.6M of re-read conversation against 103 tokens of genuinely new input. Output is shown separately because it is priced five times higher per token.

**Subagents are counted.** They do not write into the conversation that spawned them — each gets its own transcript under `<session-id>/subagents/` — so the top level of a project directory holds only part of what a task cost. On a worktree driven through a pipeline that is usually the smaller part: 51M context in the parent against 95M across its subagents is a normal split. The whole directory tree is walked for `.jsonl`, and everything else Claude Code keeps down there (`tool-results/`, the per-subagent `.json` sidecars) carries no usage and is skipped. `SESS` still counts conversations, not subagents — a subagent is part of the sitting, not another one.

Two things keep the counts honest. Messages are counted once by `message.id`, because a resumed session copies history forward and compaction rewrites it, so the same API response appears in several lines and often several transcripts. And each line is parsed as JSON rather than scanned for `"output_tokens"` — a message whose own text quotes a usage block would otherwise inflate its own session, which is exactly what a transcript of a session about token counts does.

`~USD` is Anthropic **list price**, applied per model, with cache writes at 1.25× input (2× for the hour-long TTL) and cache reads at 0.1×. It is not what a Claude subscription bills — it is what the same tokens would have cost through the API. The table lives in one place, `prices` in `src/usage.zig`; a model that is not in it still has its tokens counted, and the total it is missing from is marked with a trailing `+`.

The attribution is per worktree, which means per task only as long as the task has its own worktree. Work done in the main checkout lands in one bucket no matter which branch was checked out at the time, because Claude Code keys the directory on the cwd and not on git state.

### Why it is not slow

Counting means parsing every line of every transcript, and the pile only grows — Claude Code appends and never prunes. A repo worked in daily reaches hundreds of MB, and re-reading all of it to redraw a table costs about 0.6s.

Almost none of it changed since the last run, so almost none of it is read again. Each transcript is reduced to the assistant messages that carried usage — two orders of magnitude smaller — and that is kept in `~/.cache/lcc/usage.json`, reused whenever the file's size and mtime both still match. Append-only means either one moving is enough to notice. In practice one session is live and everything else is frozen:

```
cold (cache deleted)   0.64s
warm                   0.05s      1.7MB of cache for 1.3B tokens across 45 project directories
```

Nothing derived is stored. Cost is recomputed from the token counts on every read, so correcting `prices` takes effect at once instead of being frozen into a file nobody would think to delete. Deduplication is not stored either: a cache entry is deduplicated against its own transcript only, which keeps it a pure function of that file, and the cross-file pass stays with the scanner — the only thing that knows which transcripts a given question spans. A cached run and a cold run produce identical output, which is what the tests assert.

The cache lives under `~/.cache`, not `~/.config/lcc` like the rest of lcc's state, because it is regenerable and large enough to matter — config directories end up in dotfile repos. `LCC_USAGE_CACHE` overrides the location; deleting the file costs one slow run. `lcc list --no-tokens` skips the whole thing.

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
| `linkPatterns` | `[".env", ".env.*", "CLAUDE.md", "CLAUDE.local.md", ".claude/settings.local.json"]` | Which files to symlink into each worktree |
| `linkExclude` | `[".env.example", ".env.sample", ".env.template"]` | Which of those to skip |
| `mcpCarry` | absent — all of them | Which local-scope MCP servers to carry; setup accepts a comma-separated list, `all`, or `none` |
| `clientId` | built-in | Linear OAuth application. Override with `LCC_CLIENT_ID` or `lcc auth setup --client-id <id>` |

`{repoRoot}` and `{repoParent}` always resolve against the **main** worktree, so running `lcc` from inside a worktree puts the next one beside its siblings instead of nesting it one level deeper.

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

`CLAUDE.md` and `CLAUDE.local.md` are there for the repos that keep theirs out of git — a worktree of one hands Claude Code no project instructions at all, which is the same session in a repo it knows nothing about. Claude Code walks up the parent directories looking for both, so a worktree **nested** inside the repo (the default template) finds them without any help; the link is what covers a template that puts worktrees *beside* the repo. A repo that commits its `CLAUDE.md` is unaffected either way: the file is already in the worktree, and linking never replaces one that is there — `lcc` reports it as skipped and moves on.

`envPatterns` and `envExclude` are the pre-nested-path names for these two keys. An existing config keeps working; `linkPatterns`/`linkExclude` win when both are present, and `lcc setup` rewrites the old key to the new one.

### Code signing and the Keychain

The Linear token lives in the login Keychain (`generic password`, service `lcc`, account `linear-token`), and the Keychain decides who may read it from the program's **code signature** — not its path. Zig's linker only ad-hoc signs, and an ad-hoc signature carries no identity beyond the hash of the binary itself, so every rebuild arrives as a *changed* program: macOS then asks for the login password and the process blocks, with no output and no child process, until the dialog is answered. One "Always Allow" only ever covers the exact build it was granted for.

So the build signs the installed binary itself, with nothing to configure:

```
$ zig build -Doptimize=ReleaseFast
info: signing lcc with "Apple Development: …"
```

*Which* certificate it is does not matter — only that it stays the same between builds — so the build takes whatever the machine already has: a certificate named `lcc-dev` if you made one on purpose, otherwise an Apple Development certificate, which a machine that builds apps already has. The chosen name is printed rather than picked silently. Finding nothing is not an error either; the build then leaves the ad-hoc signature alone and the prompts come back.

The designated requirement becomes `identifier lcc and … certificate leaf[subject.CN] = "<identity>"`, which does not mention the binary's contents at all — two different builds produce the same requirement, so the Keychain keeps recognising lcc and one "Always Allow" holds.

| Override | |
|---|---|
| `-Dsign="<identity>"` | sign with that certificate |
| `LCC_CODESIGN_IDENTITY="<identity>"` | the same, from the environment |
| `-Dsign=none` | opt out, keep the ad-hoc signature |

A self-signed certificate works and never expires on someone else's schedule (Keychain Access → Certificate Assistant → *Create a Certificate*, type *Code Signing*); name it `lcc-dev` and it is preferred automatically. An Apple Development certificate is equally fine, with the caveat that it expires — the requirement changes with the certificate, so the first run after a renewal asks once more.

### MCP servers

Symlinks cannot solve the same problem for MCP servers, because they are not in the repository. `claude mcp add` without `-s user` stores a server under `projects["<absolute cwd>"].mcpServers` in `~/.claude.json` — the key *is* the directory. A worktree is a different directory, so it starts with none of them: the checkout where `linear-server` was added is the only place it exists.

So `lcc start` and `lcc open` read the repo's local-scope servers and pass them to Claude Code as `--mcp-config <file>`, generated per repo under `~/.config/lcc/mcp/`. Without `--strict-mcp-config` they add to the user, global and plugin scopes rather than replacing them, and the servers keep whatever authentication they already had. `~/.claude.json` itself is only ever read: it is Claude Code's own working state, rewritten whole when a session ends, so an outside write survives only until the next exit.

Two things this cannot do. A server that was never authenticated stays unauthenticated — `/mcp` in a session is the only thing that fixes that, and the worktree is not why it is dark. And a session that is *already* running cannot be handed servers retroactively, which is why `lcc start --json` reports what a launch would have carried instead of carrying it.

`mcpCarry` narrows the set to the names it lists, matched case-insensitively, keeping the file's order. `lcc setup` accepts a comma-separated list, `all` to remove the key and carry every server, or `none` to write an empty list and carry none. Carrying everything is the default because it is the answer that never surprises anyone, but it is not free: a server the work never calls still spends every agent in the session its name and its instructions, on every turn — and a pipeline that fans out to twenty subagents pays that twenty times over. Measured across eight pipeline runs in this repo's worktrees, `linear-server` and `xcode` accounted for every local-scope call that was made; `clickup`, `notion` and `sentry` were carried into all eight and never touched once. A name the repo does not have is ignored, and a list that matches nothing launches without MCP rather than with an empty config.

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
src/mcp.zig              local-scope MCP servers, carried into a worktree
src/repos.zig            which repository an issue belongs to, remembered
src/fold.zig             case folding for ASCII, Latin-1, Cyrillic
src/link.zig             pattern matching and symlinking into a worktree
src/disk.zig             path containment and batched `du`
src/derived_data.zig     DerivedData discovery and reclamation
src/claude_projects.zig  ~/.claude/projects discovery and reclamation
src/usage.zig            token usage out of the transcripts, per worktree and model
src/usage_cache.zig      transcripts distilled, so a second run does not read them
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
