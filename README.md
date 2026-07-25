# lcc

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Node](https://img.shields.io/badge/node-%E2%89%A520-brightgreen.svg)](#install)

One command to go from "I should work on PE-N" to a clean git worktree with `.env` symlinks and Claude Code already running.

```
$ lcc
  PE-42   H   In Progress   Migrate notification scheduler off Redis
  PE-51       Todo          Add Liquid Glass to settings sheet
> PE-47   M   Todo          Backfill missing receipt categories
  ...
✓ Worktree created: /Users/me/Documents/Projects/Pantry/.lcc/worktrees/PE-47-backfill-receipts
✓ Linked .env
✓ Linked .env.local
[claude opens in worktree]
```

## Install

```bash
git clone <this repo> ~/Documents/Projects/lcc
cd ~/Documents/Projects/lcc
npm install
npm run build
npm link    # makes `lcc` available globally
```

## Authenticate

```bash
lcc auth
# Browser opens → click Authorize → done.
```

`lcc` uses OAuth 2.0 with PKCE — like `gh auth login`. No API keys pasted into the terminal, no shell history secrets. The OAuth token is stored in your OS keychain (macOS Keychain / Windows Credential Manager / libsecret) and refreshed automatically when it expires.

## Usage

```bash
lcc                  # pick an issue, bootstrap worktree, launch Claude
lcc setup            # configure startTaskCommand, worktreeTemplate, activeStates
lcc list             # list all worktrees
lcc open             # pick a worktree and resume Claude in it (--no-resume for fresh)
lcc open xcode       # pick a worktree and open it in Xcode instead
lcc remove           # pick a worktree, remove it + its Xcode build data (--force)
lcc clean            # reclaim build data left by worktrees that no longer exist
lcc auth             # log in
lcc auth --status    # who am I, when does token expire
lcc auth --logout    # clear token from keychain
```

`lcc open xcode` (alias `lcc o xcode`) uses the same worktree picker as `lcc open`, then launches Xcode instead of Claude. It looks for the shallowest `.xcworkspace`, `.xcodeproj`, or `Package.swift` in the worktree (workspace > project > package when several sit at the same depth) and opens it with `open -a Xcode`.

## Xcode build data

Every worktree Xcode builds gets its **own** DerivedData folder — build products plus the source index, routinely 5–10 GB each. Removing the worktree does not remove them, so a few months of branches quietly turns into a hundred gigabytes.

`lcc remove` now takes the build data with it. Folders are matched by reading `info.plist` in each DerivedData directory and comparing its `WorkspacePath` against the worktree — never by guessing Xcode's name hash — so only folders belonging to the worktree you picked are touched:

```
? Remove worktree feature/PE-227-disable-external-auth?
    worktree   ~/Projects/App.worktrees/pe-227-disable-external-auth
    build data App-ahchusvekwlwlwhdubkhblbxcyis  (7.9 GB)
 (y/N)
```

Declining deletes nothing. `--keep-derived-data` removes the worktree only.

`lcc clean` handles what earlier removals left behind: it lists every DerivedData folder whose project path no longer exists on disk, largest first, and lets you pick which to delete. `-y` takes them all without prompting.

Two things are deliberately never deleted:

- **Xcode's shared caches** — `ModuleCache.noindex`, `SDKStatCaches.noindex`, `CompilationCache.noindex` and friends carry no `info.plist`, belong to no single project, and are skipped. Deletion is also hard-limited to direct children of the DerivedData root.
- **Caches that aren't per-worktree** — `~/Library/Developer/Xcode/UserData/Previews` and `~/Library/Caches/org.swift.swiftpm` are shared across all your projects, so removing one worktree is never a reason to clear them.

The DerivedData root is read from Xcode's own `IDECustomDerivedDataLocation` preference when you've set an absolute custom location, otherwise `~/Library/Developer/Xcode/DerivedData`. `LCC_DERIVED_DATA` overrides both.

## How it works

1. Fetches your **active** Linear issues (assigned to you, state Todo or In Progress) via the official `@linear/sdk`.
2. Shows a searchable picker (`@inquirer/prompts`).
3. Runs `git worktree add` using the branch name Linear computes for the issue (`feature/PE-N-slug`). Base = `origin/HEAD` (or `main` / `master`). Worktrees live at `<repo>/.lcc/worktrees/<branchLeaf>` by default; `.lcc/` is appended to `.git/info/exclude` so git status stays clean.
4. Symlinks every `.env*` from the repo root into the new worktree (skips `.env.example`, `.env.sample`, `.env.template`).
5. Spawns `claude` in the worktree with `stdio: 'inherit'` so you land directly in the session.

## Config

`~/.config/lcc/config.json`

```json
{
  "worktreeTemplate": "{repoRoot}/.lcc/worktrees/{branchLeaf}",
  "envPatterns": [".env", ".env.*"],
  "envExclude": [".env.example", ".env.sample", ".env.template"]
}
```

Tokens in `{worktreeTemplate}`: `{repoRoot}`, `{repoParent}`, `{repoName}`, `{branch}`, `{branchLeaf}`.

### Use your own OAuth application (optional)

`lcc` ships with a built-in public OAuth `client_id`. If you fork lcc or want to point at your own Linear OAuth application (e.g., self-hosted variant), either:

```bash
lcc auth setup --client-id <your-client-id>
# or
export LCC_CLIENT_ID=<your-client-id>
```

`client_id` is public information by OAuth design — PKCE protects the flow without a client secret.

## Headless / CI fallback

If you can't use a browser (CI, remote shell):

```bash
lcc auth --token <personal-api-key>
```

This stores a personal API token directly. No refresh, no expiry tracking — use OAuth wherever possible.

## Contributing

PRs welcome. Run `npm run typecheck && npm run build` before opening a PR.

## License

MIT — see [LICENSE](LICENSE).

## Troubleshooting

- **"Port 39126 already in use"** — another `lcc auth` is running, or another process grabbed the port. Close it and retry.
- **"Not inside a git repository"** — run `lcc` from inside your repo.
- **"Worktree path already exists"** — remove it with `git worktree remove <path>` (or delete the directory).
- **`claude` not found** — install Claude Code: https://docs.claude.com/en/docs/claude-code
