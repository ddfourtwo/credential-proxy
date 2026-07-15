import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { rm } from 'node:fs/promises';

// Isolate storage to a private data dir so this file never races the shared
// secrets.json that other test files (which run in parallel) read and write.
const TEST_DATA_DIR = join(tmpdir(), 'credential-proxy-test-proxy-exec');
process.env.CREDENTIAL_PROXY_DATA_DIR = TEST_DATA_DIR;

const { handleProxyExec } = await import('../src/tools/proxy-exec.js');
const { addSecret } = await import('../src/storage/secrets-store.js');

describe('proxy_exec command allowlist', () => {
  beforeEach(async () => {
    await rm(TEST_DATA_DIR, { recursive: true, force: true });
  });
  afterEach(async () => {
    await rm(TEST_DATA_DIR, { recursive: true, force: true });
  });

  it('refuses a secret with no command allowlist (blocks the sh -c encode-and-exfil path)', async () => {
    await addSecret('EXEC_NO_CMDS', 'topsecretvalue', ['*.example.com'], ['arg']);

    const result = await handleProxyExec({ command: ['echo', '{{EXEC_NO_CMDS}}'] });

    expect('error' in result && result.error).toBe('SECRET_COMMAND_BLOCKED');
  });

  it('refuses a command outside the allowlist', async () => {
    await addSecret('EXEC_GIT', 'topsecretvalue', ['*.example.com'], ['arg'], ['git *']);

    const result = await handleProxyExec({ command: ['sh', '-c', 'echo {{EXEC_GIT}} | base64'] });

    expect('error' in result && result.error).toBe('SECRET_COMMAND_BLOCKED');
  });

  it('allows a command inside the allowlist and redacts the raw value', async () => {
    await addSecret('EXEC_ECHO', 'topsecretvalue', ['*.example.com'], ['arg'], ['echo *']);

    const result = await handleProxyExec({ command: ['echo', '{{EXEC_ECHO}}'] });

    expect('error' in result).toBe(false);
    if (!('error' in result)) {
      expect(result.exitCode).toBe(0);
      expect(result.stdout).not.toContain('topsecretvalue');
      expect(result.redacted).toBe(true);
    }
  });
});
