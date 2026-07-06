import { join } from 'node:path';
import { homedir } from 'node:os';

const DEFAULT_APP_PORT = 11111;

/**
 * Detect whether we're running from inside the Credential Proxy.app bundle.
 */
export function isAppBundle(): boolean {
  return (
    import.meta.url?.includes('/Credential Proxy.app/') ?? false
  ) || (
    process.argv[1]?.includes('/Credential Proxy.app/') ?? false
  );
}

/**
 * Return the explicit or inferred app server URL.
 * Does *not* verify the server is actually reachable.
 */
export function getConfiguredAppUrl(): string | undefined {
  return process.env.CREDENTIAL_PROXY_APP_URL ||
    (isAppBundle() ? `http://127.0.0.1:${DEFAULT_APP_PORT}` : undefined);
}

let _appUrl: string | undefined | null = null;

/**
 * Detect the Credential Proxy app HTTP server.
 * Probes localhost:11111/health when no explicit URL is configured.
 * Result is cached for the process lifetime.
 */
export async function detectAppUrl(): Promise<string | undefined> {
  if (_appUrl !== null) return _appUrl;

  const configured = getConfiguredAppUrl();
  if (configured) {
    _appUrl = configured;
    return _appUrl;
  }

  try {
    const res = await fetch(`http://127.0.0.1:${DEFAULT_APP_PORT}/health`, {
      signal: AbortSignal.timeout(2000),
    });
    if (res.status === 200) {
      const data = await res.json() as { status?: string };
      if (data.status === 'ok') {
        _appUrl = `http://127.0.0.1:${DEFAULT_APP_PORT}`;
        return _appUrl;
      }
    }
  } catch {
    // Not running
  }

  _appUrl = undefined;
  return _appUrl;
}

/**
 * Reset cached app URL (useful in tests).
 */
export function resetAppUrlCache(): void {
  _appUrl = null;
}

/**
 * Read the daemon management token from the well-known file path.
 */
export async function readDaemonToken(): Promise<string | undefined> {
  try {
    const { readFile } = await import('node:fs/promises');
    const tokenPath = join(
      homedir(),
      'Library/Application Support/credential-proxy/daemon.mgmt-token'
    );
    const token = await readFile(tokenPath, 'utf8');
    return token.trim();
  } catch {
    return undefined;
  }
}

/**
 * Get the effective management token:
 * 1. CREDENTIAL_PROXY_MGMT_TOKEN env var
 * 2. Daemon token file
 */
export async function getMgmtToken(): Promise<string | undefined> {
  return process.env.CREDENTIAL_PROXY_MGMT_TOKEN || (await readDaemonToken());
}

/**
 * Relay a request to the app HTTP server.
 */
export async function relayToApp(
  endpoint: string,
  method: string,
  body?: unknown,
  queryParams?: Record<string, string>,
  timeoutMs?: number,
  mgmtToken?: string
): Promise<unknown> {
  const appUrl = await detectAppUrl();
  if (!appUrl) {
    throw new Error('Credential Proxy app server is not running');
  }

  const url = new URL(endpoint, appUrl);
  if (queryParams) {
    for (const [k, v] of Object.entries(queryParams)) {
      if (v !== undefined) url.searchParams.set(k, v);
    }
  }

  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
  };
  if (mgmtToken) {
    headers['Authorization'] = `Bearer ${mgmtToken}`;
  }

  const opts: RequestInit = {
    method,
    headers,
  };
  if (body && method !== 'GET') {
    opts.body = JSON.stringify(body);
  }
  if (timeoutMs) {
    opts.signal = AbortSignal.timeout(timeoutMs);
  }

  const maxRetries = 3;
  const baseDelay = 500;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const res = await fetch(url.toString(), opts);
      const text = await res.text();
      let data: unknown;
      try {
        data = JSON.parse(text);
      } catch {
        throw new Error(`App server returned ${res.status}: ${text.slice(0, 200)}`);
      }
      if (res.status >= 400) {
        const err = data as { error?: string; message?: string };
        throw new Error(err.message || err.error || `HTTP ${res.status}`);
      }
      return data;
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      const isConnectionError = msg.includes('fetch failed') || msg.includes('ECONNREFUSED');
      if (!isConnectionError || attempt === maxRetries) {
        throw error;
      }
      await new Promise(resolve => setTimeout(resolve, baseDelay * (attempt + 1)));
    }
  }

  throw new Error('Unreachable');
}
