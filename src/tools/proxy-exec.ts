import { spawn } from 'node:child_process';
import { getSecret, getSecretMetadata, recordUsage } from '../storage/secrets-store.js';
import { redactValue } from '../utils/redaction.js';
import { audit } from '../utils/audit-logger.js';
import { minimatch } from 'minimatch';

export interface ProxyExecInput {
  command: string[];                    // ["git", "clone", "https://{{TOKEN}}@github.com/..."]
  env?: Record<string, string>;         // { "GH_TOKEN": "{{GITHUB_TOKEN}}" }
  cwd?: string;
  timeout?: number;                     // Default: 30000ms
  stdin?: string;                       // Optional stdin input
}

export interface ProxyExecOutput {
  exitCode: number;
  stdout: string;
  stderr: string;
  redacted: boolean;
  timedOut: boolean;
}

export interface ProxyExecError {
  error: 'SECRET_NOT_FOUND' | 'SECRET_COMMAND_BLOCKED' | 'SECRET_PLACEMENT_BLOCKED' | 'EXEC_FAILED';
  message: string;
  hint?: string;
  secret?: string;
  requestedCommand?: string;
  allowedCommands?: string[];
  requestedPlacement?: string;
  allowedPlacements?: string[];
  cause?: string;
}

export const proxyExecTool = {
  name: 'proxy_exec',
  description: 'Execute a command with secure credential substitution. Use {{SECRET_NAME}} placeholders in command arguments or environment variables. The secret value is never exposed to you - it is substituted on the server side and redacted from output.',
  inputSchema: {
    type: 'object' as const,
    properties: {
      command: {
        type: 'array',
        items: { type: 'string' },
        description: 'Command and arguments as array. Use {{SECRET_NAME}} for credentials, e.g., ["git", "clone", "https://{{TOKEN}}@github.com/repo"]'
      },
      env: {
        type: 'object',
        additionalProperties: { type: 'string' },
        description: 'Environment variables to set. Use {{SECRET_NAME}} for credentials, e.g., { "GH_TOKEN": "{{GITHUB_TOKEN}}" }'
      },
      cwd: {
        type: 'string',
        description: 'Working directory for the command'
      },
      timeout: {
        type: 'number',
        description: 'Timeout in milliseconds (default: 30000)'
      },
      stdin: {
        type: 'string',
        description: 'Optional input to send to stdin'
      }
    },
    required: ['command']
  }
};

const PLACEHOLDER_REGEX = /\{\{([A-Z][A-Z0-9_]*)\}\}/g;

type ExecPlacement = 'arg' | 'env';

interface PlaceholderInfo {
  name: string;
  placement: ExecPlacement;
  fullMatch: string;
}

function findPlaceholders(input: ProxyExecInput): PlaceholderInfo[] {
  const placeholders: PlaceholderInfo[] = [];

  // Check command arguments
  for (const arg of input.command) {
    let match;
    while ((match = PLACEHOLDER_REGEX.exec(arg)) !== null) {
      placeholders.push({
        name: match[1],
        placement: 'arg',
        fullMatch: match[0]
      });
    }
    PLACEHOLDER_REGEX.lastIndex = 0;
  }

  // Check environment variables
  if (input.env) {
    for (const value of Object.values(input.env)) {
      let match;
      while ((match = PLACEHOLDER_REGEX.exec(value)) !== null) {
        placeholders.push({
          name: match[1],
          placement: 'env',
          fullMatch: match[0]
        });
      }
      PLACEHOLDER_REGEX.lastIndex = 0;
    }
  }

  return placeholders;
}

function commandMatchesPattern(command: string[], pattern: string): boolean {
  const commandStr = command.join(' ');
  return minimatch(commandStr, pattern, { dot: true });
}

async function validatePlaceholder(
  placeholder: PlaceholderInfo,
  command: string[]
): Promise<ProxyExecError | null> {
  const metadata = await getSecretMetadata(placeholder.name);

  if (!metadata) {
    return {
      error: 'SECRET_NOT_FOUND',
      message: `Secret '${placeholder.name}' is not configured`,
      hint: `Use 'credential-proxy add ${placeholder.name}' to configure`
    };
  }

  // Check if placement is allowed
  if (!metadata.allowedPlacements.includes(placeholder.placement)) {
    await audit.secretBlocked(placeholder.name, command[0], 'PLACEMENT_NOT_ALLOWED');
    return {
      error: 'SECRET_PLACEMENT_BLOCKED',
      message: `Secret '${placeholder.name}' cannot be used in '${placeholder.placement}'`,
      secret: placeholder.name,
      requestedPlacement: placeholder.placement,
      allowedPlacements: metadata.allowedPlacements
    };
  }

  // Check if command is allowed (if restrictions exist)
  if (metadata.allowedCommands && metadata.allowedCommands.length > 0) {
    const allowed = metadata.allowedCommands.some(pattern => 
      commandMatchesPattern(command, pattern)
    );
    
    if (!allowed) {
      await audit.secretBlocked(placeholder.name, command.join(' '), 'COMMAND_NOT_ALLOWED');
      return {
        error: 'SECRET_COMMAND_BLOCKED',
        message: `Secret '${placeholder.name}' cannot be used with command '${command[0]}'`,
        secret: placeholder.name,
        requestedCommand: command.join(' '),
        allowedCommands: metadata.allowedCommands
      };
    }
  }

  return null;
}

function substituteSecrets(
  content: string,
  secretValues: Map<string, string>
): string {
  let result = content;
  for (const [name, value] of secretValues) {
    result = result.replaceAll(`{{${name}}}`, value);
  }
  return result;
}

export async function handleProxyExec(
  input: ProxyExecInput
): Promise<ProxyExecOutput | ProxyExecError> {
  const startTime = Date.now();

  if (!input.command || input.command.length === 0) {
    return {
      error: 'EXEC_FAILED',
      message: 'Command array cannot be empty'
    };
  }

  // Find all placeholders
  const placeholders = findPlaceholders(input);

  // Validate each placeholder
  for (const placeholder of placeholders) {
    const error = await validatePlaceholder(placeholder, input.command);
    if (error) {
      return error;
    }
  }

  // Load secret values
  const secretValues = new Map<string, string>();
  const secretNames = [...new Set(placeholders.map(p => p.name))];

  for (const name of secretNames) {
    const value = await getSecret(name);
    if (!value) {
      return {
        error: 'SECRET_NOT_FOUND',
        message: `Secret '${name}' could not be retrieved`,
        hint: 'The secret may be corrupted or 1Password may not be authenticated.'
      };
    }
    secretValues.set(name, value);
  }

  // Substitute secrets in command arguments
  const substitutedCommand = input.command.map(arg => 
    substituteSecrets(arg, secretValues)
  );

  // Substitute secrets in environment variables
  const substitutedEnv: Record<string, string> = { ...process.env } as Record<string, string>;
  if (input.env) {
    for (const [key, value] of Object.entries(input.env)) {
      substitutedEnv[key] = substituteSecrets(value, secretValues);
    }
  }

  // Execute command
  return new Promise((resolve) => {
    const timeout = input.timeout ?? 30_000;
    let timedOut = false;
    let stdout = '';
    let stderr = '';

    const proc = spawn(substitutedCommand[0], substitutedCommand.slice(1), {
      cwd: input.cwd,
      env: substitutedEnv,
      stdio: ['pipe', 'pipe', 'pipe']
    });

    const timeoutId = setTimeout(() => {
      timedOut = true;
      proc.kill('SIGKILL');
    }, timeout);

    proc.stdout.on('data', (data) => {
      stdout += data.toString();
    });

    proc.stderr.on('data', (data) => {
      stderr += data.toString();
    });

    if (input.stdin) {
      proc.stdin.write(input.stdin);
      proc.stdin.end();
    } else {
      proc.stdin.end();
    }

    proc.on('close', async (code) => {
      clearTimeout(timeoutId);
      const duration = Date.now() - startTime;

      // Record usage for each secret
      for (const name of secretNames) {
        await recordUsage(name);
        await audit.secretUsedExec(name, input.command[0], code ?? -1, duration);
      }

      // Redact any secret values from output
      let redacted = false;
      for (const [name, value] of secretValues) {
        const originalStdoutLen = stdout.length;
        const originalStderrLen = stderr.length;
        
        stdout = redactValue(stdout, value, name);
        stderr = redactValue(stderr, value, name);
        
        if (stdout.length !== originalStdoutLen || stderr.length !== originalStderrLen) {
          redacted = true;
          await audit.secretRedacted(name, originalStdoutLen + originalStderrLen, 1);
        }
      }

      resolve({
        exitCode: code ?? -1,
        stdout,
        stderr,
        redacted,
        timedOut
      });
    });

    proc.on('error', (error) => {
      clearTimeout(timeoutId);
      resolve({
        error: 'EXEC_FAILED',
        message: `Failed to execute command: ${error.message}`,
        cause: error.message
      } as ProxyExecError);
    });
  });
}
