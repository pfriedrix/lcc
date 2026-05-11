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
}

export async function startCmd(opts: StartOpts): Promise<void> {
  if (!getToken()) {
    log.error('Not authenticated. Run `lcc auth` first.');
    process.exit(1);
  }

  const cfg = await loadConfig();
  const repo = await repoRoot();

  log.step(`Fetching Linear issues (${cfg.activeStates.join(', ')})...`);
  const client = await getClient();
  const issues = await fetchActiveIssues(client, cfg.activeStates);
  if (issues.length === 0) {
    log.warn(`No issues assigned to you in: ${cfg.activeStates.join(', ')}.`);
    log.dim('Promote something into one of those states in Linear, then re-run.');
    log.dim('To customize which states show up, edit ~/.config/lcc/config.json → activeStates.');
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
