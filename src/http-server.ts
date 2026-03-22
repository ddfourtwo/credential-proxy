import { createServer, IncomingMessage, ServerResponse } from 'node:http';
import { createHmac, timingSafeEqual } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { existsSync } from 'node:fs';
import { handleProxyRequest, type ProxyRequestInput } from './tools/proxy-request.js';
import { handleProxyExec, type ProxyExecInput } from './tools/proxy-exec.js';
import { handleListCredentials, type ListCredentialsInput } from './tools/list-credentials.js';
import { addSecret, removeSecret, rotateSecret, getSecret } from './storage/secrets-store.js';
import { getAuditLogPath } from './storage/keyring.js';
import type { SecretPlacement } from './storage/types.js';

interface ServerOptions {
  port: number;
  host: string;
}

const MAX_BODY_SIZE = 1024 * 1024; // 1 MB
const MGMT_TOKEN = process.env.CREDENTIAL_PROXY_MGMT_TOKEN;

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

function checkMgmtAuth(req: IncomingMessage): boolean {
  if (!MGMT_TOKEN) return true; // No token configured = no auth required
  const auth = req.headers.authorization;
  return auth === `Bearer ${MGMT_TOKEN}`;
}

function requireMgmtAuth(req: IncomingMessage, res: ServerResponse): boolean {
  if (!checkMgmtAuth(req)) {
    sendError(res, 401, 'Management token required');
    return false;
  }
  return true;
}

async function handleRequest(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url ?? '/', `http://${req.headers.host}`);
  const path = url.pathname;
  const method = req.method?.toUpperCase();

  // CORS headers — restrict to localhost origins only
  const origin = req.headers['origin'];
  if (origin && /^http:\/\/localhost:\d+$/.test(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, PUT, DELETE, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

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

    // List credentials (available to both agents and management UI)
    if (path === '/credentials' && method === 'GET') {
      const filter = url.searchParams.get('filter') ?? undefined;
      const input: ListCredentialsInput = { filter };
      const result = await handleListCredentials(input);
      sendJson(res, 200, result);
      return;
    }

    // --- Management endpoints (require auth token) ---

    // Add credential
    if (path === '/credentials' && method === 'POST') {
      if (!requireMgmtAuth(req, res)) return;

      const bodyStr = await parseBody(req);
      if (!bodyStr) { sendError(res, 400, 'Request body is required'); return; }

      let body: {
        name?: string;
        value?: string;
        allowedDomains?: string[];
        allowedPlacements?: string[];
        allowedCommands?: string[];
      };
      try { body = JSON.parse(bodyStr); } catch { sendError(res, 400, 'Invalid JSON'); return; }

      if (!body.name || !body.value || !body.allowedDomains?.length) {
        sendError(res, 400, 'name, value, and allowedDomains are required');
        return;
      }

      const placements = (body.allowedPlacements || ['header']) as SecretPlacement[];
      const result = await addSecret(body.name, body.value, body.allowedDomains, placements, body.allowedCommands);
      sendJson(res, result.overwritten ? 200 : 201, { success: true, ...result });
      return;
    }

    // Delete credential: DELETE /credentials/:name
    const deleteMatch = path.match(/^\/credentials\/([A-Z][A-Z0-9_]*)$/);
    if (deleteMatch && method === 'DELETE') {
      if (!requireMgmtAuth(req, res)) return;

      const name = deleteMatch[1];
      const removed = await removeSecret(name);
      if (!removed) {
        sendError(res, 404, `Secret "${name}" not found`);
        return;
      }
      sendJson(res, 200, { success: true, name });
      return;
    }

    // Rotate credential: POST /credentials/:name/rotate
    const rotateMatch = path.match(/^\/credentials\/([A-Z][A-Z0-9_]*)\/rotate$/);
    if (rotateMatch && method === 'POST') {
      if (!requireMgmtAuth(req, res)) return;

      const name = rotateMatch[1];
      const bodyStr = await parseBody(req);
      if (!bodyStr) { sendError(res, 400, 'Request body is required'); return; }

      let body: { value?: string };
      try { body = JSON.parse(bodyStr); } catch { sendError(res, 400, 'Invalid JSON'); return; }

      if (!body.value) {
        sendError(res, 400, 'value is required');
        return;
      }

      const result = await rotateSecret(name, body.value);
      if (!result) {
        sendError(res, 404, `Secret "${name}" not found`);
        return;
      }
      sendJson(res, 200, { success: true, name, ...result });
      return;
    }

    // Audit log: GET /audit?limit=50
    if (path === '/audit' && method === 'GET') {
      if (!requireMgmtAuth(req, res)) return;

      const limit = parseInt(url.searchParams.get('limit') ?? '50', 10);
      const logPath = getAuditLogPath();

      if (!existsSync(logPath)) {
        sendJson(res, 200, { events: [] });
        return;
      }

      const content = await readFile(logPath, 'utf8');
      const lines = content.trim().split('\n').filter(Boolean);
      const events = lines.slice(-limit).reverse();
      sendJson(res, 200, { events });
      return;
    }

    // --- Agent tool endpoints (no auth required) ---

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

      if (!input.method || !input.url) {
        sendError(res, 400, 'method and url are required');
        return;
      }

      const result = await handleProxyRequest(input);

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

      if (!input.command || !Array.isArray(input.command) || input.command.length === 0) {
        sendError(res, 400, 'command array is required');
        return;
      }

      const result = await handleProxyExec(input);

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

    // Validate HMAC signature
    if (path === '/validate-hmac' && method === 'POST') {
      const bodyStr = await parseBody(req);
      if (!bodyStr) { sendError(res, 400, 'Request body is required'); return; }

      let body: {
        secretName?: string;
        algorithm?: string;
        payload?: string;
        signature?: string;
        encoding?: string;
        prefix?: string;
      };
      try { body = JSON.parse(bodyStr); } catch { sendError(res, 400, 'Invalid JSON'); return; }

      if (!body.secretName || !body.algorithm || !body.payload || !body.signature || !body.encoding) {
        sendError(res, 400, 'secretName, algorithm, payload, signature, and encoding are required');
        return;
      }

      const secretValue = await getSecret(body.secretName);
      if (secretValue === null) {
        sendError(res, 404, 'Secret not found');
        return;
      }

      const computedHmac = createHmac(body.algorithm, secretValue)
        .update(Buffer.from(body.payload, 'base64'))
        .digest(body.encoding as 'hex' | 'base64');

      let providedSignature = body.signature;
      if (body.prefix && providedSignature.startsWith(body.prefix)) {
        providedSignature = providedSignature.slice(body.prefix.length);
      }

      const computedBuf = Buffer.from(computedHmac, 'utf8');
      const providedBuf = Buffer.from(providedSignature, 'utf8');
      const valid = computedBuf.length === providedBuf.length &&
        timingSafeEqual(computedBuf, providedBuf);

      sendJson(res, 200, { valid });
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
      console.log(`credential-proxy HTTP server running at http://${options.host}:${options.port}`);
      if (MGMT_TOKEN) {
        console.log('Management endpoints require authorization token');
      }
      console.log('');
      console.log('Endpoints:');
      console.log('  GET    /health                      - Health check');
      console.log('  GET    /credentials                 - List credentials');
      console.log('  POST   /credentials                 - Add credential [mgmt]');
      console.log('  DELETE /credentials/:name            - Remove credential [mgmt]');
      console.log('  POST   /credentials/:name/rotate    - Rotate credential [mgmt]');
      console.log('  GET    /audit                       - Audit log [mgmt]');
      console.log('  POST   /proxy                       - Proxied HTTP request');
      console.log('  POST   /exec                        - Proxied command execution');
      console.log('  POST   /validate-hmac                - Validate HMAC signature');
      console.log('');
      resolve();
    });
  });
}
