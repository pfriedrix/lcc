import path from 'node:path';
import pc from 'picocolors';
import { listWorktrees, repoRoot } from '../git.js';
import { log } from '../ui.js';

export async function listCmd(): Promise<void> {
  const repo = await repoRoot();
  const entries = await listWorktrees(repo);
  const managedRoot = path.join(repo, '.lcc', 'worktrees');

  const rows = entries
    .map((wt) => ({
      ...wt,
      managed: wt.path.startsWith(managedRoot + path.sep),
    }))
    .filter((wt) => !wt.isMain);

  if (rows.length === 0) {
    log.dim('No worktrees.');
    return;
  }

  const widthBranch = Math.max(...rows.map((r) => (r.branch ?? r.head.slice(0, 8)).length), 6);
  for (const wt of rows) {
    const label = wt.branch ?? `${wt.head.slice(0, 8)} (detached)`;
    const flags: string[] = [];
    if (wt.locked) flags.push(pc.yellow('locked'));
    if (wt.prunable) flags.push(pc.red('prunable'));
    if (wt.managed) flags.push(pc.dim('lcc'));
    const tail = flags.length ? '  ' + flags.join(' ') : '';
    console.log(`${pc.cyan(label.padEnd(widthBranch))}  ${pc.dim(wt.path)}${tail}`);
  }
}
