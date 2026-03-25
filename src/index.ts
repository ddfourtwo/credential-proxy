import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
} from '@modelcontextprotocol/sdk/types.js';
import { listCredentialsTool, handleListCredentials } from './tools/list-credentials.js';
import { proxyRequestTool, handleProxyRequest } from './tools/proxy-request.js';
import { proxyExecTool, handleProxyExec } from './tools/proxy-exec.js';
import { requestCredentialTool } from './tools/request-credential.js';
import { updateCredentialTool, handleUpdateCredential } from './tools/update-credential.js';
import type { RequestCredentialInput } from './tools/request-credential.js';
import type { UpdateCredentialInput } from './tools/update-credential.js';
import type { ListCredentialsInput } from './tools/list-credentials.js';
import type { ProxyRequestInput } from './tools/proxy-request.js';
import type { ProxyExecInput } from './tools/proxy-exec.js';

import { appendFileSync, mkdirSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

const APP_URL = process.env.CREDENTIAL_PROXY_APP_URL;

// Log to both stderr and a file (stderr may be silenced by MCP clients)
const LOG_DIR = join(homedir(), 'Library', 'Application Support', 'credential-proxy', 'logs');
try { mkdirSync(LOG_DIR, { recursive: true }); } catch { /* ignore */ }
function mcpLog(msg: string) {
  const line = `[${new Date().toISOString()}] ${msg}\n`;
  console.error(line.trimEnd());
  try { appendFileSync(join(LOG_DIR, 'mcp.log'), line); } catch { /* ignore */ }
}

// Relay mode: forward tool calls to the app's HTTP server.
// The MCP stdio server never touches secrets — the app handles everything.
async function relayToApp(
  endpoint: string,
  method: string,
  body?: unknown,
  queryParams?: Record<string, string>,
  timeoutMs?: number
): Promise<unknown> {
  const url = new URL(endpoint, APP_URL);
  if (queryParams) {
    for (const [k, v] of Object.entries(queryParams)) {
      if (v !== undefined) url.searchParams.set(k, v);
    }
  }

  const opts: RequestInit = {
    method,
    headers: { 'Content-Type': 'application/json' },
  };
  if (body && method !== 'GET') {
    opts.body = JSON.stringify(body);
  }

  // For long-running requests (e.g. proxy_exec), set fetch timeout to match.
  // Default 30s for normal requests; exec passes its own timeout + buffer.
  if (timeoutMs) {
    opts.signal = AbortSignal.timeout(timeoutMs);
  }

  const maxRetries = 3;
  const baseDelay = 500; // ms

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    try {
      const res = await fetch(url.toString(), opts);
      const text = await res.text();
      try {
        return JSON.parse(text);
      } catch {
        throw new Error(`App server returned ${res.status}: ${text.slice(0, 200)}`);
      }
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      const isConnectionError = msg.includes('fetch failed') || msg.includes('ECONNREFUSED');
      if (!isConnectionError || attempt === maxRetries) {
        throw error;
      }
      // Server may be starting up after unlock — wait and retry
      await new Promise(resolve => setTimeout(resolve, baseDelay * (attempt + 1)));
    }
  }

  throw new Error('Unreachable');
}

const server = new Server(
  {
    name: 'credential-proxy',
    version: '1.0.0',
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// List available tools
server.setRequestHandler(ListToolsRequestSchema, async () => {
  return {
    tools: [listCredentialsTool, proxyRequestTool, proxyExecTool, requestCredentialTool, updateCredentialTool],
  };
});

// Handle tool calls
server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    let result: unknown;

    if (APP_URL) {
      // Relay mode: forward to app HTTP server
      switch (name) {
        case 'list_credentials':
          result = await relayToApp(
            '/credentials', 'GET', undefined,
            (args as ListCredentialsInput)?.filter ? { filter: (args as ListCredentialsInput).filter! } : undefined
          );
          break;
        case 'proxy_request':
          result = await relayToApp('/proxy', 'POST', args);
          break;
        case 'proxy_exec': {
          // Match fetch timeout to the command's timeout + 10s buffer
          const execArgs = args as unknown as ProxyExecInput;
          const execTimeout = (execArgs.timeout ?? 30_000) + 10_000;
          result = await relayToApp('/exec', 'POST', args, undefined, execTimeout);
          break;
        }
        case 'update_credential':
          result = await relayToApp('/update-credential', 'POST', args);
          break;
        case 'request_credential': {
          const reqArgs = args as unknown as RequestCredentialInput;
          // Check if credential already exists before prompting the user
          const existing = await relayToApp('/credentials', 'GET') as { secrets?: Array<{ name: string }> };
          if (existing?.secrets?.some(s => s.name === reqArgs.name) && !reqArgs.overwrite) {
            return {
              content: [{ type: 'text' as const, text: `Credential '${reqArgs.name}' already exists. If you intend to replace it, call request_credential again with overwrite: true. Please confirm with the user first.` }],
              isError: true,
            };
          }
          result = await relayToApp('/request-credential', 'POST', args);
          break;
        }
        default:
          return {
            content: [{ type: 'text' as const, text: `Unknown tool: ${name}` }],
            isError: true,
          };
      }
    } else {
      // Local mode: handle directly (legacy, no app installed)
      switch (name) {
        case 'list_credentials':
          result = await handleListCredentials(args as ListCredentialsInput);
          break;
        case 'proxy_request':
          result = await handleProxyRequest(args as unknown as ProxyRequestInput);
          break;
        case 'proxy_exec':
          result = await handleProxyExec(args as unknown as ProxyExecInput);
          break;
        case 'update_credential':
          result = await handleUpdateCredential(args as unknown as UpdateCredentialInput);
          break;
        case 'request_credential':
          return {
            content: [{ type: 'text' as const, text: 'request_credential requires the macOS app. Set CREDENTIAL_PROXY_APP_URL to use this tool.' }],
            isError: true,
          };
        default:
          return {
            content: [{ type: 'text' as const, text: `Unknown tool: ${name}` }],
            isError: true,
          };
      }
    }

    return {
      content: [{ type: 'text' as const, text: JSON.stringify(result, null, 2) }],
    };
  } catch (error) {
    const msg = error instanceof Error ? error.message : String(error);
    const isConnectionError = msg.includes('fetch failed') || msg.includes('ECONNREFUSED');
    const isTimeout = error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError');

    if (isTimeout && APP_URL) {
      return {
        content: [
          {
            type: 'text' as const,
            text: `The command timed out waiting for Credential Proxy at ${APP_URL}. ` +
              'The command may still be running on the server. ' +
              'Consider increasing the timeout parameter for long-running commands.',
          },
        ],
        isError: true,
      };
    }

    if (isConnectionError && APP_URL) {
      return {
        content: [
          {
            type: 'text' as const,
            text: `Credential Proxy is not responding at ${APP_URL} (retried 3 times). Possible causes:\n` +
              '1. The macOS app is locked — click the key icon in the menu bar and enter your PIN\n' +
              '2. The app was just unlocked — the server may still be starting, try again in a few seconds\n' +
              '3. The app is not running — launch Credential Proxy from Applications',
          },
        ],
        isError: true,
      };
    }

    return {
      content: [
        {
          type: 'text' as const,
          text: `Error: ${msg}`,
        },
      ],
      isError: true,
    };
  }
});

// Start server
async function main() {
  const transport = new StdioServerTransport();

  const mode = APP_URL ? `relay → ${APP_URL}` : 'local';
  mcpLog(`starting (${mode}, pid ${process.pid})`);

  process.stdin.on('end', () => {
    mcpLog('stdin closed — shutting down');
  });

  process.stdin.on('error', (err) => {
    mcpLog(`stdin error: ${err.message}`);
  });

  process.on('SIGTERM', () => mcpLog('received SIGTERM'));
  process.on('SIGINT', () => mcpLog('received SIGINT'));

  process.on('uncaughtException', (err) => {
    mcpLog(`uncaught exception: ${err.stack || err.message}`);
    process.exit(1);
  });

  process.on('unhandledRejection', (reason) => {
    mcpLog(`unhandled rejection: ${reason}`);
  });

  await server.connect(transport);
  mcpLog('connected and ready');
}

main().catch((error) => {
  mcpLog(`failed to start: ${error.stack || error.message || error}`);
  process.exit(1);
});
