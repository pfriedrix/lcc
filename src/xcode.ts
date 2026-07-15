import { promises as fs, type Dirent } from 'node:fs';
import path from 'node:path';
import { execa } from 'execa';

// Directories that never hold the project we want to open — skip them while
// searching so we don't descend into dependencies or build output.
const IGNORE_DIRS = new Set(['node_modules', 'Pods', 'Carthage', 'DerivedData', 'vendor']);

export type XcodeKind = 'workspace' | 'project' | 'package';

export interface XcodeTarget {
  path: string;
  kind: XcodeKind;
}

// Same depth wins by kind: a workspace references its projects, so prefer it.
const KIND_RANK: Record<XcodeKind, number> = { workspace: 0, project: 1, package: 2 };

const KIND_LABEL: Record<XcodeKind, string> = {
  workspace: 'workspace',
  project: 'project',
  package: 'Swift package',
};

export function describeXcodeTarget(target: XcodeTarget): string {
  return `${path.basename(target.path)} (${KIND_LABEL[target.kind]})`;
}

interface Candidate extends XcodeTarget {
  depth: number;
}

/**
 * Find the best Xcode entry point under `root`: an `.xcworkspace`, `.xcodeproj`,
 * or `Package.swift`. Prefers the shallowest match, then workspace > project >
 * package at the same depth. Returns null when nothing is found.
 */
export async function findXcodeTarget(root: string, maxDepth = 4): Promise<XcodeTarget | null> {
  const found: Candidate[] = [];
  await walk(root, 0, maxDepth, found);
  if (found.length === 0) return null;
  found.sort(
    (a, b) => a.depth - b.depth || KIND_RANK[a.kind] - KIND_RANK[b.kind] || a.path.length - b.path.length,
  );
  const { path: p, kind } = found[0]!;
  return { path: p, kind };
}

async function walk(dir: string, depth: number, maxDepth: number, out: Candidate[]): Promise<void> {
  let entries: Dirent[];
  try {
    entries = await fs.readdir(dir, { withFileTypes: true });
  } catch {
    return;
  }
  for (const entry of entries) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name.endsWith('.xcworkspace')) {
        out.push({ path: full, kind: 'workspace', depth });
        continue; // bundle — don't descend
      }
      if (entry.name.endsWith('.xcodeproj')) {
        out.push({ path: full, kind: 'project', depth });
        continue; // bundle — don't descend
      }
      if (entry.name.startsWith('.') || IGNORE_DIRS.has(entry.name)) continue;
      if (depth < maxDepth) await walk(full, depth + 1, maxDepth, out);
    } else if (entry.isFile() && entry.name === 'Package.swift') {
      out.push({ path: full, kind: 'package', depth });
    }
  }
}

/**
 * Launch Xcode on the given target. Uses macOS `open -a Xcode`, which returns as
 * soon as the app is handed the document (Xcode is a GUI app, not attached to
 * this process).
 */
export async function openXcode(target: string): Promise<void> {
  try {
    await execa('open', ['-a', 'Xcode', target]);
  } catch (err) {
    const detail = err instanceof Error ? err.message : String(err);
    throw new Error(
      `Failed to open Xcode. Is Xcode installed?\n` +
        `Tried: open -a Xcode ${target}\n${detail}`,
    );
  }
}
