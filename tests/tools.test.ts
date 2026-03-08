import { handleListCredentials } from '../src/tools/list-credentials.js';
import { addSecret, removeSecret } from '../src/storage/secrets-store.js';
import { existsSync } from 'node:fs';
import { unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { homedir } from 'node:os';

const TEST_SECRETS_PATH = join(homedir(), '.local', 'share', 'credential-proxy', 'secrets.json');

describe('list_credentials tool', () => {
  beforeEach(async () => {
    // Clean up any existing test secrets
    if (existsSync(TEST_SECRETS_PATH)) {
      await unlink(TEST_SECRETS_PATH);
    }
  });

  afterEach(async () => {
    // Clean up after tests
    if (existsSync(TEST_SECRETS_PATH)) {
      await unlink(TEST_SECRETS_PATH);
    }
  });

  it('should return empty list when no secrets configured', async () => {
    const result = await handleListCredentials({});
    expect(result.secrets).toEqual([]);
  });

  it('should list configured secrets without values', async () => {
    await addSecret('TEST_API_KEY', 'secret-value-123', ['*.example.com'], ['header']);
    await addSecret('TEST_TOKEN', 'another-secret', ['api.github.com'], ['header', 'body']);

    const result = await handleListCredentials({});

    expect(result.secrets).toHaveLength(2);
    expect(result.secrets).toContainEqual({
      name: 'TEST_API_KEY',
      allowedDomains: ['*.example.com'],
      allowedPlacements: ['header'],
      configured: true
    });
    expect(result.secrets).toContainEqual({
      name: 'TEST_TOKEN',
      allowedDomains: ['api.github.com'],
      allowedPlacements: ['header', 'body'],
      configured: true
    });

    // Verify values are not exposed
    const secretsStr = JSON.stringify(result.secrets);
    expect(secretsStr).not.toContain('secret-value-123');
    expect(secretsStr).not.toContain('another-secret');
  });

  it('should filter secrets by pattern', async () => {
    await addSecret('LINEAR_API_KEY', 'key1', ['*.linear.app'], ['header']);
    await addSecret('GITHUB_TOKEN', 'key2', ['*.github.com'], ['header']);
    await addSecret('LINEAR_WEBHOOK_SECRET', 'key3', ['*.linear.app'], ['body']);

    const result = await handleListCredentials({ filter: 'LINEAR*' });

    expect(result.secrets).toHaveLength(2);
    expect(result.secrets.map(s => s.name)).toContain('LINEAR_API_KEY');
    expect(result.secrets.map(s => s.name)).toContain('LINEAR_WEBHOOK_SECRET');
  });

  it('should filter with suffix wildcard', async () => {
    await addSecret('API_TOKEN', 'key1', ['*.example.com'], ['header']);
    await addSecret('GITHUB_TOKEN', 'key2', ['*.github.com'], ['header']);
    await addSecret('API_KEY', 'key3', ['*.example.com'], ['header']);

    const result = await handleListCredentials({ filter: '*_TOKEN' });

    expect(result.secrets).toHaveLength(2);
    expect(result.secrets.map(s => s.name)).toContain('API_TOKEN');
    expect(result.secrets.map(s => s.name)).toContain('GITHUB_TOKEN');
  });
});
