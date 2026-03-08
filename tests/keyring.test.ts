import { join } from 'node:path';
import { homedir } from 'node:os';

// We need to test getDataDir, getSecretsFilePath, getAuditLogPath
// These are module-level functions that read process.env at call time.
// We'll use dynamic imports to get fresh module state.

describe('keyring instance-aware paths', () => {
  afterEach(() => {
    // Restore env vars
    delete process.env.CREDENTIAL_PROXY_INSTANCE;
    delete process.env.CLAUDETMUX_INSTANCE;
    delete process.env.CREDENTIAL_PROXY_DATA_DIR;
  });

  describe('getDataDir', () => {
    it('returns default path when no instance env is set', async () => {
      delete process.env.CREDENTIAL_PROXY_INSTANCE;
      delete process.env.CLAUDETMUX_INSTANCE;
      delete process.env.CREDENTIAL_PROXY_DATA_DIR;

      const { getDataDir } = await import('../src/storage/keyring.js');
      const result = getDataDir();
      expect(result).toBe(join(homedir(), '.local', 'share', 'credential-proxy'));
    });

    it('returns instance-specific path when CREDENTIAL_PROXY_INSTANCE is set', async () => {
      process.env.CREDENTIAL_PROXY_INSTANCE = 'work';
      delete process.env.CLAUDETMUX_INSTANCE;
      delete process.env.CREDENTIAL_PROXY_DATA_DIR;

      const { getDataDir } = await import('../src/storage/keyring.js');
      const result = getDataDir();
      expect(result).toBe(join(homedir(), '.local', 'share', 'credential-proxy-work'));
    });

    it('falls back to CLAUDETMUX_INSTANCE for backward compatibility', async () => {
      delete process.env.CREDENTIAL_PROXY_INSTANCE;
      process.env.CLAUDETMUX_INSTANCE = 'legacy';
      delete process.env.CREDENTIAL_PROXY_DATA_DIR;

      const { getDataDir } = await import('../src/storage/keyring.js');
      const result = getDataDir();
      expect(result).toBe(join(homedir(), '.local', 'share', 'credential-proxy-legacy'));
    });

    it('CREDENTIAL_PROXY_INSTANCE takes priority over CLAUDETMUX_INSTANCE', async () => {
      process.env.CREDENTIAL_PROXY_INSTANCE = 'new';
      process.env.CLAUDETMUX_INSTANCE = 'old';
      delete process.env.CREDENTIAL_PROXY_DATA_DIR;

      const { getDataDir } = await import('../src/storage/keyring.js');
      const result = getDataDir();
      expect(result).toBe(join(homedir(), '.local', 'share', 'credential-proxy-new'));
    });

    it('CREDENTIAL_PROXY_DATA_DIR overrides both default and instance paths', async () => {
      process.env.CREDENTIAL_PROXY_INSTANCE = 'work';
      process.env.CREDENTIAL_PROXY_DATA_DIR = '/custom/data/dir';

      const { getDataDir } = await import('../src/storage/keyring.js');
      const result = getDataDir();
      expect(result).toBe('/custom/data/dir');
    });

    it('CREDENTIAL_PROXY_DATA_DIR overrides default when no instance set', async () => {
      delete process.env.CREDENTIAL_PROXY_INSTANCE;
      delete process.env.CLAUDETMUX_INSTANCE;
      process.env.CREDENTIAL_PROXY_DATA_DIR = '/override/path';

      const { getDataDir } = await import('../src/storage/keyring.js');
      const result = getDataDir();
      expect(result).toBe('/override/path');
    });
  });

  describe('getSecretsFilePath', () => {
    it('uses instance-aware data dir', async () => {
      process.env.CREDENTIAL_PROXY_INSTANCE = 'personal';
      delete process.env.CREDENTIAL_PROXY_DATA_DIR;

      const { getSecretsFilePath } = await import('../src/storage/keyring.js');
      const result = getSecretsFilePath();
      expect(result).toBe(join(homedir(), '.local', 'share', 'credential-proxy-personal', 'secrets.json'));
    });
  });

  describe('getAuditLogPath', () => {
    it('uses instance-aware data dir', async () => {
      process.env.CREDENTIAL_PROXY_INSTANCE = 'personal';
      delete process.env.CREDENTIAL_PROXY_DATA_DIR;

      const { getAuditLogPath } = await import('../src/storage/keyring.js');
      const result = getAuditLogPath();
      expect(result).toBe(join(homedir(), '.local', 'share', 'credential-proxy-personal', 'logs', 'secrets-audit.log'));
    });
  });
});
