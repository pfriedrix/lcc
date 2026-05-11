import { input } from '@inquirer/prompts';
import pc from 'picocolors';
import { configPath, loadConfig, saveConfig } from '../config.js';
import { log } from '../ui.js';

export async function setupCmd(): Promise<void> {
  const cfg = await loadConfig();

  log.info(pc.bold('Configure lcc'));
  log.dim('Press Enter to keep current value. Ctrl-C to abort.');
  log.info('');

  const startTaskCommand = await input({
    message: 'Start-task command (placeholders: {identifier}, {branch}, {url}; empty = disabled):',
    default: cfg.startTaskCommand,
  });

  const worktreeTemplate = await input({
    message: 'Worktree path template:',
    default: cfg.worktreeTemplate,
  });

  const activeStatesRaw = await input({
    message: 'Active Linear states (comma-separated):',
    default: cfg.activeStates.join(', '),
  });
  const activeStates = activeStatesRaw
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);

  await saveConfig({ startTaskCommand, worktreeTemplate, activeStates });
  log.success(`Saved to ${configPath()}`);
}
