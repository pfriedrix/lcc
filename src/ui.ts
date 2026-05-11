import { search } from '@inquirer/prompts';
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
  return await search<ActiveIssue>({
    message: 'Pick a Linear issue:',
    source: (term) => {
      if (!term) return choices;
      const q = term.toLowerCase();
      return choices.filter(
        (c) =>
          c.value.identifier.toLowerCase().includes(q) ||
          c.value.title.toLowerCase().includes(q) ||
          c.value.branchName.toLowerCase().includes(q),
      );
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
