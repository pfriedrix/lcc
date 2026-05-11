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
