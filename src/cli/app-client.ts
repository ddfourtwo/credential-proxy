import { detectAppUrl, relayToApp, getMgmtToken } from '../app-client.js';
import {
  listSecrets,
  getSecret,
  getSecretMetadata,
  secretExists,
  addSecret,
  removeSecret,
  rotateSecret,
} from '../storage/secrets-store.js';
import { handleProxyRequest } from '../tools/proxy-request.js';
import { handleProxyExec } from '../tools/proxy-exec.js';
import type {
  SecretInfo,
  SecretMetadata,
  SecretPlacement,
} from '../storage/types.js';
import type {
  ProxyRequestInput,
  ProxyRequestOutput,
  ProxyRequestError,
} from '../tools/proxy-request.js';
import type {
  ProxyExecInput,
  ProxyExecOutput,
  ProxyExecError,
} from '../tools/proxy-exec.js';

interface AppCredentialInfo {
  name: string;
  sourceType: string;
  allowedDomains: string[];
  allowedPlacements: SecretPlacement[];
  allowedCommands?: string[];
  configured: boolean;
  createdAt: string;
  lastUsed: string | null;
  usageCount: number;
}

interface AppListResponse {
  credentials?: AppCredentialInfo[];
  secrets?: AppCredentialInfo[];
}

async function withAppFallback<T>(
  appFn: () => Promise<T>,
  localFn: () => Promise<T>
): Promise<T> {
  const appUrl = await detectAppUrl();
  if (appUrl) {
    try {
      return await appFn();
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      const isConnectionError =
        msg.includes('fetch failed') ||
        msg.includes('ECONNREFUSED') ||
        msg.includes('ENOTFOUND');
      if (isConnectionError) {
        return localFn();
      }
      throw error;
    }
  }
  return localFn();
}

function normalizeListResponse(result: AppListResponse): SecretInfo[] {
  const items = result.credentials ?? result.secrets ?? [];
  return items.map((item) => ({
    name: item.name,
    sourceType: item.sourceType as 'encrypted' | '1password',
    allowedDomains: item.allowedDomains,
    allowedPlacements: item.allowedPlacements,
    allowedCommands: item.allowedCommands,
    configured: item.configured ?? true,
    createdAt: item.createdAt,
    lastUsed: item.lastUsed,
    usageCount: item.usageCount ?? 0,
  }));
}

function isNotFoundError(error: unknown): boolean {
  const msg = error instanceof Error ? error.message : String(error);
  return msg.includes('404') || msg.toLowerCase().includes('not found');
}

export async function cliListSecrets(): Promise<SecretInfo[]> {
  return withAppFallback(
    async () => {
      const mgmtToken = await getMgmtToken();
      const result = (await relayToApp(
        '/credentials',
        'GET',
        undefined,
        undefined,
        undefined,
        mgmtToken
      )) as AppListResponse;
      return normalizeListResponse(result);
    },
    () => listSecrets()
  );
}

export async function cliGetSecret(name: string): Promise<string | null> {
  return withAppFallback(
    async () => {
      const mgmtToken = await getMgmtToken();
      try {
        const result = (await relayToApp(
          `/credentials/${encodeURIComponent(name)}/reveal`,
          'GET',
          undefined,
          undefined,
          undefined,
          mgmtToken
        )) as { value?: string };
        return result.value ?? null;
      } catch (error) {
        if (isNotFoundError(error)) {
          return null;
        }
        throw error;
      }
    },
    () => getSecret(name)
  );
}

export async function cliGetSecretMetadata(
  name: string
): Promise<SecretMetadata | null> {
  return withAppFallback(
    async () => {
      const mgmtToken = await getMgmtToken();
      const result = (await relayToApp(
        '/credentials',
        'GET',
        undefined,
        undefined,
        undefined,
        mgmtToken
      )) as AppListResponse;
      const items = normalizeListResponse(result);
      const item = items.find((c) => c.name === name);
      if (!item) return null;
      return {
        source:
          item.sourceType === '1password'
            ? { type: '1password' as const, ref: '' }
            : { type: 'encrypted' as const, encryptedValue: '__app__' },
        allowedDomains: item.allowedDomains,
        allowedPlacements: item.allowedPlacements,
        allowedCommands: item.allowedCommands,
        createdAt: item.createdAt,
        lastUsed: item.lastUsed,
        usageCount: item.usageCount,
      };
    },
    () => getSecretMetadata(name)
  );
}

export async function cliSecretExists(name: string): Promise<boolean> {
  return withAppFallback(
    async () => {
      const mgmtToken = await getMgmtToken();
      const result = (await relayToApp(
        '/credentials',
        'GET',
        undefined,
        undefined,
        undefined,
        mgmtToken
      )) as AppListResponse;
      const items = normalizeListResponse(result);
      return items.some((c) => c.name === name);
    },
    () => secretExists(name)
  );
}

export async function cliAddSecret(
  name: string,
  value: string,
  allowedDomains: string[],
  allowedPlacements: SecretPlacement[] = ['header'],
  allowedCommands?: string[]
): Promise<{ created: boolean; overwritten: boolean }> {
  return withAppFallback(
    async () => {
      const mgmtToken = await getMgmtToken();
      const result = (await relayToApp(
        '/credentials',
        'POST',
        {
          name,
          value,
          allowedDomains,
          allowedPlacements,
          allowedCommands,
        },
        undefined,
        undefined,
        mgmtToken
      )) as { success?: boolean; created?: boolean; overwritten?: boolean };
      return {
        created: result.created ?? result.success ?? true,
        overwritten: result.overwritten ?? false,
      };
    },
    () => addSecret(name, value, allowedDomains, allowedPlacements, allowedCommands)
  );
}

export async function cliRemoveSecret(name: string): Promise<boolean> {
  return withAppFallback(
    async () => {
      const mgmtToken = await getMgmtToken();
      try {
        await relayToApp(
          `/credentials/${encodeURIComponent(name)}`,
          'DELETE',
          undefined,
          undefined,
          undefined,
          mgmtToken
        );
        return true;
      } catch (error) {
        if (isNotFoundError(error)) {
          return false;
        }
        throw error;
      }
    },
    () => removeSecret(name)
  );
}

export async function cliRotateSecret(
  name: string,
  newValue: string
): Promise<{ previousUsageCount: number } | null> {
  return withAppFallback(
    async () => {
      const mgmtToken = await getMgmtToken();
      try {
        const result = (await relayToApp(
          `/credentials/${encodeURIComponent(name)}/rotate`,
          'POST',
          { value: newValue },
          undefined,
          undefined,
          mgmtToken
        )) as { previousUsageCount?: number };
        return { previousUsageCount: result.previousUsageCount ?? 0 };
      } catch (error) {
        if (isNotFoundError(error)) {
          return null;
        }
        throw error;
      }
    },
    () => rotateSecret(name, newValue)
  );
}

export async function cliHandleProxyRequest(
  input: ProxyRequestInput
): Promise<ProxyRequestOutput | ProxyRequestError> {
  return withAppFallback(
    async () => {
      try {
        const result = (await relayToApp('/proxy', 'POST', input)) as
          | ProxyRequestOutput
          | ProxyRequestError;
        return result;
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        // If the app server returned a 4xx/5xx with an error body, relayToApp throws.
        // Try to parse the error details from the message.
        if (msg.includes('SECRET_NOT_FOUND')) {
          return { error: 'SECRET_NOT_FOUND', message: msg } as ProxyRequestError;
        }
        if (msg.includes('SECRET_DOMAIN_BLOCKED')) {
          return { error: 'SECRET_DOMAIN_BLOCKED', message: msg } as ProxyRequestError;
        }
        if (msg.includes('SECRET_PLACEMENT_BLOCKED')) {
          return { error: 'SECRET_PLACEMENT_BLOCKED', message: msg } as ProxyRequestError;
        }
        if (msg.includes('REQUEST_FAILED')) {
          return { error: 'REQUEST_FAILED', message: msg } as ProxyRequestError;
        }
        return { error: 'REQUEST_FAILED', message: msg } as ProxyRequestError;
      }
    },
    () => handleProxyRequest(input)
  );
}

export async function cliHandleProxyExec(
  input: ProxyExecInput
): Promise<ProxyExecOutput | ProxyExecError> {
  return withAppFallback(
    async () => {
      try {
        const timeoutMs = (input.timeout ?? 30_000) + 10_000;
        const result = (await relayToApp(
          '/exec',
          'POST',
          input,
          undefined,
          timeoutMs
        )) as ProxyExecOutput | ProxyExecError;
        return result;
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        if (msg.includes('SECRET_NOT_FOUND')) {
          return { error: 'SECRET_NOT_FOUND', message: msg } as ProxyExecError;
        }
        if (msg.includes('SECRET_COMMAND_BLOCKED')) {
          return { error: 'SECRET_COMMAND_BLOCKED', message: msg } as ProxyExecError;
        }
        if (msg.includes('SECRET_PLACEMENT_BLOCKED')) {
          return { error: 'SECRET_PLACEMENT_BLOCKED', message: msg } as ProxyExecError;
        }
        if (msg.includes('EXEC_FAILED')) {
          return { error: 'EXEC_FAILED', message: msg } as ProxyExecError;
        }
        return { error: 'EXEC_FAILED', message: msg } as ProxyExecError;
      }
    },
    () => handleProxyExec(input)
  );
}
