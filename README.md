# lcc

One command to go from "I should work on PE-N" to a clean git worktree with `.env` symlinks and Claude Code already running.

```
$ lcc
  PE-42   H   In Progress   Migrate notification scheduler off Redis
  PE-51       Todo          Add Liquid Glass to settings sheet
> PE-47   M   Todo          Backfill missing receipt categories
  ...
✓ Worktree created: /Users/me/Documents/Projects/Pantry.worktrees/PE-47-backfill-receipts
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
lcc --start-task     # also run /linear-pfx-plugin:start-task in the new session
lcc auth             # log in
lcc auth --status    # who am I, when does token expire
lcc auth --logout    # clear token from keychain
```

## How it works

1. Fetches your **active** Linear issues (assigned to you, state Todo or In Progress) via the official `@linear/sdk`.
2. Shows a searchable picker (`@inquirer/prompts`).
3. Runs `git worktree add` using the branch name Linear computes for the issue (`feature/PE-N-slug`). Base = `origin/HEAD` (or `main` / `master`).
4. Symlinks every `.env*` from the repo root into the new worktree (skips `.env.example`, `.env.sample`, `.env.template`).
5. Spawns `claude` in the worktree with `stdio: 'inherit'` so you land directly in the session.

## Config

`~/.config/lcc/config.json`

```json
{
  "worktreeTemplate": "{repoParent}/{repoName}.worktrees/{branchLeaf}",
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

## Troubleshooting

- **"Port 39126 already in use"** — another `lcc auth` is running, or another process grabbed the port. Close it and retry.
- **"Not inside a git repository"** — run `lcc` from inside your repo.
- **"Worktree path already exists"** — remove it with `git worktree remove <path>` (or delete the directory).
- **`claude` not found** — install Claude Code: https://docs.claude.com/en/docs/claude-code
