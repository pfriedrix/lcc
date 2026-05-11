import path from 'node:path';
import pc from 'picocolors';
import { loadConfig } from '../config.js';
import { getClient } from '../linear.js';
import { fetchActiveIssues } from '../issues.js';
import { createWorktree, defaultBranch, renderWorktreePath, repoRoot } from '../git.js';
import { findEnvFiles, linkEnvFiles } from '../env.js';
import { launchClaude } from '../claude.js';
import { pickIssue, log } from '../ui.js';
import { getToken } from '../keychain.js';

export interface StartOpts {
  startTask?: boolean;
  all?: boolean;
}

export async function startCmd(opts: StartOpts): Promise<void> {
  if (!getToken()) {
    log.error('Not authenticated. Run `lcc auth` first.');
    process.exit(1);
  }

  const cfg = await loadConfig();
  const repo = await repoRoot();

  const fetchLabel = opts.all ? 'all states' : cfg.activeStates.join(', ');
  log.step(`Fetching Linear issues (${fetchLabel})...`);
  const client = await getClient();
  const { matched: issues, skippedByState, total } = await fetchActiveIssues(
    client,
    cfg.activeStates,
    { includeAll: opts.all },
  );

  if (!opts.all && skippedByState.size > 0) {
    const skippedTotal = [...skippedByState.values()].reduce((a, b) => a + b, 0);
    const breakdown = [...skippedByState.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([name, count]) => `${name} (${count})`)
      .join(', ');
    log.dim(
      `Filtered out ${skippedTotal} of ${total} assigned issues — not in activeStates: ${breakdown}`,
    );
    log.dim('To include them, edit ~/.config/lcc/config.json → activeStates, or run `lcc --all`.');
  }

  if (issues.length === 0) {
    log.warn(
      opts.all
        ? 'No active issues assigned to you (excluding Completed/Canceled).'
        : `No issues assigned to you in: ${cfg.activeStates.join(', ')}.`,
    );
    return;
  }

  const selected = await pickIssue(issues);
  log.dim(`Selected ${pc.cyan(selected.identifier)} — branch ${pc.bold(selected.branchName)}`);

  const worktreePath = renderWorktreePath(cfg.worktreeTemplate, {
    repoRoot: repo,
    branch: selected.branchName,
  });
  const base = await defaultBranch(repo);

  log.step(`Creating worktree at ${pc.dim(worktreePath)} (base: ${base})`);
  const wt = await createWorktree(repo, selected.branchName, worktreePath, base);
  log.success(`Worktree ${wt.created === 'new' ? 'created' : wt.created === 'reused-local' ? 'reused local branch' : 'tracking origin'}: ${wt.path}`);

  const envFiles = await findEnvFiles(repo, cfg.envPatterns, cfg.envExclude);
  if (envFiles.length === 0) {
    log.dim('No .env files found at repo root — skipping symlinks.');
  } else {
    const linked = await linkEnvFiles(envFiles, worktreePath);
    for (const r of linked) {
      const name = path.basename(r.target);
      if (r.status === 'linked') log.success(`Linked ${name}`);
      else log.dim(`Skipped ${name} (already exists in worktree)`);
    }
  }

  log.info('');
  log.info(`${pc.bold('Launching Claude Code')} in ${pc.dim(worktreePath)}`);
  log.dim(`Linear: ${selected.url}`);
  log.info('');

  const extraArgs: string[] = [];
  if (opts.startTask) {
    extraArgs.push('-p', `/linear-pfx-plugin:start-task ${selected.identifier}`);
  }
  const exitCode = await launchClaude(worktreePath, extraArgs);
  process.exit(exitCode);
}
