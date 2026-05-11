import { confirm, search } from '@inquirer/prompts';
import pc from 'picocolors';
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
