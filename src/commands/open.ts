import path from 'node:path';
import pc from 'picocolors';
import { launchClaude } from '../claude.js';
import { listWorktrees, repoRoot } from '../git.js';
import { log, pickWorktree } from '../ui.js';

export interface OpenOpts {
  noResume?: boolean;
}

export async function openCmd(opts: OpenOpts): Promise<void> {
  const repo = await repoRoot();
  const entries = await listWorktrees(repo);
  const managedRoot = path.join(repo, '.lcc', 'worktrees');

  const candidates = entries
    .filter((wt) => !wt.isMain)
    .map((wt) => ({
      path: wt.path,
      branch: wt.branch,
      head: wt.head,
      locked: wt.locked,
      prunable: wt.prunable,
      managed: wt.path.startsWith(managedRoot + path.sep),
    }));

  if (candidates.length === 0) {
    log.warn('No worktrees to open (only the main one exists).');
    return;
  }

  const picked = await pickWorktree(candidates, 'Pick a worktree to open:');

  const label = picked.branch ?? picked.head.slice(0, 8);
  const extraArgs = opts.noResume ? [] : ['--resume'];
  log.info(`${pc.bold('Launching Claude Code')} in ${pc.dim(picked.path)} ${pc.cyan(label)}`);
  const exitCode = await launchClaude(picked.path, extraArgs);
  process.exit(exitCode);
}
