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
import type { RequestCredentialInput } from './tools/request-credential.js';
import type { ListCredentialsInput } from './tools/list-credentials.js';
import type { ProxyRequestInput } from './tools/proxy-request.js';
import type { ProxyExecInput } from './tools/proxy-exec.js';

const APP_URL = process.env.CREDENTIAL_PROXY_APP_URL;

// Relay mode: forward tool calls to the app's HTTP server.
// The MCP stdio server never touches secrets — the app handles everything.
async function relayToApp(
  endpoint: string,
  method: string,
  body?: unknown,
  queryParams?: Record<string, string>
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

  const res = await fetch(url.toString(), opts);
  const text = await res.text();
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`App server returned ${res.status}: ${text.slice(0, 200)}`);
  }
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
    tools: [listCredentialsTool, proxyRequestTool, proxyExecTool, requestCredentialTool],
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
        case 'proxy_exec':
          result = await relayToApp('/exec', 'POST', args);
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
    return {
      content: [
        {
          type: 'text' as const,
          text: `Error: ${error instanceof Error ? error.message : String(error)}`,
        },
      ],
      isError: true,
    };
  }
});

// Start server
async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((error) => {
  console.error('Failed to start server:', error);
  process.exit(1);
});
