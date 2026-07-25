import { promises as fs, type Dirent } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { execa } from 'execa';

const DEFAULT_ROOT = path.join(os.homedir(), 'Library', 'Developer', 'Xcode', 'DerivedData');

export interface DerivedDataEntry {
  /** Absolute path of the folder, e.g. `.../DerivedData/MyApp-abcdef…`. */
  path: string;
  /** Folder name — the same string Xcode shows in its build locations. */
  name: string;
  /** Project or workspace this folder was built for, from `info.plist`. */
  workspacePath: string;
}

export interface SizedDerivedData extends DerivedDataEntry {
  /** Disk usage in bytes. */
  size: number;
  sizeLabel: string;
}

/**
 * Where Xcode keeps DerivedData. Honours a custom *absolute* location from Xcode's
 * preferences; a relative one ("Relative to Workspace") lives inside the project and
 * is already removed along with the worktree, so the default root still applies.
 * `LCC_DERIVED_DATA` overrides both.
 */
export async function derivedDataRoot(): Promise<string> {
  const override = process.env.LCC_DERIVED_DATA?.trim();
  if (override) return path.resolve(override.replace(/^~(?=$|\/)/, os.homedir()));
  try {
    const { stdout } = await execa('defaults', [
      'read',
      'com.apple.dt.Xcode',
      'IDECustomDerivedDataLocation',
    ]);
    const custom = stdout.trim();
    if (custom && path.isAbsolute(custom)) return custom;
  } catch {
    // Key unset — Xcode is using the default location.
  }
  return DEFAULT_ROOT;
}

/**
 * Every per-project folder under `root`. Xcode's own shared caches
 * (`ModuleCache.noindex`, `SDKStatCaches.noindex`, …) carry no `info.plist` and are
 * skipped — they belong to no project and must never be treated as removable.
 */
export async function listDerivedData(root: string): Promise<DerivedDataEntry[]> {
  let dirents: Dirent[];
  try {
    dirents = await fs.readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }
  const entries: DerivedDataEntry[] = [];
  for (const dirent of dirents) {
    if (!dirent.isDirectory() || dirent.name.startsWith('.')) continue;
    const full = path.join(root, dirent.name);
    const workspacePath = await readWorkspacePath(full);
    if (!workspacePath) continue;
    entries.push({ path: full, name: dirent.name, workspacePath });
  }
  return entries;
}

async function readWorkspacePath(dir: string): Promise<string | null> {
  const plist = path.join(dir, 'info.plist');
  let raw: string;
  try {
    raw = await fs.readFile(plist, 'utf8');
  } catch {
    return null;
  }
  const direct = matchWorkspacePath(raw);
  if (direct) return direct;
  // Some Xcode versions write a binary plist — convert before matching.
  try {
    const { stdout } = await execa('plutil', ['-convert', 'xml1', '-o', '-', plist]);
    return matchWorkspacePath(stdout);
  } catch {
    return null;
  }
}

function matchWorkspacePath(xml: string): string | null {
  const match = /<key>WorkspacePath<\/key>\s*<string>([^<]*)<\/string>/.exec(xml);
  const value = match?.[1]?.trim();
  return value ? decodeEntities(value) : null;
}

function decodeEntities(value: string): string {
  return value
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, '&');
}

/**
 * Folders whose project lives inside `worktreePath`. A worktree can own more than
 * one (an `.xcodeproj` and a `Package.swift`, say), so all matches come back.
 */
export async function forWorktree(
  entries: DerivedDataEntry[],
  worktreePath: string,
): Promise<DerivedDataEntry[]> {
  // Xcode records the resolved path; `git worktree list` does not resolve symlinks.
  const root = await realpath(worktreePath);
  return entries.filter((entry) => isInside(root, entry.workspacePath));
}

/** Entries whose project is gone from disk — the worktree was removed long ago. */
export async function orphans(entries: DerivedDataEntry[]): Promise<DerivedDataEntry[]> {
  const checked = await Promise.all(
    entries.map(async (entry) => ((await exists(entry.workspacePath)) ? null : entry)),
  );
  return checked.filter((entry): entry is DerivedDataEntry => entry !== null);
}

/** Attach disk usage to each entry, measuring a few folders at a time. */
export async function withSizes(entries: DerivedDataEntry[]): Promise<SizedDerivedData[]> {
  const sized: SizedDerivedData[] = new Array(entries.length);
  let next = 0;
  const worker = async () => {
    for (;;) {
      const index = next++;
      const entry = entries[index];
      if (!entry) return;
      const size = await dirSize(entry.path);
      sized[index] = { ...entry, size, sizeLabel: formatBytes(size) };
    }
  };
  await Promise.all(Array.from({ length: Math.min(8, entries.length) }, worker));
  return sized;
}

/** Disk usage in bytes via `du` — walking millions of build artifacts in JS is far slower. */
async function dirSize(target: string): Promise<number> {
  // `du` exits non-zero on unreadable subdirectories but still prints the total.
  const { stdout } = await execa('du', ['-sk', target], { reject: false });
  const kb = Number.parseInt(stdout.trim().split(/\s+/)[0] ?? '', 10);
  return Number.isFinite(kb) ? kb * 1024 : 0;
}

/**
 * Delete one DerivedData folder. Refuses anything that is not a direct child of
 * `root`, so the root itself and Xcode's shared caches can never be hit.
 */
export async function removeDerivedData(entry: DerivedDataEntry, root: string): Promise<void> {
  const target = path.resolve(entry.path);
  if (path.dirname(target) !== path.resolve(root) || !entry.name) {
    throw new Error(`Refusing to delete ${target}: not a project folder inside ${root}.`);
  }
  await fs.rm(target, { recursive: true, force: true });
}

export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return `${value.toFixed(value < 10 ? 1 : 0)} ${units[unit]}`;
}

function isInside(parent: string, child: string): boolean {
  const rel = path.relative(parent, path.resolve(child));
  return rel !== '' && !rel.startsWith('..') && !path.isAbsolute(rel);
}

async function realpath(target: string): Promise<string> {
  try {
    return await fs.realpath(target);
  } catch {
    return path.resolve(target);
  }
}

async function exists(target: string): Promise<boolean> {
  try {
    await fs.access(target);
    return true;
  } catch {
    return false;
  }
}
