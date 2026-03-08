import { appendFile, mkdir, stat } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { dirname } from 'node:path';
import { getAuditLogPath } from '../storage/keyring.js';

type AuditEventType =
  | 'SECRET_USED'
  | 'SECRET_USED_EXEC'
  | 'SECRET_BLOCKED'
  | 'SECRET_REDACTED'
  | 'SECRET_ADDED'
  | 'SECRET_REMOVED'
  | 'SECRET_ROTATED';

interface BaseAuditEvent {
  type: AuditEventType;
  timestamp: string;
  secret: string;
}

interface SecretUsedEvent extends BaseAuditEvent {
  type: 'SECRET_USED';
  domain: string;
  method: string;
  status: number;
  durationMs: number;
}

interface SecretUsedExecEvent extends BaseAuditEvent {
  type: 'SECRET_USED_EXEC';
  command: string;
  exitCode: number;
  durationMs: number;
}

interface SecretBlockedEvent extends BaseAuditEvent {
  type: 'SECRET_BLOCKED';
  domain: string;
  reason: 'DOMAIN_NOT_ALLOWED' | 'PLACEMENT_NOT_ALLOWED' | 'COMMAND_NOT_ALLOWED';
}

interface SecretRedactedEvent extends BaseAuditEvent {
  type: 'SECRET_REDACTED';
  responseBytes: number;
  redactedCount: number;
}

interface SecretAddedEvent extends BaseAuditEvent {
  type: 'SECRET_ADDED';
  domains: string[];
  placements: string[];
}

interface SecretRemovedEvent extends BaseAuditEvent {
  type: 'SECRET_REMOVED';
}

interface SecretRotatedEvent extends BaseAuditEvent {
  type: 'SECRET_ROTATED';
  previousUses: number;
}

type AuditEvent =
  | SecretUsedEvent
  | SecretUsedExecEvent
  | SecretBlockedEvent
  | SecretRedactedEvent
  | SecretAddedEvent
  | SecretRemovedEvent
  | SecretRotatedEvent;

const MAX_LOG_SIZE = 10 * 1024 * 1024; // 10MB

async function ensureLogDir(): Promise<void> {
  const logPath = getAuditLogPath();
  const dir = dirname(logPath);
  if (!existsSync(dir)) {
    await mkdir(dir, { recursive: true, mode: 0o700 });
  }
}

async function shouldRotate(): Promise<boolean> {
  const logPath = getAuditLogPath();
  if (!existsSync(logPath)) return false;

  try {
    const stats = await stat(logPath);
    return stats.size >= MAX_LOG_SIZE;
  } catch {
    return false;
  }
}

async function rotateLog(): Promise<void> {
  const logPath = getAuditLogPath();
  const rotatedPath = `${logPath}.${Date.now()}.old`;

  const { rename } = await import('node:fs/promises');
  await rename(logPath, rotatedPath);
}

function formatEvent(event: AuditEvent): string {
  const parts = [`[${event.timestamp}]`, event.type, `secret=${event.secret}`];

  switch (event.type) {
    case 'SECRET_USED':
      parts.push(`domain=${event.domain}`, `method=${event.method}`, `status=${event.status}`, `duration=${event.durationMs}ms`);
      break;
    case 'SECRET_USED_EXEC':
      parts.push(`command=${event.command}`, `exit_code=${event.exitCode}`, `duration=${event.durationMs}ms`);
      break;
    case 'SECRET_BLOCKED':
      parts.push(`domain=${event.domain}`, `reason=${event.reason}`);
      break;
    case 'SECRET_REDACTED':
      parts.push(`response_bytes=${event.responseBytes}`, `redacted_count=${event.redactedCount}`);
      break;
    case 'SECRET_ADDED':
      parts.push(`domains=${event.domains.join(',')}`, `placements=${event.placements.join(',')}`);
      break;
    case 'SECRET_ROTATED':
      parts.push(`previous_uses=${event.previousUses}`);
      break;
  }

  return parts.join(' ');
}

async function log(event: AuditEvent): Promise<void> {
  await ensureLogDir();

  if (await shouldRotate()) {
    await rotateLog();
  }

  const logPath = getAuditLogPath();
  const line = formatEvent(event) + '\n';
  await appendFile(logPath, line, { mode: 0o600 });
}

export const audit = {
  async secretUsed(secret: string, domain: string, method: string, status: number, durationMs: number): Promise<void> {
    await log({
      type: 'SECRET_USED',
      timestamp: new Date().toISOString(),
      secret,
      domain,
      method,
      status,
      durationMs
    });
  },

  async secretUsedExec(secret: string, command: string, exitCode: number, durationMs: number): Promise<void> {
    await log({
      type: 'SECRET_USED_EXEC',
      timestamp: new Date().toISOString(),
      secret,
      command,
      exitCode,
      durationMs
    });
  },

  async secretBlocked(secret: string, domain: string, reason: 'DOMAIN_NOT_ALLOWED' | 'PLACEMENT_NOT_ALLOWED' | 'COMMAND_NOT_ALLOWED'): Promise<void> {
    await log({
      type: 'SECRET_BLOCKED',
      timestamp: new Date().toISOString(),
      secret,
      domain,
      reason
    });
  },

  async secretRedacted(secret: string, responseBytes: number, redactedCount: number): Promise<void> {
    await log({
      type: 'SECRET_REDACTED',
      timestamp: new Date().toISOString(),
      secret,
      responseBytes,
      redactedCount
    });
  },

  async secretAdded(secret: string, domains: string[], placements: string[]): Promise<void> {
    await log({
      type: 'SECRET_ADDED',
      timestamp: new Date().toISOString(),
      secret,
      domains,
      placements
    });
  },

  async secretRemoved(secret: string): Promise<void> {
    await log({
      type: 'SECRET_REMOVED',
      timestamp: new Date().toISOString(),
      secret
    });
  },

  async secretRotated(secret: string, previousUses: number): Promise<void> {
    await log({
      type: 'SECRET_ROTATED',
      timestamp: new Date().toISOString(),
      secret,
      previousUses
    });
  }
};
