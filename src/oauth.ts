import http from 'node:http';
import crypto from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import {
  AUTHORIZE_URL,
  DEFAULT_SCOPES,
  REDIRECT_PORT,
  REDIRECT_URI,
  TOKEN_URL,
} from './config.js';
import { getToken, setToken, type TokenRecord } from './keychain.js';

function base64url(buf: Buffer): string {
  return buf.toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

export interface PkcePair {
  verifier: string;
  challenge: string;
}

export function generatePkce(): PkcePair {
  const verifier = base64url(crypto.randomBytes(32));
  const challenge = base64url(crypto.createHash('sha256').update(verifier).digest());
  return { verifier, challenge };
}

export function generateState(): string {
  return base64url(crypto.randomBytes(16));
}

export function buildAuthorizeUrl(params: {
  clientId: string;
  state: string;
  challenge: string;
  scopes?: string[];
}): string {
  const url = new URL(AUTHORIZE_URL);
  url.searchParams.set('client_id', params.clientId);
  url.searchParams.set('redirect_uri', REDIRECT_URI);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', (params.scopes ?? DEFAULT_SCOPES).join(','));
  url.searchParams.set('state', params.state);
  url.searchParams.set('code_challenge', params.challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('prompt', 'consent');
  return url.toString();
}

export interface CallbackResult {
  code: string;
  state: string;
}

const SUCCESS_HTML = `<!doctype html><html><head><meta charset="utf-8"><title>lcc</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0a0a0a;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.box{text-align:center;padding:2rem 3rem;border:1px solid #2a2a2a;border-radius:12px;background:#111}
h1{margin:0 0 .5rem;font-size:1.4rem}p{margin:0;color:#999;font-size:.95rem}</style></head>
<body><div class="box"><h1>✓ Authentication successful</h1><p>You can return to your terminal.</p></div></body></html>`;

const ERROR_HTML = (msg: string) => `<!doctype html><html><head><meta charset="utf-8"><title>lcc</title>
<style>body{font-family:-apple-system,system-ui,sans-serif;background:#0a0a0a;color:#eee;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}
.box{text-align:center;padding:2rem 3rem;border:1px solid #4a1a1a;border-radius:12px;background:#1a0a0a}
h1{margin:0 0 .5rem;font-size:1.4rem;color:#ff6b6b}p{margin:0;color:#bbb;font-size:.95rem}</style></head>
<body><div class="box"><h1>Authentication failed</h1><p>${msg}</p></div></body></html>`;

export async function awaitCallback(expectedState: string, timeoutMs = 5 * 60_000): Promise<CallbackResult> {
  return await new Promise<CallbackResult>((resolve, reject) => {
    const server = http.createServer((req, res) => {
      if (!req.url) {
        res.writeHead(404).end();
        return;
      }
      const reqUrl = new URL(req.url, `http://localhost:${REDIRECT_PORT}`);
      if (reqUrl.pathname !== '/oauth/callback') {
        res.writeHead(404).end();
        return;
      }
      const code = reqUrl.searchParams.get('code');
      const state = reqUrl.searchParams.get('state');
      const error = reqUrl.searchParams.get('error');
      const errorDesc = reqUrl.searchParams.get('error_description');

      if (error) {
        res.writeHead(400, { 'content-type': 'text/html; charset=utf-8' }).end(ERROR_HTML(errorDesc ?? error));
        cleanup();
        reject(new Error(`Linear returned error: ${error}${errorDesc ? ` — ${errorDesc}` : ''}`));
        return;
      }
      if (!code || !state) {
        res.writeHead(400, { 'content-type': 'text/html; charset=utf-8' }).end(ERROR_HTML('Missing code or state.'));
        cleanup();
        reject(new Error('Callback missing code or state parameter'));
        return;
      }
      if (state !== expectedState) {
        res.writeHead(400, { 'content-type': 'text/html; charset=utf-8' }).end(ERROR_HTML('State mismatch — possible CSRF.'));
        cleanup();
        reject(new Error('OAuth state mismatch (possible CSRF)'));
        return;
      }
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(SUCCESS_HTML);
      cleanup();
      resolve({ code, state });
    });

    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error('Timed out waiting for browser authorization'));
    }, timeoutMs);

    function cleanup() {
      clearTimeout(timeout);
      // Allow the response to flush before tearing down
      setImmediate(() => server.close());
    }

    server.on('error', (err: NodeJS.ErrnoException) => {
      cleanup();
      if (err.code === 'EADDRINUSE') {
        reject(new Error(
          `Port ${REDIRECT_PORT} is already in use. Another lcc auth flow may be running — close it and retry.`,
        ));
        return;
      }
      reject(err);
    });

    server.listen(REDIRECT_PORT, '127.0.0.1');
  });
}

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string;
  token_type?: string;
}

async function postToken(body: Record<string, string>): Promise<TokenResponse> {
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded', accept: 'application/json' },
    body: new URLSearchParams(body).toString(),
  });
  const text = await res.text();
  if (!res.ok) {
    throw new Error(`Token endpoint ${res.status}: ${text}`);
  }
  return JSON.parse(text) as TokenResponse;
}

function toRecord(resp: TokenResponse): TokenRecord {
  const now = Math.floor(Date.now() / 1000);
  return {
    access_token: resp.access_token,
    refresh_token: resp.refresh_token,
    expires_at: resp.expires_in ? now + resp.expires_in - 60 : undefined,
    scope: resp.scope,
    token_type: resp.token_type,
  };
}

export async function exchangeCode(params: {
  clientId: string;
  code: string;
  verifier: string;
}): Promise<TokenRecord> {
  const resp = await postToken({
    grant_type: 'authorization_code',
    code: params.code,
    redirect_uri: REDIRECT_URI,
    client_id: params.clientId,
    code_verifier: params.verifier,
  });
  return toRecord(resp);
}

export async function refreshAccessToken(params: {
  clientId: string;
  refreshToken: string;
}): Promise<TokenRecord> {
  const resp = await postToken({
    grant_type: 'refresh_token',
    refresh_token: params.refreshToken,
    client_id: params.clientId,
  });
  const record = toRecord(resp);
  // Linear may omit refresh_token on refresh; preserve previous value
  if (!record.refresh_token) record.refresh_token = params.refreshToken;
  return record;
}

export async function ensureFreshToken(clientId?: string): Promise<string> {
  const token = getToken();
  if (!token) {
    throw new Error('Not authenticated. Run `lcc auth` first.');
  }
  if (token.is_pat) {
    return token.access_token;
  }
  const now = Math.floor(Date.now() / 1000);
  const isExpired = token.expires_at !== undefined && token.expires_at <= now;
  if (!isExpired) {
    return token.access_token;
  }
  if (!token.refresh_token) {
    throw new Error('Access token expired and no refresh token available. Run `lcc auth` again.');
  }
  if (!clientId) {
    throw new Error('Access token expired but no client_id configured for refresh. Run `lcc auth setup --client-id <id>` then `lcc auth`.');
  }
  const refreshed = await refreshAccessToken({ clientId, refreshToken: token.refresh_token });
  setToken(refreshed);
  return refreshed.access_token;
}

// Re-export for callers that want to retry after race
export { delay };
