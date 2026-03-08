import { createServer, IncomingMessage, ServerResponse } from 'node:http';
import { handleProxyRequest, type ProxyRequestInput } from './tools/proxy-request.js';
import { handleProxyExec, type ProxyExecInput } from './tools/proxy-exec.js';
import { handleListCredentials, type ListCredentialsInput } from './tools/list-credentials.js';

interface ServerOptions {
  port: number;
  host: string;
}

const MAX_BODY_SIZE = 1024 * 1024; // 1 MB

function parseBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_SIZE) {
        req.destroy();
        reject(new Error('Request body too large'));
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function sendJson(res: ServerResponse, status: number, data: unknown): void {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data, null, 2));
}

function sendError(res: ServerResponse, status: number, message: string): void {
  sendJson(res, status, { error: message });
}

async function handleRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
  const path = url.pathname;
  const method = req.method?.toUpperCase();

  // CORS headers for local use
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type');

  if (method === 'OPTIONS') {
    res.writeHead(204);
    res.end();
    return;
  }

  try {
    // Health check
    if (path === '/health' && method === 'GET') {
      sendJson(res, 200, { status: 'ok', service: 'credential-proxy' });
      return;
    }

    // List credentials
    if (path === '/credentials' && method === 'GET') {
      const filter = url.searchParams.get('filter') ?? undefined;
      const input: ListCredentialsInput = { filter };
      const result = await handleListCredentials(input);
      sendJson(res, 200, result);
      return;
    }

    // Proxy request
    if (path === '/proxy' && method === 'POST') {
      const bodyStr = await parseBody(req);
      
      if (!bodyStr) {
        sendError(res, 400, 'Request body is required');
        return;
      }

      let input: ProxyRequestInput;
      try {
        input = JSON.parse(bodyStr);
      } catch {
        sendError(res, 400, 'Invalid JSON body');
        return;
      }

      // Validate required fields
      if (!input.method || !input.url) {
        sendError(res, 400, 'method and url are required');
        return;
      }

      const result = await handleProxyRequest(input);
      
      // Check if result is an error
      if ('error' in result) {
        const status = result.error === 'SECRET_NOT_FOUND' ? 404 :
                       result.error === 'SECRET_DOMAIN_BLOCKED' ? 403 :
                       result.error === 'SECRET_PLACEMENT_BLOCKED' ? 403 :
                       500;
        sendJson(res, status, result);
        return;
      }

      sendJson(res, 200, result);
      return;
    }

    // Exec command
    if (path === '/exec' && method === 'POST') {
      const bodyStr = await parseBody(req);
      
      if (!bodyStr) {
        sendError(res, 400, 'Request body is required');
        return;
      }

      let input: ProxyExecInput;
      try {
        input = JSON.parse(bodyStr);
      } catch {
        sendError(res, 400, 'Invalid JSON body');
        return;
      }

      // Validate required fields
      if (!input.command || !Array.isArray(input.command) || input.command.length === 0) {
        sendError(res, 400, 'command array is required');
        return;
      }

      const result = await handleProxyExec(input);
      
      // Check if result is an error
      if ('error' in result) {
        const status = result.error === 'SECRET_NOT_FOUND' ? 404 :
                       result.error === 'SECRET_COMMAND_BLOCKED' ? 403 :
                       result.error === 'SECRET_PLACEMENT_BLOCKED' ? 403 :
                       500;
        sendJson(res, status, result);
        return;
      }

      sendJson(res, 200, result);
      return;
    }

    // Not found
    sendError(res, 404, `Unknown endpoint: ${method} ${path}`);
  } catch (error) {
    console.error('Request error:', error);
    sendError(res, 500, error instanceof Error ? error.message : 'Internal server error');
  }
}

export function startHttpServer(options: ServerOptions): Promise<void> {
  return new Promise((resolve, reject) => {
    const server = createServer((req, res) => {
      handleRequest(req, res).catch((error) => {
        console.error('Unhandled error:', error);
        if (!res.headersSent) {
          sendError(res, 500, 'Internal server error');
        }
      });
    });

    server.on('error', (error) => {
      reject(error);
    });

    server.listen(options.port, options.host, () => {
      console.log(`🔐 credential-proxy HTTP server running at http://${options.host}:${options.port}`);
      console.log('');
      console.log('Endpoints:');
      console.log(`  GET  /health       - Health check`);
      console.log(`  GET  /credentials  - List configured credentials`);
      console.log(`  POST /proxy        - Make proxied request with credential substitution`);
      console.log(`  POST /exec         - Execute command with credential substitution`);
      console.log('');
      resolve();
    });
  });
}
