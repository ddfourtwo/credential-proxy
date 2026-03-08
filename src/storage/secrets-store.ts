import { readFile, writeFile, chmod, mkdir } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { encrypt, decrypt } from './encryption.js';
import { getMasterKey, getSecretsFilePath, ensureDataDir } from './keyring.js';
import { isKeychainMode, resolveFromKeychain, storeInKeychain, deleteFromKeychain } from './keychain-resolver.js';
import { 
  SecretsStore, 
  SecretMetadata, 
  SecretInfo, 
  SecretPlacement,
  LegacySecretMetadata,
  CURRENT_VERSION 
} from './types.js';

const execFileAsync = promisify(execFile);

// Cache for 1Password values (short TTL to balance security and performance)
const opCache = new Map<string, { value: string; expiresAt: number }>();
const OP_CACHE_TTL_MS = 60_000; // 1 minute

async function loadStore(): Promise<SecretsStore> {
  const filePath = getSecretsFilePath();

  if (!existsSync(filePath)) {
    return { version: CURRENT_VERSION, secrets: {} };
  }

  const content = await readFile(filePath, 'utf8');
  const store = JSON.parse(content) as SecretsStore;
  
  // Migrate from v1 to v2 if needed
  if (store.version === 1) {
    return migrateV1ToV2(store);
  }
  
  return store;
}

function migrateV1ToV2(store: SecretsStore): SecretsStore {
  const migrated: SecretsStore = {
    version: CURRENT_VERSION,
    secrets: {}
  };
  
  for (const [name, meta] of Object.entries(store.secrets)) {
    const legacy = meta as unknown as LegacySecretMetadata;
    migrated.secrets[name] = {
      source: { type: 'encrypted', encryptedValue: legacy.encryptedValue },
      allowedDomains: legacy.allowedDomains,
      allowedPlacements: legacy.allowedPlacements,
      createdAt: legacy.createdAt,
      lastUsed: legacy.lastUsed,
      usageCount: legacy.usageCount
    };
  }
  
  return migrated;
}

async function saveStore(store: SecretsStore): Promise<void> {
  await ensureDataDir();
  const filePath = getSecretsFilePath();

  const dir = dirname(filePath);
  if (!existsSync(dir)) {
    await mkdir(dir, { recursive: true, mode: 0o700 });
  }

  await writeFile(filePath, JSON.stringify(store, null, 2), { mode: 0o600 });
  await chmod(filePath, 0o600);
}

export async function addSecret(
  name: string,
  value: string,
  allowedDomains: string[],
  allowedPlacements: SecretPlacement[] = ['header'],
  allowedCommands?: string[]
): Promise<{ created: boolean; overwritten: boolean }> {
  validateSecretName(name);
  validateDomains(allowedDomains);

  const store = await loadStore();
  const overwritten = name in store.secrets;

  if (isKeychainMode()) {
    // Store value in macOS Keychain, metadata in file
    await storeInKeychain(name, value);
    store.secrets[name] = {
      source: { type: 'encrypted', encryptedValue: '__keychain__' },
      allowedDomains,
      allowedPlacements,
      allowedCommands,
      createdAt: new Date().toISOString(),
      lastUsed: null,
      usageCount: 0
    };
  } else {
    const masterKey = await getMasterKey();
    store.secrets[name] = {
      source: { type: 'encrypted', encryptedValue: encrypt(value, masterKey) },
      allowedDomains,
      allowedPlacements,
      allowedCommands,
      createdAt: new Date().toISOString(),
      lastUsed: null,
      usageCount: 0
    };
  }

  await saveStore(store);
  return { created: true, overwritten };
}

export async function addSecretFrom1Password(
  name: string,
  opRef: string,
  allowedDomains: string[],
  allowedPlacements: SecretPlacement[] = ['header'],
  allowedCommands?: string[]
): Promise<{ created: boolean; overwritten: boolean; verified: boolean }> {
  validateSecretName(name);
  validateDomains(allowedDomains);
  validate1PasswordRef(opRef);

  // Verify we can read the secret
  let verified = false;
  try {
    await read1PasswordSecret(opRef);
    verified = true;
  } catch {
    // Will still add, but flag as unverified
  }

  const store = await loadStore();
  const overwritten = name in store.secrets;

  store.secrets[name] = {
    source: { type: '1password', ref: opRef },
    allowedDomains,
    allowedPlacements,
    allowedCommands,
    createdAt: new Date().toISOString(),
    lastUsed: null,
    usageCount: 0
  };

  await saveStore(store);
  return { created: true, overwritten, verified };
}

async function read1PasswordSecret(ref: string): Promise<string> {
  // Check cache first
  const cached = opCache.get(ref);
  if (cached && cached.expiresAt > Date.now()) {
    return cached.value;
  }

  try {
    const { stdout } = await execFileAsync('op', ['read', ref], {
      timeout: 10_000
    });
    const value = stdout.trim();
    
    // Cache the result
    opCache.set(ref, {
      value,
      expiresAt: Date.now() + OP_CACHE_TTL_MS
    });
    
    return value;
  } catch (error) {
    const err = error as { stderr?: string; message?: string };
    throw new Error(`Failed to read from 1Password: ${err.stderr || err.message}`, { cause: error });
  }
}

export async function getSecret(name: string): Promise<string | null> {
  const store = await loadStore();
  const secret = store.secrets[name];

  if (!secret) {
    return null;
  }

  // Keychain mode: resolve via macOS Keychain (used when running inside the app)
  if (isKeychainMode()) {
    return resolveFromKeychain(name);
  }

  if (secret.source.type === '1password') {
    try {
      return await read1PasswordSecret(secret.source.ref);
    } catch {
      return null;
    }
  }

  const masterKey = await getMasterKey();
  return decrypt(secret.source.encryptedValue, masterKey);
}

export async function getSecretMetadata(name: string): Promise<SecretMetadata | null> {
  const store = await loadStore();
  return store.secrets[name] ?? null;
}

export async function listSecrets(): Promise<SecretInfo[]> {
  const store = await loadStore();

  return Object.entries(store.secrets).map(([name, meta]) => ({
    name,
    sourceType: meta.source.type,
    allowedDomains: meta.allowedDomains,
    allowedPlacements: meta.allowedPlacements,
    allowedCommands: meta.allowedCommands,
    configured: true,
    createdAt: meta.createdAt,
    lastUsed: meta.lastUsed,
    usageCount: meta.usageCount
  }));
}

export async function removeSecret(name: string): Promise<boolean> {
  const store = await loadStore();

  if (!(name in store.secrets)) {
    return false;
  }

  // Remove from Keychain if in Keychain mode
  if (isKeychainMode()) {
    await deleteFromKeychain(name);
  }

  delete store.secrets[name];

  // Also clear from cache if 1password
  opCache.delete(name);

  await saveStore(store);
  return true;
}

export async function rotateSecret(name: string, newValue: string): Promise<{ previousUsageCount: number } | null> {
  const store = await loadStore();
  const secret = store.secrets[name];
  
  if (!secret) {
    return null;
  }

  // Can only rotate encrypted secrets, not 1password refs
  if (secret.source.type === '1password') {
    throw new Error('Cannot rotate 1Password secrets. Update the value in 1Password instead.');
  }

  const previousUsageCount = secret.usageCount;

  if (isKeychainMode()) {
    await storeInKeychain(name, newValue);
  } else {
    const masterKey = await getMasterKey();
    secret.source = { type: 'encrypted', encryptedValue: encrypt(newValue, masterKey) };
  }

  secret.createdAt = new Date().toISOString();
  secret.lastUsed = null;
  secret.usageCount = 0;

  await saveStore(store);
  return { previousUsageCount };
}

export async function recordUsage(name: string): Promise<void> {
  const store = await loadStore();

  const secret = store.secrets[name];
  if (secret) {
    secret.lastUsed = new Date().toISOString();
    secret.usageCount++;
    await saveStore(store);
  }
}

export async function secretExists(name: string): Promise<boolean> {
  const store = await loadStore();
  return name in store.secrets;
}

export function clearOpCache(): void {
  opCache.clear();
}

function validateSecretName(name: string): void {
  if (!/^[A-Z][A-Z0-9_]*$/.test(name)) {
    throw new Error(`Invalid secret name "${name}". Must be SCREAMING_SNAKE_CASE (e.g., API_KEY, GITHUB_TOKEN)`);
  }
}

function validateDomains(domains: string[]): void {
  if (domains.length === 0) {
    throw new Error('At least one allowed domain is required');
  }

  for (const domain of domains) {
    if (!isValidDomain(domain)) {
      throw new Error(`Invalid domain pattern "${domain}"`);
    }
  }
}

function validate1PasswordRef(ref: string): void {
  // Format: op://vault/item/field or op://vault/item/section/field
  if (!ref.startsWith('op://')) {
    throw new Error(`Invalid 1Password reference "${ref}". Must start with "op://"`);
  }
  
  const parts = ref.slice(5).split('/');
  if (parts.length < 3) {
    throw new Error(`Invalid 1Password reference "${ref}". Format: op://vault/item/field`);
  }
}

function isValidDomain(domain: string): boolean {
  // Allow wildcards like *.domain.com or exact domains
  const pattern = /^(\*\.)?[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$/;
  return pattern.test(domain);
}
