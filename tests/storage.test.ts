import { encrypt, decrypt, generateMasterKey } from '../src/storage/encryption.js';
import { matchesDomain, isDomainAllowed, extractDomain } from '../src/utils/domain-matcher.js';

describe('encryption', () => {
  it('should encrypt and decrypt a value', () => {
    const masterKey = generateMasterKey();
    const plaintext = 'super-secret-api-key-12345';

    const encrypted = encrypt(plaintext, masterKey);
    expect(encrypted).toMatch(/^aes256gcm:/);
    expect(encrypted).not.toContain(plaintext);

    const decrypted = decrypt(encrypted, masterKey);
    expect(decrypted).toBe(plaintext);
  });

  it('should produce different ciphertext for same plaintext', () => {
    const masterKey = generateMasterKey();
    const plaintext = 'test-value';

    const encrypted1 = encrypt(plaintext, masterKey);
    const encrypted2 = encrypt(plaintext, masterKey);

    expect(encrypted1).not.toBe(encrypted2);

    // Both should decrypt to same value
    expect(decrypt(encrypted1, masterKey)).toBe(plaintext);
    expect(decrypt(encrypted2, masterKey)).toBe(plaintext);
  });

  it('should fail to decrypt with wrong key', () => {
    const masterKey1 = generateMasterKey();
    const masterKey2 = generateMasterKey();
    const plaintext = 'secret';

    const encrypted = encrypt(plaintext, masterKey1);

    expect(() => decrypt(encrypted, masterKey2)).toThrow();
  });

  it('should fail on tampered ciphertext', () => {
    const masterKey = generateMasterKey();
    const encrypted = encrypt('secret', masterKey);

    // Tamper with the ciphertext
    const tampered = encrypted.slice(0, -5) + 'XXXXX';

    expect(() => decrypt(tampered, masterKey)).toThrow();
  });
});

describe('domain-matcher', () => {
  describe('matchesDomain', () => {
    it('should match exact domains', () => {
      expect(matchesDomain('api.linear.app', 'api.linear.app')).toBe(true);
      expect(matchesDomain('api.linear.app', 'other.linear.app')).toBe(false);
    });

    it('should match wildcard domains', () => {
      expect(matchesDomain('api.linear.app', '*.linear.app')).toBe(true);
      expect(matchesDomain('staging.linear.app', '*.linear.app')).toBe(true);
      expect(matchesDomain('api.staging.linear.app', '*.linear.app')).toBe(true);
    });

    it('should not match root domain with wildcard', () => {
      expect(matchesDomain('linear.app', '*.linear.app')).toBe(false);
    });

    it('should be case insensitive', () => {
      expect(matchesDomain('API.Linear.App', 'api.linear.app')).toBe(true);
      expect(matchesDomain('api.linear.app', '*.LINEAR.APP')).toBe(true);
    });

    it('should not match different domains', () => {
      expect(matchesDomain('api.github.com', '*.linear.app')).toBe(false);
      expect(matchesDomain('evil.com', 'api.linear.app')).toBe(false);
    });
  });

  describe('isDomainAllowed', () => {
    it('should check against all patterns', () => {
      const allowed = ['*.linear.app', 'api.github.com', '*.openai.com'];

      expect(isDomainAllowed('api.linear.app', allowed)).toBe(true);
      expect(isDomainAllowed('api.github.com', allowed)).toBe(true);
      expect(isDomainAllowed('api.openai.com', allowed)).toBe(true);
      expect(isDomainAllowed('evil.com', allowed)).toBe(false);
    });
  });

  describe('extractDomain', () => {
    it('should extract domain from URL', () => {
      expect(extractDomain('https://api.linear.app/graphql')).toBe('api.linear.app');
      expect(extractDomain('http://localhost:3000/api')).toBe('localhost');
      expect(extractDomain('https://example.com/path?query=1')).toBe('example.com');
    });

    it('should throw on invalid URL', () => {
      expect(() => extractDomain('not-a-url')).toThrow('Invalid URL');
    });
  });
});
