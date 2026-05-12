import path from 'node:path';
import pc from 'picocolors';
import { listWorktrees, removeWorktree, repoRoot } from '../git.js';
import { confirmForceRemove, confirmRemoveWorktree, log, pickWorktree } from '../ui.js';

export interface RemoveOpts {
  all?: boolean;
  force?: boolean;
  yes?: boolean;
}

export async function removeCmd(opts: RemoveOpts): Promise<void> {
  const repo = await repoRoot();
  const entries = await listWorktrees(repo);
  const managedRoot = path.join(repo, '.lcc', 'worktrees');

  const candidates = entries
    .map((wt) => ({
      path: wt.path,
      branch: wt.branch,
      head: wt.head,
      locked: wt.locked,
      prunable: wt.prunable,
      managed: wt.path.startsWith(managedRoot + path.sep),
      isMain: wt.isMain,
    }))
    .filter((wt) => !wt.isMain)
    .filter((wt) => opts.all || wt.managed);

  if (candidates.length === 0) {
    log.warn(
      opts.all
        ? 'No worktrees to remove (only the main one exists).'
        : 'No lcc-managed worktrees. Use `lcc remove --all` to pick any worktree.',
    );
    return;
  }

  const picked = await pickWorktree(candidates, 'Pick a worktree to remove:');
  if (!opts.yes && !(await confirmRemoveWorktree(picked))) {
    log.dim('Aborted.');
    return;
  }

  try {
    await removeWorktree(repo, picked.path, opts.force);
  } catch (err) {
    if (opts.force) throw err;
    const msg = err instanceof Error ? err.message : String(err);
    log.warn(msg.split('\n').slice(-3).join('\n'));
    if (!(await confirmForceRemove())) {
      log.dim('Aborted.');
      return;
    }
    await removeWorktree(repo, picked.path, true);
  }

  log.success(`Removed worktree ${pc.cyan(picked.branch ?? picked.head.slice(0, 8))}`);
  log.dim(`Branch left intact. Delete with: git branch -D ${picked.branch ?? '<branch>'}`);
}
