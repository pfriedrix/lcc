import { promises as fs } from 'node:fs';
import path from 'node:path';

function patternToRegex(glob: string): RegExp {
  // Top-level only — translate `.env` and `.env.*` style globs.
  const escaped = glob
    .replace(/[.+^${}()|[\]\\]/g, '\\$&')
    .replace(/\*/g, '[^/]*')
    .replace(/\?/g, '[^/]');
  return new RegExp(`^${escaped}$`);
}

export async function findEnvFiles(
  repoRoot: string,
  patterns: string[],
  exclude: string[] = [],
): Promise<string[]> {
  const matchers = patterns.map(patternToRegex);
  const excludeSet = new Set(exclude);
  const entries = await fs.readdir(repoRoot, { withFileTypes: true });
  const found: string[] = [];
  for (const entry of entries) {
    if (!entry.isFile() && !entry.isSymbolicLink()) continue;
    const name = entry.name;
    if (excludeSet.has(name)) continue;
    if (matchers.some((re) => re.test(name))) {
      found.push(path.join(repoRoot, name));
    }
  }
  return found.sort();
}

export interface LinkResult {
  source: string;
  target: string;
  status: 'linked' | 'skipped-exists';
}

export async function linkEnvFiles(files: string[], worktreePath: string): Promise<LinkResult[]> {
  const results: LinkResult[] = [];
  for (const source of files) {
    const name = path.basename(source);
    const target = path.join(worktreePath, name);
    try {
      await fs.lstat(target);
      results.push({ source, target, status: 'skipped-exists' });
      continue;
    } catch (err) {
      if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
    }
    await fs.symlink(source, target);
    results.push({ source, target, status: 'linked' });
  }
  return results;
}
