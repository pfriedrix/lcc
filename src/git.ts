import { execa } from 'execa';
import path from 'node:path';
import { promises as fs } from 'node:fs';

export async function repoRoot(cwd: string = process.cwd()): Promise<string> {
  try {
    const { stdout } = await execa('git', ['rev-parse', '--show-toplevel'], { cwd });
    return stdout.trim();
  } catch {
    throw new Error('Not inside a git repository. Run `lcc` from within your repo.');
  }
}

export async function defaultBranch(repo: string): Promise<string> {
  try {
    const { stdout } = await execa('git', ['symbolic-ref', '--short', 'refs/remotes/origin/HEAD'], { cwd: repo });
    return stdout.trim().replace(/^origin\//, '');
  } catch {
    // Fall through to local heuristics
  }
  for (const candidate of ['main', 'master']) {
    try {
      await execa('git', ['show-ref', '--verify', '--quiet', `refs/heads/${candidate}`], { cwd: repo });
      return candidate;
    } catch {
      // try next
    }
  }
  // Final fallback: current HEAD
  const { stdout } = await execa('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repo });
  return stdout.trim();
}

export async function currentBranch(repo: string): Promise<string | null> {
  const { stdout } = await execa('git', ['rev-parse', '--abbrev-ref', 'HEAD'], { cwd: repo });
  const branch = stdout.trim();
  return branch === 'HEAD' ? null : branch;
}

export async function listBranches(repo: string): Promise<string[]> {
  const { stdout } = await execa(
    'git',
    ['for-each-ref', '--format=%(refname:short)', 'refs/heads/', 'refs/remotes/'],
    { cwd: repo },
  );
  const seen = new Set<string>();
  for (const line of stdout.split('\n')) {
    const ref = line.trim();
    if (!ref || ref.endsWith('/HEAD')) continue;
    seen.add(ref.startsWith('origin/') ? ref.slice('origin/'.length) : ref);
  }
  return [...seen].sort();
}

export function rewriteBranchName(linearBranch: string, prefix = 'feature'): string {
  const slash = linearBranch.indexOf('/');
  const tail = slash >= 0 ? linearBranch.slice(slash + 1) : linearBranch;
  return `${prefix}/${tail}`;
}

export async function resolveStrategy(
  repo: string,
  branch: string,
): Promise<WorktreeResult['created']> {
  if (await localBranchExists(repo, branch)) return 'reused-local';
  if (await remoteBranchExists(repo, branch)) return 'tracking-remote';
  return 'new';
}

async function localBranchExists(repo: string, branch: string): Promise<boolean> {
  try {
    await execa('git', ['show-ref', '--verify', '--quiet', `refs/heads/${branch}`], { cwd: repo });
    return true;
  } catch {
    return false;
  }
}

async function remoteBranchExists(repo: string, branch: string): Promise<boolean> {
  try {
    await execa('git', ['show-ref', '--verify', '--quiet', `refs/remotes/origin/${branch}`], { cwd: repo });
    return true;
  } catch {
    return false;
  }
}

async function pathExists(p: string): Promise<boolean> {
  try {
    await fs.access(p);
    return true;
  } catch {
    return false;
  }
}

export interface WorktreeResult {
  path: string;
  branch: string;
  created: 'reused-local' | 'tracking-remote' | 'new';
}

export async function createWorktree(
  repo: string,
  branch: string,
  worktreePath: string,
  base: string,
): Promise<WorktreeResult> {
  if (await pathExists(worktreePath)) {
    throw new Error(
      `Worktree path already exists: ${worktreePath}\n` +
        `Remove it first with: git worktree remove ${worktreePath}  (or delete the directory).`,
    );
  }
  await fs.mkdir(path.dirname(worktreePath), { recursive: true });
  await ensureLocalIgnore(repo, worktreePath);

  if (await localBranchExists(repo, branch)) {
    await execa('git', ['worktree', 'add', worktreePath, branch], { cwd: repo, stdio: 'inherit' });
    return { path: worktreePath, branch, created: 'reused-local' };
  }
  if (await remoteBranchExists(repo, branch)) {
    await execa('git', ['worktree', 'add', '--track', '-b', branch, worktreePath, `origin/${branch}`], {
      cwd: repo,
      stdio: 'inherit',
    });
    return { path: worktreePath, branch, created: 'tracking-remote' };
  }
  await execa('git', ['worktree', 'add', '-b', branch, worktreePath, base], { cwd: repo, stdio: 'inherit' });
  return { path: worktreePath, branch, created: 'new' };
}

async function ensureLocalIgnore(repo: string, worktreePath: string): Promise<void> {
  const rel = path.relative(repo, worktreePath);
  if (rel.startsWith('..') || path.isAbsolute(rel)) return;
  const topDir = rel.split(path.sep)[0];
  if (!topDir) return;
  const entry = `/${topDir}/`;
  const excludeFile = path.join(repo, '.git', 'info', 'exclude');
  let current = '';
  try {
    current = await fs.readFile(excludeFile, 'utf8');
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
  }
  const lines = current.split('\n').map((l) => l.trim());
  if (lines.includes(entry) || lines.includes(topDir) || lines.includes(`${topDir}/`)) return;
  const next = (current.endsWith('\n') || current === '' ? current : current + '\n') + entry + '\n';
  await fs.mkdir(path.dirname(excludeFile), { recursive: true });
  await fs.writeFile(excludeFile, next, 'utf8');
}

export function renderWorktreePath(
  template: string,
  ctx: { repoRoot: string; branch: string },
): string {
  const repoName = path.basename(ctx.repoRoot);
  const repoParent = path.dirname(ctx.repoRoot);
  const branchLeaf = ctx.branch.split('/').pop() ?? ctx.branch;
  return template
    .replace(/\{repoRoot\}/g, ctx.repoRoot)
    .replace(/\{repoParent\}/g, repoParent)
    .replace(/\{repoName\}/g, repoName)
    .replace(/\{branch\}/g, ctx.branch)
    .replace(/\{branchLeaf\}/g, branchLeaf);
}
