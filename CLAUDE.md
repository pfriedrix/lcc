# CLAUDE.md

Working notes for an agent editing this repo. `README.md` is the user-facing manual — what
each command does and why it behaves that way lives there, and is not repeated here.

`lcc` is a single Zig binary, macOS only, pinned to **Zig 0.16**. It shells out to `git`,
`claude`, `gh`, `open`, `du`, `defaults`, `plutil`, `mdfind`, `xcode-select`; everything else
is the Zig standard library plus CoreFoundation/Security.

## Commands

Run from the repo root:

```bash
zig build test --summary all       # unit tests (~6s, 337 at last count)
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
  `LCC_CLAUDE_PROJECTS`, `LCC_CLAUDE_JSON`, `LCC_DERIVED_DATA`, `LCC_SESSIONS`,
  `LCC_WATCH_DIR`. The last one moves the socket, the lock, the hook settings and the
  recovered-status files together, so it is the one the daemon and `watch_state` tests need.
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
- **`orConfig` erases who asked for an option, so nothing may be *refused* on its value.**
  `opts.all`, `opts.plan_mode`, `opts.watch`, `opts.tokens` all come back from `orConfig` as a
  plain `bool` that reads the same whether the user typed the flag or a `~/.config/lcc` key set
  it years ago. A guard like "`--all` does nothing under `--json`" is a sentence about *argv*,
  and keying it on the resolved value fires for every caller of a config carrying
  `allIssues: true` — who cannot unset a flag they never passed, so `lcc start PE-N --json`
  fails outright and the worktree gets made by hand. `start.AllIssues` keeps `.flag` apart from
  `.config` for that reason: behaviour asks `enabled()`, the refusal asks `== .flag`. A new
  guard over a config-backed option needs the same split, and `.config` has to stay a distinct
  tag rather than be folded back into a bool once it looks unused.
- **Interactive commands need a tty.** `src/prompt.zig` puts the terminal in raw mode and
  returns `Error.NotATerminal` otherwise, so any path that reaches a picker fails when run
  from a tool call. Exercise the non-interactive paths instead: `lcc start PE-N --json`,
  `lcc issue show PE-N --json`, `lcc list --local`, `--yes` on the destructive ones. A
  picker's *rows* are still reachable: they are built by pure functions over a row struct
  (`cellsFor` / `rowLine` / `headerLine` in `src/commands/remove.zig`), which is where a
  layout is tested and where a throwaway `std.debug.print` can show you a frame.
- **Every line a picker prints has to be paid for in `pageSize`.** `prompt.checkbox` and
  `prompt.search` erase their frame by walking the cursor up `screen.lines`, so a frame taller
  than the terminal scrolls and every later redraw eats a line of scrollback instead. The
  `reserved` argument to `pageSize` is what keeps the two in step — `checkbox` passes 5 when
  it has a column header and 4 when it does not. Add a line to a frame without raising it and
  the list looks fine until the terminal is short.
- **The dashboard is a frame like any other, so every line it prints has to be paid for.**
  It was the one that did not: `dims.rows` was read and never used, and the table rendered a
  row per worktree. Past the height of the terminal the frame scrolls, `Screen.eraseFrame`
  walks the cursor up over lines that are no longer the ones it wrote, and each redraw takes
  another line of whatever was on the screen before `lcc open` started. `visibleRows` is the
  budget — `spent` counts the lines already drawn this frame, and it leaves one row spare so
  the closing newline cannot scroll — and `window` keeps the cursor inside it. Anything new
  in that frame is another argument to `spent`, not a free line. The same rule is why an
  error there is a *counted* line in the frame rather than an `app.ui.fail`: `fail` writes
  through a different writer and past `screen.lines`, so the next erase walks the wrong
  distance and the frame smears.
- **A `git` run with `cwd` inside a worktree can answer for a different repository.** Git
  discovers its repo by walking *up* from `cwd` until it finds a `.git`, and the default
  worktree template is `{repoRoot}/.lcc/worktrees/{branchLeaf}` — so a worktree that lost its
  `.git` link does not make `git status --porcelain` fail, it makes it succeed with the *main*
  checkout's changes. `dirtyCount` guards on `unlinked` for that reason: without it every
  emptied worktree reads `clean` or `N dirty` in `lcc remove` and `lcc list` instead of
  `missing`, and the removal prompt warns about uncommitted changes that are not in there and
  cannot be lost. The guard only bails when the `.git` entry is *definitely* absent
  (`FileNotFound` / `NotDir`) — an unreadable parent has to fall through to git rather than be
  reported as a deleted checkout, the same distinction `disk.presence` draws. Any new read that
  passes a worktree path as `cwd` needs the same guard; a broken `.git` *pointer* is already
  safe, because git fails loudly (exit 128) instead of escaping.
- **An Xcode is a path, not a bundle id.** A beta carries `com.apple.dt.Xcode` exactly like
  the release build, so `open -a Xcode` hands the choice to LaunchServices and `lcc open
  xcode` cannot honour one — the same reason `closeIn` addresses each *running* Xcode by its
  bundle path. Discovery leads with `mdfind` because an Xcode outside `/Applications` is
  normal (a beta parked in `~/Downloads`); the `/Applications` and `~/Applications` scans are
  the fallback for a machine with Spotlight off and would miss that beta on their own. What
  makes a bundle an Xcode is `Contents/MacOS/Xcode` — the file `parseApps` already keys on —
  not its name. `--xcode` and the `xcodeApp` setting run through the same matcher but not the
  same failure: `open.Preference` keeps `.flag` apart from `.config` so a typo'd flag can fail
  the command while a setting written months ago only warns and asks, which is the split
  `start.AllIssues` draws for the same reason.
- **Keychain and code signing are coupled.** The Linear token's ACL is keyed on the binary's
  code signature, so `build.zig` signs the installed binary to keep one "Always Allow"
  valid across rebuilds. Removing or bypassing that (`-Dsign=none`) brings back a login
  password prompt on every rebuild, from a process that blocks with no output.
- **"No token" and "the Keychain would not give it to me" are different answers.**
  `oauth.readToken` separates `.missing` from `.unreadable`, and every caller has to keep
  them apart — collapsing them back into `getToken() == null` compiles, reads tidier, and
  tells a user whose token is right there to run `lcc auth` again: a browser round trip for
  a Keychain dialog that only had to be answered. The refusal is the *likelier* of the two
  on a machine that rebuilds lcc, because a renewed signing certificate changes the
  designated requirement and macOS asks once more — and that prompt can be denied, escaped,
  or missed behind a full-screen terminal. `keychain.describeLast` is what turns the
  OSStatus into that sentence; leaving it uncalled is how the distinction quietly dies.
- **`src/keychain.zig` imports five narrow C headers on purpose.** The umbrella
  `CoreFoundation.h` / `Security.h` do not translate on this SDK. Do not tidy them into one
  import.
- **`start.zig`'s `bail` only exits when nobody is waiting on it.** It returns
  `error{Failed}` under `opts.returns_to_caller`, which is what `lcc open`'s `n` sets: the
  dashboard calls `start.run` in-process, so a `std.process.exit` in there takes the whole
  dashboard down — every other session's row with it — over one bad answer. That is why
  every call site reads `return bail(…)` and why `cancel` has the same shape. A new call
  site written as a bare `bail(…)` is a compile error rather than a silent fall-through,
  but only because the returned error value cannot be discarded; do not "fix" that by
  ignoring it.
- **A replay withholds a sequence; it must still hand back the half it swallowed.** The
  replay ends at `scrollback.written` frozen at attach time — an offset that lands wherever
  the child happened to be, so the last `.replay` frame regularly ends mid-CSI. The bytes
  the filter has buffered are not discardable: the very next frame is `.output`, written
  raw, and it begins with the rest of that sequence. `watch_attach` calls
  `ModeFilter.flush` once, on the first live frame, for that reason. Without it the
  terminal prints `1;31m` as text and the escape it belonged to is gone — which reads as
  the agent emitting garbage rather than as a seam in lcc. The same rule is why a CSI too
  long for `pending` is passed through verbatim instead of truncated: an unterminated CSI
  eats every character after it until the terminal finds a final byte, so whole lines of
  output simply vanish. `ModeFilter.overhead` is the caller's buffer bound and is exact —
  it was one byte short of the worst case, which in ReleaseFast is a write past the end of
  a stack array.
- **Dropping the child's setup from a replay leaves a debt the daemon has to settle.**
  `ansi.ModeFilter` withholds the sequences that configure rather than draw, because
  replaying a keyboard-stack push a second time is what once broke Enter in Claude Code's
  picker. But the child sends that setup exactly once, at startup, and `term.sanitize` takes
  all of it down on detach — so with only the filter, a re-attached terminal has bracketed
  paste, the kitty keyboard protocol, modifyOtherKeys and focus reporting *off* while Claude
  Code still believes them on: a multi-line paste submits a line at a time and Shift+Enter is
  plain Enter. `watch_session.Session.modes` therefore tracks the resolved state over the
  whole session — not the ring window, which for a long session no longer holds the startup —
  and `attachClient` carries it on the `attached` frame for the client to apply before any
  replay byte. The stack is settled to *one* push however many the history holds, which is
  what keeps the original double-push bug fixed. `?2026` is excluded on purpose: a
  synchronised update is per-frame, and settling a half-open one freezes the terminal until
  the child's next frame closes it.
- **`clamp`'s `skipped` is the only notice that a client's screen is now a lie.** When the
  ring laps past a client the cursor jumps an arbitrary range, mid-escape-sequence, and
  neither end can tell. Discarding the flag compiles and looks tidy, and it leaves a hole
  in the screen that nothing ever repaints over, because Claude Code only redraws what it
  believes changed. `pumpClient` turns a skip into a `repaint` for that reason, and it
  queues until the ring is drained rather than one frame per poll pass — the starvation was
  what made the ring lap in the first place.
- **A session's pty size is measured, never defaulted.** `Handoff.size` carried 40x120 and
  no call site overrode it, so every session was born on a terminal nobody has: the banner,
  the prompt box and the `--resume` picker were laid out for 120 columns and *then* replayed
  into the real terminal. `resolveSize` asks `term.currentSize()` and keeps `unmeasured_size`
  for the case where nothing on the process has a window — a `--json` start from a tool call.
  Anything that registers a session has to go through it.
- **The repaint poke has to be two sizes separated in time, not two ioctls.** `renegotiate`
  resizes the pty only when the negotiated size differs, so re-attaching from the terminal a
  session was last attached from tells Claude Code nothing and the screen keeps whatever the
  replay painted. `attachClient` compares the size across `renegotiate` and pokes when it did
  not move — but the two `pty.resize` calls cannot be back to back. The kernel coalesces the
  two SIGWINCHes, and an app that reads the winsize *in its handler* finds the value already
  restored, sees no change, and skips the repaint. Measured against a real Claude Code: a
  same-size attach with a back-to-back poke returned **0 bytes**, a resize with time either
  side returned ~11 KB starting with `CSI 2J`, and the two-phase poke returns ~2 KB from a
  session that was otherwise silent. So `repaint` shrinks now, sets `repaint_pending`, and
  `settleRepaint` puts it back on the `repaint_restore_at` deadline. It restores to the
  session's *current* `size` rather than a captured one, so a real resize inside the window
  wins; `renegotiate` clears the flag for the same reason.

  How long the shrink stands is the whole of the user-visible cost: Claude Code anchors its
  UI to the bottom row, so a frame drawn a row short and then restored *moves down a row* on
  screen. `repaint_settle_ms` (400ms) is only the fallback for a child that never answers.
  The real path is `reactedToRepaint`: the first output after the shrink is proof the child
  read the new size, and it shortens the deadline to `repaint_floor_ms` (40ms). Do not settle
  on that output *immediately* — a session that was already printing would restore before its
  handler ever ran, and a busy session is exactly the one a ring lap pokes. Measured: the
  child answers in ~9ms, the shrink stands ~40ms, and 400ms was plainly visible as a jump.
  A test whose stand-in traps SIGWINCH and prints proves nothing here — a shell trap fires on
  the signal whatever the size says. It has to report the size it actually read.
- **Claude Code runs on the alternate screen, and a byte replay cannot rebuild one.** Its
  first bytes are `ESC 7 CSI r ESC 8 CSI ?25h CSI ?1049h CSI 2J CSI H`, and from there it
  paints by absolute address (`CSI 58;1H`) and rewrites only the cells it believes changed —
  a capture of a live session contains **no LF at all** and no tabs. Two things follow. The
  alternate screen has no scrollback, so there is nothing for a replay to restore: the buffer
  is exactly one screen, and `attachClient` skips the replay entirely when
  `ModeState.onAltScreen()` says so. And replaying a byte history from wherever the ring
  happens to start rebuilds a screen that is *not* the one the app thinks it is looking at, so
  its next partial update leaves half of each stale line in place — lines come out as a hybrid
  of two different strings, which is what "text disappears or moves" actually looks like. The
  forced repaint is what makes the screen right, not the replay.
- **A hook event that reports no `permission_mode` must not clear the one already known.**
  Only some events carry it — `Notification` does not (see the test in `watch_hooks.zig`).
  `watch_session.setPlan` is guarded on `permission_mode.len > 0` for that reason, and
  `watch_state.write` merges the previous record's mode in for the same one. Drop either
  guard and it still compiles, still passes anything that only replays `PreToolUse`, and
  quietly takes a session out of `◈ plan` the first time the agent asks for a permission —
  so `plan` only ever survives until the next prompt, which reads as the mode being flaky
  rather than as a bug.
- **`watch_state` recovers a status, never a session.** The rows it feeds `collect` keep
  `session_id = null` on purpose: that is the only thing making `watch_table.Row.attachable`
  return `false`, so enter starts the work again instead of asking the daemon for a pty that
  died with the previous one. Filling the id in from the record's `lcc_session` looks like an
  improvement and turns every recovered row into an `unknown_session` error. The ids collide
  across daemons anyway — `next_id` restarts at 1 — which is also why the state file is named
  for Claude Code's session UUID rather than for either the lcc id or the worktree path.
- **A dashboard row has to name a directory that still exists.** `sessions.present` is that
  rule, and *both* ways the rows are read have to go through it — the live snapshot in
  `collect` / `snapshotOnce` and `sessions.resolved` — because the daemon never drops a
  session from its own list and flushes that whole list once more as it exits, so its file
  outlives it naming every worktree it ever ran in. `collect` puts the same predicate on
  `app.worktreeChoices` through `onDiskChoices`, not inside `worktreeChoices`: git keeps
  listing a worktree whose directory was deleted (`prunable`), and that is exactly the row
  `lcc list` shows in red and `lcc remove` needs in order to clean the entry up. Anything
  counting sessions has to ask too — `lcc daemon --status` reports `sessions.visibleCount`,
  not `state.sessions.len`, or it contradicts the list `lcc open` prints from the same file.
- **"Gone" is a narrower answer than "the stat failed".** `disk.presence` separates the two and
  `isGone` is the one a row is hidden on, because the predicate now runs against *live*
  sessions: collapse `AccessDenied`, `SymLinkLoop`, a stalled mount or a deleted cwd into
  `missing` and one unreadable parent directory takes every running agent off the dashboard,
  out of `lcc open --json`, and out of reach of anything but `--stop-all`. `isDirectory` is the
  positive question and stays false for `unknown`; nothing may hide a row on `!isDirectory`.
- **A registry row reading `unknown` is bookkeeping, not a session.** `rowFor` collapses it
  through `liveMatch` itself, so no caller can hand it a dead id. Leave it a match and the
  worktree's hook-recovered status is never consulted — which after a daemon dies is every
  worktree it touched, so `watch_state` recovers nothing and the column reads `unknown` with an
  age measured from the epoch. Giving `rowFor` the recovered status *and* the dead session id
  instead is worse than either: `attachable` goes true and enter asks the daemon for a session
  nothing holds. The collapsed entry is still read for the age and the issue — dropping it
  whole is what leaves a worktree the daemon lost reading `—` with no issue, as if nothing had
  ever run there. Both of `collect`'s loops go through `rowAt`; the second one exists for
  sessions outside this repo, and building its rows by hand is how they end up the only ones
  that never recover a status.
- **`collect` runs once a second, so it allocates from the frame arena.** It rebinds the app
  (`var scoped = app; scoped.gpa = arena;`) and every call under it — `watch_client.snapshot`,
  `scoped.repo()`, `worktreeChoices`, `sessions.load` — inherits that. Hand any of them
  `app.gpa` and the dashboard grows a git spawn's output plus a parsed snapshot per frame in
  the process arena, which is never freed, until an overnight `lcc open` is measured in
  hundreds of megabytes.
- **The dashboard's git facts cannot be recomputed per frame, and cannot live in the frame
  arena either.** `collect` already pays three git spawns a second (`repo()` is two, `listWorktrees`
  one), and `dirtyCount` is one spawn *per worktree* — so re-reading every row every tick is a git
  process per worktree per second on a repo where `git status` is the slow call. `watch_git.Cache`
  is the budget: one `for-each-ref` for every branch's drift at once every five seconds, and one
  `git status` per frame for whichever row has waited longest, so the per-frame cost stays O(1)
  however many worktrees there are. The cache is a fixed-capacity value owned by `dashboard`
  precisely because `frame_arena` is reset every tick and `app.gpa` is the process arena that is
  never freed — allocating its paths from either is how an overnight `lcc open` either loses the
  cache every second or grows without bound. Rows from *another* repository are left blank rather
  than `—`: there is no repo handle to measure them with, so "not yet" would be a promise nothing
  will keep.
- **`describe` parses the hook payload a second time on purpose.** Folding `tool_name` and
  `tool_input` into `watch_hooks.Payload` compiles and reads tidier, and it makes the whole parse
  fail on a `tool_input` shaped in a way lcc does not model — which takes `cwd` and
  `permission_mode` down with it, so the session stops reporting its status at all and the
  dashboard reads `no session` for a live agent. A separate parse that returns `""` on any error
  cannot do that. The text it produces is the *agent's own*, and `term.truncate` counts codepoints
  and strips nothing, so it is stripped of every byte below 0x20 before it can reach a raw-mode
  frame: an escape in a Bash command moves the cursor, and `Screen.eraseFrame` then walks up over
  lines it never wrote.
- **`rowAt` reads the hook record for every row, and may take only one thing from it.** It used to
  load `watch_state` solely for worktrees with no live session; `DOING` needs it for live ones too,
  because the hook writes that file *before* it reports to the socket. The status and the session
  id must still come from the live session — `liveMatch` is what keeps a dead daemon's row from
  going `attachable`, and the recovered status is deliberately the *older* answer. Taking the
  record's status "while we are in there" undoes both.
- **A dropped column costs more than a cut name.** `fit` drops whole columns, and `TASK` is prose:
  a branch slug like `feature/pe-338-keep-error-observation-alive-after-the-main-sheet-is` measures
  over fifty columns, so dropping before shrinking took `GIT` and `DOING` off an 80-column terminal
  to spell out a name whose first twenty characters had already identified the row. `fit` therefore
  drops `WORKTREE`, then shrinks `TASK` toward `task_floor`, and only then drops the fact columns —
  and `measure` caps `TASK` and `DOING` outright, since neither is worth an unbounded share of the
  row. `STATUS` is still never dropped.
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
