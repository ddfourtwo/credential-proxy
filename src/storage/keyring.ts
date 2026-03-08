import { readFile, writeFile, mkdir, chmod } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';
import { generateMasterKey } from './encryption.js';

const SERVICE_NAME = 'credential-proxy';
const ACCOUNT_NAME = 'encryption-key';

function getDataDir(): string {
  // Explicit override takes highest priority
  const explicit = process.env.CREDENTIAL_PROXY_DATA_DIR;
  if (explicit) return explicit;

  // Instance-derived path (CREDENTIAL_PROXY_INSTANCE preferred, CLAUDETMUX_INSTANCE as fallback)
  const instance = process.env.CREDENTIAL_PROXY_INSTANCE ?? process.env.CLAUDETMUX_INSTANCE;
  if (instance) {
    return join(homedir(), '.local', 'share', `credential-proxy-${instance}`);
  }

  // Default
  return join(homedir(), '.local', 'share', 'credential-proxy');
}

function getKeyFilePath(): string {
  return join(getDataDir(), 'secrets.key');
}

async function ensureDataDir(): Promise<void> {
  const dataDir = getDataDir();
  if (!existsSync(dataDir)) {
    await mkdir(dataDir, { recursive: true, mode: 0o700 });
  }
}

// Try to use keytar if available, fall back to file-based storage
// NOTE: Disabled keytar by default for consistency - keychain access is unreliable
// over SSH and causes encryption key mismatches. Set CREDENTIAL_PROXY_USE_KEYCHAIN=1 to enable.
async function tryKeytar(): Promise<typeof import('keytar') | null> {
  // Skip keytar unless explicitly enabled - file-based storage is more reliable
  if (process.env.CREDENTIAL_PROXY_USE_KEYCHAIN !== '1') {
    return null;
  }
  
  try {
    const keytarModule = await import('keytar');
    // Handle both ESM default export and CommonJS interop
    const keytar = (keytarModule.default ?? keytarModule) as typeof import('keytar');
    // Verify the functions exist before returning
    if (typeof keytar.setPassword !== 'function' || typeof keytar.getPassword !== 'function') {
      console.error('[credential-proxy] keytar loaded but functions not available, falling back to file storage');
      return null;
    }
    return keytar;
  } catch {
    // Silently fall back to file-based storage
    return null;
  }
}

export async function getMasterKey(): Promise<string> {
  const keytar = await tryKeytar();

  if (keytar) {
    try {
      // Try keyring first
      const key = await keytar.getPassword(SERVICE_NAME, ACCOUNT_NAME);
      if (key) {
        return key;
      }

      // Generate new key and store in keyring
      const newKey = generateMasterKey();
      await keytar.setPassword(SERVICE_NAME, ACCOUNT_NAME, newKey);
      return newKey;
    } catch {
      // Keytar failed (e.g., no keychain access over SSH) - fall back to file
      console.error('[credential-proxy] Keychain access failed, using file-based key storage');
    }
  }

  // Fall back to file-based key
  return getOrCreateFileKey();
}

async function getOrCreateFileKey(): Promise<string> {
  await ensureDataDir();
  const keyPath = getKeyFilePath();

  if (existsSync(keyPath)) {
    const key = await readFile(keyPath, 'utf8');
    return key.trim();
  }

  // Generate and save new key
  const newKey = generateMasterKey();
  await writeFile(keyPath, newKey, { mode: 0o600 });
  await chmod(keyPath, 0o600); // Ensure permissions
  return newKey;
}

export async function deleteMasterKey(): Promise<void> {
  const keytar = await tryKeytar();

  if (keytar) {
    await keytar.deletePassword(SERVICE_NAME, ACCOUNT_NAME);
  }

  // Also remove file-based key if exists
  const keyPath = getKeyFilePath();
  if (existsSync(keyPath)) {
    const { unlink } = await import('node:fs/promises');
    await unlink(keyPath);
  }
}

export function getSecretsFilePath(): string {
  return join(getDataDir(), 'secrets.json');
}

export function getAuditLogPath(): string {
  return join(getDataDir(), 'logs', 'secrets-audit.log');
}

export { ensureDataDir, getDataDir };
