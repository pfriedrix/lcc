import path from 'node:path';
import pc from 'picocolors';
import { launchClaude } from '../claude.js';
import { listWorktrees, repoRoot } from '../git.js';
import { log, pickWorktree, type WorktreeChoice } from '../ui.js';
import { describeXcodeTarget, findXcodeTarget, openXcode } from '../xcode.js';

const TARGETS = ['claude', 'xcode'] as const;
type Target = (typeof TARGETS)[number];

export interface OpenOpts {
  noResume?: boolean;
}

export async function openCmd(target: string | undefined, opts: OpenOpts): Promise<void> {
  const resolved = resolveTarget(target);

  const picked = await pickWorktreeInRepo(`Pick a worktree to open in ${resolved}:`);
  if (!picked) return;

  if (resolved === 'xcode') {
    await openInXcode(picked);
    return;
  }
  await openInClaude(picked, opts);
}

function resolveTarget(target: string | undefined): Target {
  if (!target) return 'claude';
  const normalized = target.toLowerCase();
  if ((TARGETS as readonly string[]).includes(normalized)) return normalized as Target;
  throw new Error(`Unknown open target '${target}'. Use one of: ${TARGETS.join(', ')}.`);
}

async function pickWorktreeInRepo(message: string): Promise<WorktreeChoice | null> {
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
    return null;
  }

  return await pickWorktree(candidates, message);
}

async function openInClaude(picked: WorktreeChoice, opts: OpenOpts): Promise<void> {
  const label = picked.branch ?? picked.head.slice(0, 8);
  const extraArgs = opts.noResume ? [] : ['--resume'];
  log.info(`${pc.bold('Launching Claude Code')} in ${pc.dim(picked.path)} ${pc.cyan(label)}`);
  const exitCode = await launchClaude(picked.path, extraArgs);
  process.exit(exitCode);
}

async function openInXcode(picked: WorktreeChoice): Promise<void> {
  const target = await findXcodeTarget(picked.path);
  if (!target) {
    log.warn(`No .xcworkspace, .xcodeproj, or Package.swift found in ${pc.dim(picked.path)}.`);
    return;
  }
  const label = picked.branch ?? picked.head.slice(0, 8);
  log.info(
    `${pc.bold('Opening Xcode')} — ${pc.cyan(describeXcodeTarget(target))} ${pc.dim(`(${label})`)}`,
  );
  await openXcode(target.path);
  log.success('Xcode launched.');
}
