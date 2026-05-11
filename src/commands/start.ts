import path from 'node:path';
import pc from 'picocolors';
import { loadConfig } from '../config.js';
import { getClient } from '../linear.js';
import { fetchActiveIssues } from '../issues.js';
import {
  createWorktree,
  currentBranch,
  defaultBranch,
  listBranches,
  renderWorktreePath,
  repoRoot,
  resolveStrategy,
  rewriteBranchName,
} from '../git.js';
import { findEnvFiles, linkEnvFiles } from '../env.js';
import { launchClaude } from '../claude.js';
import { confirmUseCurrentBase, pickBaseBranch, pickIssue, log } from '../ui.js';
import { getToken } from '../keychain.js';

export interface StartOpts {
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
  const branch = rewriteBranchName(selected.branchName);
  log.dim(`Selected ${pc.cyan(selected.identifier)} — branch ${pc.bold(branch)}`);

  const worktreePath = renderWorktreePath(cfg.worktreeTemplate, {
    repoRoot: repo,
    branch,
  });

  const strategy = await resolveStrategy(repo, branch);
  let base: string;
  if (strategy === 'new') {
    const def = await defaultBranch(repo);
    const cur = await currentBranch(repo);
    if (!cur || cur === def) {
      base = def;
    } else if (await confirmUseCurrentBase(cur)) {
      base = cur;
    } else {
      const branches = await listBranches(repo);
      base = await pickBaseBranch(branches);
    }
    log.step(`Creating worktree at ${pc.dim(worktreePath)} (base: ${pc.bold(base)})`);
  } else {
    base = await defaultBranch(repo);
    log.step(`Creating worktree at ${pc.dim(worktreePath)}`);
  }

  const wt = await createWorktree(repo, branch, worktreePath, base);
  const summary =
    wt.created === 'new'
      ? `created from ${pc.bold(base)}`
      : wt.created === 'reused-local'
        ? 'reused local branch'
        : `tracking origin/${branch}`;
  log.success(`Worktree ${summary}: ${wt.path}`);

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
  if (cfg.startTaskCommand.trim()) {
    const cmd = cfg.startTaskCommand
      .replace(/\{identifier\}/g, selected.identifier)
      .replace(/\{branch\}/g, branch)
      .replace(/\{url\}/g, selected.url);
    extraArgs.push(cmd);
  }
  const exitCode = await launchClaude(worktreePath, extraArgs);
  process.exit(exitCode);
}
