# lcc — Zig port

A dependency-free rewrite of `lcc` in Zig. Same commands, same config file, same
Keychain entry, same output; one 1.5 MB binary instead of Node plus 87 MB of
`node_modules`.

## Build

```bash
zig build -Doptimize=ReleaseFast    # → zig-out/bin/lcc
zig build test                     # unit tests
```

Requires **Zig 0.16** and macOS. Zig's standard library changed shape
substantially in 0.16 (`std.fs.File` → `std.Io.File`, an `Io` parameter
threaded through every I/O call, `main(init: std.process.Init)`); the port
will not compile on 0.15 or earlier and will likely need edits for 0.17.

To use it instead of the npm build:

```bash
ln -sf "$PWD/zig-out/bin/lcc" /opt/homebrew/bin/lcc
```

## What replaced what

| npm dependency | Replacement |
|---|---|
| `@linear/sdk` | `linear.zig` — GraphQL over `std.http.Client`, `std.json` |
| `@napi-rs/keyring` | `keychain.zig` — Security.framework `SecItem*` via `@cImport` |
| `@inquirer/prompts` | `prompt.zig` — raw-mode `search`, `confirm`, `checkbox`, `input` |
| `execa` | `exec.zig` — `std.process.run` / `spawn` |
| `commander` | argv parsing in `main.zig` |
| `picocolors` | `ui.zig` — ANSI escapes, honours `NO_COLOR` and non-tty |
| `String.toLowerCase()` | `fold.zig` — case folding for ASCII, Latin-1, Cyrillic |
| `open` | `open(1)` via `exec.zig` |

`@cImport` deliberately pulls in five narrow CoreFoundation/Security headers
rather than the umbrella ones: on the macOS 26.5 SDK
`CoreFoundation/CoreFoundation.h` drags in mach headers whose bitfield structs
translate-c turns opaque (tripping their own `_Static_assert`s), and
`Security/Security.h` drags in `xpc.h`, which puts nullability attributes on the
non-pointer `uuid_t`.

## Deliberate differences from the TypeScript version

- **macOS only.** `@napi-rs/keyring` covered Linux (libsecret) and Windows
  (Credential Manager) for free; this speaks Security.framework directly.
- **`auth --status` prints `2026-07-26 18:38:37`**, local time via libc
  `strftime`, where Node printed the locale string `7/26/2026, 6:38:37 PM`.
- **Picker rows are plain text.** The prompt pads and truncates labels by
  codepoint, which ANSI escapes inside a row would break. `lcc list`, which does
  not go through the picker, keeps its colours.
- **Picker results are ranked, not left in list order.** Every whitespace-
  separated token still has to match, as before, but survivors are ordered by
  where they matched: start of the haystack (the issue identifier) beats the
  start of a word beats mid-word. Equal scores keep the incoming
  state-then-recency order. Typing `log` now surfaces `logout()` and
  `logAllValues()` above issues that merely happen to sit in `Backlog`.
- **Sizing runs one `du -sk` over every folder** instead of eight concurrent
  `du` processes.
- **Personal API tokens go in the `Authorization` header raw**, matching the
  Linear SDK's `apiKey` mode; the TypeScript `start` path sent them as
  `Bearer <token>`.
- **`config.json` keys are written in struct order.** Same keys, same values,
  different order than Node's object spread produced.

## Verified against the TypeScript build

Both binaries were run against the same repo, config, and Linear workspace:

- `list` — byte-identical output
- `start --all` — same issue, branch, worktree path, `.env`/`.env.local`
  symlinks (`.env.example` correctly skipped), and same `claude` argv and cwd
- `remove` — same confirmation text, same branch disposition
  (`merged — will be deleted`), same resulting git state; declining aborts
- `clean` — same orphan count and total (22 folders, 104 GB)
- `open` / `open xcode` — same launch line, same "no project found" warning,
  same unknown-target error
- `setup` — semantically identical config file
- outside a git repo — same message, same exit code 1
