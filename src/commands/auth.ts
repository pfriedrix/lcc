import open from 'open';
import pc from 'picocolors';
import { LinearClient } from '@linear/sdk';
import { configPath, loadConfig, saveConfig } from '../config.js';
import { clearToken, getToken, setToken } from '../keychain.js';
import {
  awaitCallback,
  buildAuthorizeUrl,
  ensureFreshToken,
  exchangeCode,
  generatePkce,
  generateState,
} from '../oauth.js';
import { log } from '../ui.js';

export interface AuthSetupOpts {
  clientId: string;
}

export async function authSetupCmd(opts: AuthSetupOpts): Promise<void> {
  await saveConfig({ clientId: opts.clientId });
  log.success(`Saved client_id to ${configPath()}`);
  log.dim(
    'In your Linear OAuth application (linear.app/settings/api/applications),\n' +
      '  make sure the redirect URI is set to:\n' +
      '    http://localhost:39126/oauth/callback',
  );
  log.dim('Next: run `lcc auth` to authorize.');
}

export interface AuthOpts {
  logout?: boolean;
  status?: boolean;
  token?: string;
}

export async function authCmd(opts: AuthOpts): Promise<void> {
  if (opts.logout) {
    clearToken();
    log.success('Logged out (token removed from keychain).');
    return;
  }
  if (opts.token) {
    await authWithPersonalToken(opts.token);
    return;
  }
  if (opts.status) {
    await authStatus();
    return;
  }
  await authLogin();
}

async function authLogin(): Promise<void> {
  const cfg = await loadConfig();
  const pkce = generatePkce();
  const state = generateState();
  const authorizeUrl = buildAuthorizeUrl({
    clientId: cfg.clientId,
    state,
    challenge: pkce.challenge,
  });

  log.step('Opening browser to authorize lcc with Linear...');
  log.dim(`If the browser doesn't open, visit:\n  ${authorizeUrl}`);

  const callback = awaitCallback(state);
  try {
    await open(authorizeUrl);
  } catch {
    // Non-fatal: user can use the printed URL.
  }

  const { code } = await callback;
  const tokenRecord = await exchangeCode({ clientId: cfg.clientId, code, verifier: pkce.verifier });
  setToken(tokenRecord);

  const client = new LinearClient({ accessToken: tokenRecord.access_token });
  const me = await client.viewer;
  log.success(`Authenticated as ${pc.bold(me.name)} ${pc.dim(`<${me.email}>`)}`);
  if (tokenRecord.expires_at) {
    const at = new Date(tokenRecord.expires_at * 1000).toLocaleString();
    log.dim(`Access token valid until ${at} (auto-refreshes).`);
  }
}

async function authWithPersonalToken(token: string): Promise<void> {
  setToken({ access_token: token, is_pat: true });
  const client = new LinearClient({ apiKey: token });
  try {
    const me = await client.viewer;
    log.success(`Stored personal API token. Authenticated as ${pc.bold(me.name)}.`);
  } catch (err) {
    clearToken();
    throw new Error(`Token validation failed: ${(err as Error).message}`);
  }
}

async function authStatus(): Promise<void> {
  const token = getToken();
  if (!token) {
    log.warn('Not authenticated. Run `lcc auth`.');
    return;
  }
  const cfg = await loadConfig();
  const accessToken = token.is_pat ? token.access_token : await ensureFreshToken(cfg.clientId);
  const client = token.is_pat ? new LinearClient({ apiKey: accessToken }) : new LinearClient({ accessToken });
  const me = await client.viewer;
  log.success(`Authenticated as ${pc.bold(me.name)} ${pc.dim(`<${me.email}>`)}`);
  if (token.is_pat) {
    log.dim('Using personal API token (no expiry, no refresh).');
  } else {
    log.dim(`Scopes: ${token.scope ?? '(unknown)'}`);
    if (token.expires_at) {
      log.dim(`Expires: ${new Date(token.expires_at * 1000).toLocaleString()}`);
    }
  }
}
