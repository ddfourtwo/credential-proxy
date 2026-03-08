import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const execFileAsync = promisify(execFile);

// Locate the credential-proxy-resolve binary
function getResolverPath(): string | null {
  // 1. Inside .app bundle (when launched by the app)
  const appBundlePath = join(
    homedir(), 'Applications', 'Credential Proxy.app',
    'Contents', 'Resources', 'credential-proxy-resolve'
  );
  if (existsSync(appBundlePath)) return appBundlePath;

  // 2. Explicit env var override
  const envPath = process.env.CREDENTIAL_PROXY_RESOLVER_PATH;
  if (envPath && existsSync(envPath)) return envPath;

  return null;
}

const KEYCHAIN_SERVICE = 'com.credential-proxy.secrets';

let resolverPath: string | null | undefined;

export function isKeychainMode(): boolean {
  return process.env.CREDENTIAL_PROXY_KEYCHAIN === '1';
}

export async function storeInKeychain(name: string, value: string): Promise<void> {
  // Delete existing entry first (ignore errors if not found)
  try {
    await execFileAsync('security', [
      'delete-generic-password', '-s', KEYCHAIN_SERVICE, '-a', name
    ]);
  } catch { /* ignore not-found */ }

  await execFileAsync('security', [
    'add-generic-password',
    '-s', KEYCHAIN_SERVICE,
    '-a', name,
    '-w', value,
    '-l', `Credential Proxy: ${name}`,
  ]);
}

export async function deleteFromKeychain(name: string): Promise<void> {
  try {
    await execFileAsync('security', [
      'delete-generic-password', '-s', KEYCHAIN_SERVICE, '-a', name
    ]);
  } catch { /* ignore not-found */ }
}

export async function resolveFromKeychain(name: string): Promise<string | null> {
  if (resolverPath === undefined) {
    resolverPath = getResolverPath();
  }

  if (!resolverPath) {
    throw new Error(
      'Keychain mode enabled but credential-proxy-resolve binary not found. ' +
      'Is the Credential Proxy app installed?'
    );
  }

  try {
    const { stdout } = await execFileAsync(resolverPath, [name], {
      timeout: 5_000,
    });
    return stdout; // Value without trailing newline
  } catch (error) {
    const err = error as { code?: number; stderr?: string };
    if (err.code === 1) {
      // Exit code 1 = not found
      return null;
    }
    throw new Error(
      `Failed to resolve secret "${name}" from Keychain: ${err.stderr || 'unknown error'}`,
      { cause: error }
    );
  }
}
