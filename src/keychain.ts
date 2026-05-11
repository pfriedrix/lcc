import { Entry } from '@napi-rs/keyring';

export interface TokenRecord {
  access_token: string;
  refresh_token?: string;
  expires_at?: number;
  scope?: string;
  token_type?: string;
  is_pat?: boolean;
}

const SERVICE = 'lcc';
const ACCOUNT = 'linear-token';

function entry(): Entry {
  return new Entry(SERVICE, ACCOUNT);
}

export function getToken(): TokenRecord | null {
  try {
    const raw = entry().getPassword();
    if (!raw) return null;
    return JSON.parse(raw) as TokenRecord;
  } catch {
    return null;
  }
}

export function setToken(token: TokenRecord): void {
  entry().setPassword(JSON.stringify(token));
}

export function clearToken(): void {
  try {
    entry().deletePassword();
  } catch {
    // entry may not exist — treat as already cleared
  }
}
