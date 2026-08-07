# CLAUDE.md

Working notes for an agent editing this repo. `README.md` is the user-facing manual — what
each command does and why it behaves that way lives there, and is not repeated here.

`lcc` is a single Zig binary, macOS only, pinned to **Zig 0.16**. It shells out to `git`,
`claude`, `gh`, `open`, `du`, `defaults`, `plutil`; everything else is the Zig standard
library plus CoreFoundation/Security.

## Commands

Run from the repo root:

```bash
zig build test --summary all       # unit tests (~3s, 128 at last count)
zig build                          # debug binary → zig-out/bin/lcc
zig build -Doptimize=ReleaseFast   # what PATH should be serving
zig build run -- list              # run without installing
```

`zig build test` compiles every module but never links the executable, so it cannot tell
you that `lcc` still builds — run `zig build` too. That is exactly what
`.github/workflows/ci.yml` does on every PR into `master`, on a pinned `macos-15` runner
with Zig pinned to `0.16.0`; it is a required check, so a red suite blocks the merge.
Bumping the Zig version means editing the pin in that workflow **and** README's Build
section — both are commented as having to match.

`info: signing lcc with "Apple Development: …"` is printed by `build.zig` while the build
graph is constructed, so it appears on *every* `zig build` invocation including `test`. It
is not an error and it does not mean anything was installed.

## Layout

`src/` holds the units — one concern per file (`git.zig`, `linear.zig`, `oauth.zig`,
`keychain.zig`, `prompt.zig`, `usage.zig`, `mcp.zig`, `link.zig`, `disk.zig`, …).
`src/commands/` holds one file per subcommand, composing those units. Shared behavior
belongs in a `src/` module with its own tests, not inside a command file.

A subcommand is wired in three places, and a change to its flags usually touches all
three:

1. the `usage` string literal in `src/main.zig` (the help text is hand-written, not derived),
2. a `<name>Command` function in `src/main.zig` that parses argv into the command's `Opts`,
3. `Opts` plus `pub fn run(app, opts)` in `src/commands/<name>.zig`.

`dispatch` in `src/main.zig` maps the first argument to those functions. Every action is
named explicitly — there is no default command and no magic dispatch.

`app.App` (`src/app.zig`) is the context every command takes by value: `gpa`, `io`,
`environ`, `ui`. There are no globals and nothing reads the environment directly — go
through `app.environ`. Git access is `app.repo()` / `app.repoAt(path)`.

`app.gpa` is the **process arena** from `std.process.Init`, so command-path allocations
live until exit and are generally not freed. Tests are the leak-checked side of that.

## Tests

Tests are in-source: a `test "…"` block at the bottom of the module it covers. There is no
`tests/` directory and no separate test target — `build.zig` defines the single `test` step
over a test module rooted at `src/main.zig`.

**The trap that matters here:** Zig collects tests only from files the test root reaches, and
`src/main.zig`'s bottom `test { … }` block names every module by hand. A file missing from
that list contributes **zero** tests and `zig build test` still reports success. If you add
a source file, add its `_ = @import("…")` line there in the same change, and sanity-check
the pass count moved.

`src/commands/start_plan_test.zig` is the out-of-file pattern: a test-only file, imported
from the same block, for tests authored without touching the production file. It forces the
seam under test to be `pub`.

Conventions inside a test:

- `std.testing.allocator` for the allocator (leak-checked; free everything, or wrap it in an
  `ArenaAllocator` for the test's duration).
- `std.testing.io` for the `Io` parameter, `std.testing.tmpDir(.{})` for anything on disk.
- Shelling out to real `git` inside a `tmpDir` is the accepted style, not a smell — see
  `src/git.zig`'s `repoRoot` and merge-disposition tests.
- Network and Keychain layers are tested at the string boundary instead (`buildQuery`,
  `readMutation`, `unwrap` in `src/linear.zig`) — no requests, no Keychain reads.
- Never let a test touch real state under `$HOME`. Build a `std.process.Environ.Map` and set
  the override the module reads: `LCC_REPOS`, `LCC_USAGE_CACHE`, `LCC_REMOTE_CACHE`,
  `LCC_CLAUDE_PROJECTS`, `LCC_CLAUDE_JSON`, `LCC_DERIVED_DATA`.
- Failure messages carry what a wrong answer costs, not just the mismatch. `start_plan_test.zig`
  is the reference for that shape.

Do not "simplify" `build.zig`'s separate `test_mod`: reusing the executable's module makes
`zig build test` reuse the executable compilation and silently run nothing.

## Traps

- **`lcc` on PATH is a symlink to `zig-out/bin/lcc`.** Editing `src/` changes nothing that
  PATH serves. `zig build test` never rewrites it; a plain `zig build` replaces it with a
  *debug* build. Verify behavior against a fresh `zig build -Doptimize=ReleaseFast`.
- **Zig 0.16 API, not 0.14/0.15.** `main` takes `std.process.Init`; `Io` is threaded through
  every I/O call; it is `std.Io.File` and `Io.Dir.cwd()`, not `std.fs.File`. Pre-0.16
  snippets from memory or the web will not compile.
- **All output goes through `app.ui`** — `info`, `step`, `success`, `warn`, `hint`, `fail`,
  `payload`. Never `std.debug.print` and never a raw stdout write. In machine mode the
  command sets `machine.ui.divert = opts.json` (pattern in `src/main.zig`), which moves the
  whole log vocabulary to stderr so stdout carries nothing but `ui.payload`. Writing a
  progress line to stdout in `--json` mode breaks every caller parsing it.
- **JSON contracts are stable surface.** Every key is always present, absent values are
  `null` rather than dropped, failures come back as `{"error":{"code":…}}` on stdout with
  exit 1, and `lcc issue show`'s `issue` block matches `lcc start --json`'s field for field
  where they overlap. Adding a key is cheap; renaming or dropping one is a breaking change
  for the slash commands that parse it.
- **Interactive commands need a tty.** `src/prompt.zig` puts the terminal in raw mode and
  returns `Error.NotATerminal` otherwise, so any path that reaches a picker fails when run
  from a tool call. Exercise the non-interactive paths instead: `lcc start PE-N --json`,
  `lcc issue show PE-N --json`, `lcc list --local`, `--yes` on the destructive ones.
- **Keychain and code signing are coupled.** The Linear token's ACL is keyed on the binary's
  code signature, so `build.zig` signs the installed binary to keep one "Always Allow"
  valid across rebuilds. Removing or bypassing that (`-Dsign=none`) brings back a login
  password prompt on every rebuild, from a process that blocks with no output.
- **`src/keychain.zig` imports five narrow C headers on purpose.** The umbrella
  `CoreFoundation.h` / `Security.h` do not translate on this SDK. Do not tidy them into one
  import.
- **A session's hook settings file is per session, not per daemon.** `watch_paths.hooksFor`
  names it `hooks-<session id>.json` and `watch_hooks.settingsJson` bakes that id into every
  hook command line, so a report says which session it came from. Collapsing them back into
  one shared `hooks.json` compiles and looks tidier, and it silently routes every session's
  hooks to whichever session in that worktree was registered first — including a dead one,
  which then eats the live sessions' updates while they sit frozen on whatever their first
  byte of output set. The worktree path is *not* a unique key: `lcc open` will happily start
  a second session in a worktree that already has one.

## Style

**The Zig sources carry no comments.** No `//!` module headers, no `///` on declarations,
no inline notes. They were all removed deliberately; do not reintroduce them, and do not
add one to explain a change you are making.

That leaves three places for a "why", and something has to go in one of them or it is lost:
the commit message, this file's **Traps** section (for anything that would bite the next
person editing the file), or README (for anything a *user* of `lcc` would want). Reach for
`git log -p` and `git blame` when a line looks arbitrary — that is now the rationale record.

Test names carry the rest. A `test "…"` string is the one place left where a constraint is
stated in words, so make it a sentence about the behaviour and not a label for the
function: `test "a turn that went silent asks for a person, rather than claiming it
finished"` survives the loss of its comment; `test "decay"` would not.

Default branch is `master`. Branch prefixes: `feature/`, `fix/`, `docs/`, `chore/`.
