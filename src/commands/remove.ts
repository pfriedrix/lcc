import path from 'node:path';
import pc from 'picocolors';
import {
  derivedDataRoot,
  forWorktree,
  formatBytes,
  listDerivedData,
  removeDerivedData,
  withSizes,
  type SizedDerivedData,
} from '../derived-data.js';
import {
  branchDisposition,
  deleteBranch,
  listWorktrees,
  removeWorktree,
  repoRoot,
  type BranchDisposition,
} from '../git.js';
import { confirmForceRemove, confirmRemoveWorktree, log, pickWorktree } from '../ui.js';

export interface RemoveOpts {
  force?: boolean;
  yes?: boolean;
  keepDerivedData?: boolean;
  keepBranch?: boolean;
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
    .filter((wt) => !wt.isMain);

  if (candidates.length === 0) {
    log.warn('No worktrees to remove (only the main one exists).');
    return;
  }

  const picked = await pickWorktree(candidates, 'Pick a worktree to remove:');

  // Match before removing: once the directory is gone the folders still resolve by
  // path, but the user needs to see what is about to go in the confirmation.
  const root = await derivedDataRoot();
  const derived = opts.keepDerivedData
    ? []
    : await forWorktree(await listDerivedData(root), picked.path);
  if (derived.length > 0) log.step(`Measuring Xcode build data (${derived.length})…`);
  const sized = await withSizes(derived);

  const branch =
    picked.branch && !opts.keepBranch ? await branchDisposition(repo, picked.branch) : null;

  if (!opts.yes && !(await confirmRemoveWorktree(picked, sized, branch))) {
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
  await purge(sized, root);
  await disposeBranch(repo, picked.branch, branch);
}

async function disposeBranch(
  repo: string,
  branchName: string | null,
  disposition: BranchDisposition | null,
): Promise<void> {
  if (!branchName) return; // Detached worktree — no branch to speak of.
  if (!disposition) {
    log.dim(`Branch left intact. Delete with: git branch -D ${branchName}`);
    return;
  }
  if (!disposition.safe) {
    const detail =
      disposition.reason === 'default-branch'
        ? 'is the default branch'
        : `has ${disposition.unmerged} unmerged commit${disposition.unmerged === 1 ? '' : 's'}`;
    log.warn(`Branch ${pc.cyan(branchName)} ${detail} — kept.`);
    log.dim(`  Delete anyway with: git branch -D ${branchName}`);
    return;
  }
  try {
    // A gone upstream means `-d` refuses even though the work is safely merged.
    await deleteBranch(repo, branchName, disposition.reason === 'upstream-gone');
    log.success(`Deleted branch ${pc.cyan(branchName)}`);
  } catch (err) {
    log.warn(`Could not delete branch ${branchName}: ${err instanceof Error ? err.message : String(err)}`);
    log.dim(`  Delete manually with: git branch -D ${branchName}`);
  }
}

async function purge(sized: SizedDerivedData[], root: string): Promise<void> {
  if (sized.length === 0) return;
  let reclaimed = 0;
  for (const dd of sized) {
    try {
      await removeDerivedData(dd, root);
      reclaimed += dd.size;
      log.success(`Removed build data ${pc.dim(dd.name)} ${pc.yellow(`(${dd.sizeLabel})`)}`);
    } catch (err) {
      log.warn(`Could not remove ${dd.name}: ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  if (reclaimed > 0) log.success(`Reclaimed ${pc.bold(formatBytes(reclaimed))}.`);
}
