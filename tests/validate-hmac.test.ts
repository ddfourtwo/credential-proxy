import { createHmac } from 'node:crypto';
import { vi } from 'vitest';

const TEST_PORT = 19876;
const TEST_SECRET_NAME = 'TEST_HMAC_SECRET';
const TEST_SECRET_VALUE = 'my-webhook-secret-key';

// Mock getSecret so we don't depend on the secrets file on disk
vi.mock('../src/storage/secrets-store.js', async (importOriginal) => {
  const original = await importOriginal<typeof import('../src/storage/secrets-store.js')>();
  return {
    ...original,
    getSecret: vi.fn(async (name: string) => {
      if (name === TEST_SECRET_NAME) return TEST_SECRET_VALUE;
      return null;
    }),
  };
});

async function postJson(path: string, body: unknown): Promise<{ status: number; data: any }> {
  const payload = JSON.stringify(body);
  const res = await fetch(`http://127.0.0.1:${TEST_PORT}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: payload,
  });
  const data = await res.json();
  return { status: res.status, data };
}

function computeHmac(secret: string, payload: string, algorithm = 'sha256', encoding: 'hex' | 'base64' = 'hex'): string {
  return createHmac(algorithm, secret).update(Buffer.from(payload, 'base64')).digest(encoding);
}

describe('/validate-hmac endpoint', () => {
  beforeAll(async () => {
    const { startHttpServer } = await import('../src/http-server.js');
    await startHttpServer({ port: TEST_PORT, host: '127.0.0.1' });
  });

  const testPayload = Buffer.from('{"action":"push","ref":"refs/heads/main"}').toString('base64');

  it('returns {valid: true} for correct HMAC signature', async () => {
    const signature = computeHmac(TEST_SECRET_VALUE, testPayload);
    const { status, data } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      algorithm: 'sha256',
      payload: testPayload,
      signature,
      encoding: 'hex',
    });
    expect(status).toBe(200);
    expect(data).toEqual({ valid: true });
  });

  it('returns {valid: false} for incorrect signature', async () => {
    const { status, data } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      algorithm: 'sha256',
      payload: testPayload,
      signature: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef',
      encoding: 'hex',
    });
    expect(status).toBe(200);
    expect(data).toEqual({ valid: false });
  });

  it('returns 404 for nonexistent secret', async () => {
    const { status, data } = await postJson('/validate-hmac', {
      secretName: 'NONEXISTENT_SECRET',
      algorithm: 'sha256',
      payload: testPayload,
      signature: 'abc123',
      encoding: 'hex',
    });
    expect(status).toBe(404);
    expect(data.error).toMatch(/not found/i);
  });

  it('handles prefix stripping (e.g., sha256= for GitHub)', async () => {
    const signature = computeHmac(TEST_SECRET_VALUE, testPayload);
    const { status, data } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      algorithm: 'sha256',
      payload: testPayload,
      signature: `sha256=${signature}`,
      encoding: 'hex',
      prefix: 'sha256=',
    });
    expect(status).toBe(200);
    expect(data).toEqual({ valid: true });
  });

  it('returns 400 for missing required fields', async () => {
    // Missing secretName
    const { status: s1 } = await postJson('/validate-hmac', {
      algorithm: 'sha256',
      payload: testPayload,
      signature: 'abc',
      encoding: 'hex',
    });
    expect(s1).toBe(400);

    // Missing algorithm
    const { status: s2 } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      payload: testPayload,
      signature: 'abc',
      encoding: 'hex',
    });
    expect(s2).toBe(400);

    // Missing payload
    const { status: s3 } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      algorithm: 'sha256',
      signature: 'abc',
      encoding: 'hex',
    });
    expect(s3).toBe(400);

    // Missing signature
    const { status: s4 } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      algorithm: 'sha256',
      payload: testPayload,
      encoding: 'hex',
    });
    expect(s4).toBe(400);

    // Missing encoding
    const { status: s5 } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      algorithm: 'sha256',
      payload: testPayload,
      signature: 'abc',
    });
    expect(s5).toBe(400);
  });

  it('returns 400 for invalid JSON body', async () => {
    const res = await fetch(`http://127.0.0.1:${TEST_PORT}/validate-hmac`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: 'not-json',
    });
    expect(res.status).toBe(400);
  });

  it('does not leak secret value or computed HMAC in response', async () => {
    const signature = computeHmac(TEST_SECRET_VALUE, testPayload);
    const { data } = await postJson('/validate-hmac', {
      secretName: TEST_SECRET_NAME,
      algorithm: 'sha256',
      payload: testPayload,
      signature,
      encoding: 'hex',
    });
    const responseStr = JSON.stringify(data);
    expect(responseStr).not.toContain(TEST_SECRET_VALUE);
    expect(responseStr).not.toContain(signature);
    // Response should only contain {valid: true/false}
    expect(Object.keys(data)).toEqual(['valid']);
  });
});
