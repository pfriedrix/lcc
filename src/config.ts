import { promises as fs } from 'node:fs';
import path from 'node:path';
import os from 'node:os';

export interface Config {
  clientId?: string;
  worktreeTemplate?: string;
  envPatterns?: string[];
  envExclude?: string[];
  activeStates?: string[];
  startTaskCommand?: string;
}

const CONFIG_DIR = path.join(os.homedir(), '.config', 'lcc');
const CONFIG_FILE = path.join(CONFIG_DIR, 'config.json');

export const REDIRECT_PORT = 39126;
export const REDIRECT_URI = `http://localhost:${REDIRECT_PORT}/oauth/callback`;
export const AUTHORIZE_URL = 'https://linear.app/oauth/authorize';
export const TOKEN_URL = 'https://api.linear.app/oauth/token';
export const DEFAULT_SCOPES = ['read', 'write'];

// Public OAuth client for the `lcc` tool. client_id is non-secret by OAuth design;
// PKCE protects the flow without requiring a client_secret. Override with
// LCC_CLIENT_ID env var or `lcc auth setup --client-id <id>` for forks / self-hosted.
export const DEFAULT_CLIENT_ID = '6bf6dd7b761b5ce6539cf5a9ed99b4fb';

const DEFAULTS: Required<Omit<Config, 'clientId'>> = {
  worktreeTemplate: '{repoRoot}/.lcc/worktrees/{branchLeaf}',
  envPatterns: ['.env', '.env.*'],
  envExclude: ['.env.example', '.env.sample', '.env.template'],
  activeStates: ['Todo', 'In Progress'],
  startTaskCommand: '',
};

export type ResolvedConfig = Required<typeof DEFAULTS> & { clientId: string };

export async function loadConfig(): Promise<ResolvedConfig> {
  let stored: Config = {};
  try {
    const raw = await fs.readFile(CONFIG_FILE, 'utf8');
    stored = JSON.parse(raw) as Config;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
  }
  return {
    worktreeTemplate: stored.worktreeTemplate ?? DEFAULTS.worktreeTemplate,
    envPatterns: stored.envPatterns ?? DEFAULTS.envPatterns,
    envExclude: stored.envExclude ?? DEFAULTS.envExclude,
    activeStates: stored.activeStates ?? DEFAULTS.activeStates,
    startTaskCommand: stored.startTaskCommand ?? DEFAULTS.startTaskCommand,
    clientId: process.env.LCC_CLIENT_ID ?? stored.clientId ?? DEFAULT_CLIENT_ID,
  };
}

export async function saveConfig(patch: Partial<Config>): Promise<void> {
  await fs.mkdir(CONFIG_DIR, { recursive: true });
  let existing: Config = {};
  try {
    existing = JSON.parse(await fs.readFile(CONFIG_FILE, 'utf8')) as Config;
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code !== 'ENOENT') throw err;
  }
  const merged = { ...existing, ...patch };
  await fs.writeFile(CONFIG_FILE, JSON.stringify(merged, null, 2) + '\n', 'utf8');
}

export function configPath(): string {
  return CONFIG_FILE;
}
