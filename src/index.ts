import { Command } from 'commander';
import { authCmd, authSetupCmd } from './commands/auth.js';
import { listCmd } from './commands/list.js';
import { openCmd } from './commands/open.js';
import { removeCmd } from './commands/remove.js';
import { setupCmd } from './commands/setup.js';
import { startCmd } from './commands/start.js';
import { log } from './ui.js';

const program = new Command();

program
  .name('lcc')
  .description('Pick a Linear issue → git worktree + .env symlinks + Claude Code')
  .version('0.1.0');

const auth = program
  .command('auth')
  .description('Authenticate with Linear (OAuth browser flow)')
  .option('--logout', 'remove stored token')
  .option('--status', 'show current authentication state')
  .option('--token <pat>', 'headless fallback: store a personal API token directly')
  .action((opts) => run(() => authCmd(opts)));

auth
  .command('setup')
  .description('Configure OAuth client_id (one-time)')
  .requiredOption('--client-id <id>', 'Linear OAuth application client_id')
  .action((opts) => run(() => authSetupCmd(opts)));

program
  .command('setup')
  .description('Interactively configure lcc (startTaskCommand, worktreeTemplate, activeStates)')
  .action(() => run(() => setupCmd()));

program
  .command('start', { isDefault: true })
  .description('Pick an active Linear issue and bootstrap a worktree + Claude session')
  .option('--all', 'show all assigned issues regardless of activeStates filter')
  .action((opts) => run(() => startCmd(opts)));

program
  .command('list')
  .alias('ls')
  .description('List worktrees in the current repo')
  .action(() => run(() => listCmd()));

program
  .command('open [target]')
  .alias('o')
  .description('Pick a worktree and open it — Claude Code (default) or Xcode (`open xcode`)')
  .option('--no-resume', 'launch Claude without --resume (fresh session)')
  .action((target, opts) => run(() => openCmd(target, opts)));

program
  .command('remove')
  .alias('rm')
  .description('Pick a worktree and remove it (git worktree remove)')
  .option('-f, --force', 'force remove even with uncommitted changes')
  .option('-y, --yes', 'skip the confirmation prompt')
  .action((opts) => run(() => removeCmd(opts)));

function run(fn: () => Promise<unknown>): void {
  fn().catch((err: unknown) => {
    // Ctrl-C in an inquirer picker — exit silently with conventional SIGINT code
    if (err instanceof Error && err.name === 'ExitPromptError') {
      process.exit(130);
    }
    if (err instanceof Error) {
      log.error(err.message);
    } else {
      log.error(String(err));
    }
    process.exit(1);
  });
}

program.parseAsync();
