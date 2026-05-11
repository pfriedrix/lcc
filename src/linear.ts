import { LinearClient } from '@linear/sdk';
import { ensureFreshToken } from './oauth.js';
import { loadConfig } from './config.js';

export async function getClient(): Promise<LinearClient> {
  const cfg = await loadConfig();
  const accessToken = await ensureFreshToken(cfg.clientId);
  return new LinearClient({ accessToken });
}
