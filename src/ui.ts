import { checkbox, confirm, search } from '@inquirer/prompts';
import pc from 'picocolors';
import type { SizedDerivedData } from './derived-data.js';
import type { BranchDisposition } from './git.js';
import type { ActiveIssue } from './issues.js';

const PRIORITY_LABEL: Record<number, string> = {
  0: '   ',
  1: 'U  ',
  2: 'H  ',
  3: 'M  ',
  4: 'L  ',
};

function formatChoice(issue: ActiveIssue): string {
  const id = pc.cyan(issue.identifier.padEnd(8));
  const state = issue.stateType === 'started' ? pc.green(issue.stateName) : pc.yellow(issue.stateName);
  const prio = pc.dim(PRIORITY_LABEL[issue.priority] ?? '   ');
  return `${id} ${prio} ${state.padEnd(20)} ${issue.title}`;
}

export async function pickIssue(issues: ActiveIssue[]): Promise<ActiveIssue> {
  const choices = issues.map((issue) => ({
    name: formatChoice(issue),
    value: issue,
    description: `${issue.branchName} — ${issue.url}`,
  }));
  const pageSize = Math.max(7, Math.min(30, (process.stdout.rows ?? 24) - 6));
  return await search<ActiveIssue>({
    message: `Pick a Linear issue (${issues.length} total, type to search):`,
    pageSize,
    source: (term) => {
      if (!term) return choices;
      const tokens = term.toLowerCase().split(/\s+/).filter(Boolean);
      return choices.filter((c) => {
        const haystack = [
          c.value.identifier,
          c.value.title,
          c.value.branchName,
          c.value.stateName,
          c.value.assigneeName ?? '',
          c.value.teamKey ?? '',
        ]
          .join(' ')
          .toLowerCase();
        return tokens.every((t) => haystack.includes(t));
      });
    },
  });
}

export async function confirmUseCurrentBase(current: string): Promise<boolean> {
  return await confirm({
    message: `Base new branch on current '${pc.cyan(current)}'?`,
    default: true,
  });
}

export interface WorktreeChoice {
  path: string;
  branch: string | null;
  head: string;
  locked: boolean;
  prunable: boolean;
  managed: boolean;
}

export async function pickWorktree(entries: WorktreeChoice[], message: string): Promise<WorktreeChoice> {
  const choices = entries.map((wt) => {
    const branch = wt.branch ? pc.cyan(wt.branch) : pc.dim(wt.head.slice(0, 8) + ' (detached)');
    const flags: string[] = [];
    if (wt.locked) flags.push(pc.yellow('locked'));
    if (wt.prunable) flags.push(pc.red('prunable'));
    if (wt.managed) flags.push(pc.dim('lcc'));
    const tail = flags.length ? '  ' + flags.join(' ') : '';
    return {
      name: `${branch.padEnd(40)}  ${pc.dim(wt.path)}${tail}`,
      value: wt,
      description: wt.path,
    };
  });
  const pageSize = Math.max(7, Math.min(30, (process.stdout.rows ?? 24) - 6));
  return await search<WorktreeChoice>({
    message,
    pageSize,
    source: (term) => {
      if (!term) return choices;
      const t = term.toLowerCase();
      return choices.filter((c) =>
        (c.value.branch ?? '').toLowerCase().includes(t) || c.value.path.toLowerCase().includes(t),
      );
    },
  });
}

export async function confirmRemoveWorktree(
  wt: WorktreeChoice,
  derived: SizedDerivedData[],
  branch: BranchDisposition | null,
): Promise<boolean> {
  const label = wt.branch ?? wt.head.slice(0, 8);
  const lines = [`    ${pc.dim('worktree  ')} ${wt.path}`];
  for (const dd of derived) {
    lines.push(`    ${pc.dim('build data')} ${dd.name}  ${pc.yellow(`(${dd.sizeLabel})`)}`);
  }
  if (branch) {
    lines.push(`    ${pc.dim('branch    ')} ${branch.branch}  ${describeDisposition(branch)}`);
  }
  return await confirm({
    message: `Remove worktree ${pc.cyan(label)}?\n${lines.join('\n')}\n`,
    default: false,
  });
}

function describeDisposition(branch: BranchDisposition): string {
  switch (branch.reason) {
    case 'merged':
      return pc.dim('(merged — will be deleted)');
    case 'upstream-gone':
      return pc.dim('(pushed, remote branch gone — will be deleted)');
    case 'default-branch':
      return pc.yellow('(default branch — kept)');
    case 'unmerged':
      return pc.yellow(
        `(${branch.unmerged} unmerged commit${branch.unmerged === 1 ? '' : 's'} — kept)`,
      );
  }
}

export async function pickOrphans(orphans: SizedDerivedData[]): Promise<SizedDerivedData[]> {
  const width = Math.max(...orphans.map((o) => o.sizeLabel.length));
  const pageSize = Math.max(7, Math.min(30, (process.stdout.rows ?? 24) - 6));
  return await checkbox<SizedDerivedData>({
    message: 'Select build data to delete (space toggles, enter confirms):',
    pageSize,
    choices: orphans.map((o) => ({
      name: `${pc.yellow(o.sizeLabel.padStart(width))}  ${o.name}  ${pc.dim(o.workspacePath)}`,
      value: o,
      checked: true,
    })),
  });
}

export async function confirmForceRemove(): Promise<boolean> {
  return await confirm({
    message: pc.yellow('Worktree has uncommitted changes or is locked. Force remove?'),
    default: false,
  });
}

export async function pickBaseBranch(branches: string[]): Promise<string> {
  const choices = branches.map((b) => ({ name: b, value: b }));
  const pageSize = Math.max(7, Math.min(30, (process.stdout.rows ?? 24) - 6));
  return await search<string>({
    message: 'Pick base branch:',
    pageSize,
    source: (term) => {
      if (!term) return choices;
      const t = term.toLowerCase();
      return choices.filter((c) => c.value.toLowerCase().includes(t));
    },
  });
}

export const log = {
  info: (msg: string) => console.log(msg),
  success: (msg: string) => console.log(pc.green('✓') + ' ' + msg),
  warn: (msg: string) => console.log(pc.yellow('!') + ' ' + msg),
  error: (msg: string) => console.error(pc.red('✗') + ' ' + msg),
  dim: (msg: string) => console.log(pc.dim(msg)),
  step: (msg: string) => console.log(pc.cyan('›') + ' ' + msg),
};
