import { randomBytes, createCipheriv, createDecipheriv, scryptSync } from 'node:crypto';

const ALGORITHM = 'aes-256-gcm';
const IV_LENGTH = 16;
const SALT_LENGTH = 32;
const KEY_LENGTH = 32;

export interface EncryptedData {
  salt: string;
  iv: string;
  authTag: string;
  ciphertext: string;
}

function deriveKey(masterKey: string, salt: Buffer): Buffer {
  return scryptSync(masterKey, salt, KEY_LENGTH);
}

export function encrypt(plaintext: string, masterKey: string): string {
  const salt = randomBytes(SALT_LENGTH);
  const key = deriveKey(masterKey, salt);
  const iv = randomBytes(IV_LENGTH);

  const cipher = createCipheriv(ALGORITHM, key, iv);
  let ciphertext = cipher.update(plaintext, 'utf8', 'base64');
  ciphertext += cipher.final('base64');
  const authTag = cipher.getAuthTag();

  const data: EncryptedData = {
    salt: salt.toString('base64'),
    iv: iv.toString('base64'),
    authTag: authTag.toString('base64'),
    ciphertext
  };

  return `aes256gcm:${Buffer.from(JSON.stringify(data)).toString('base64')}`;
}

export function decrypt(encryptedString: string, masterKey: string): string {
  if (!encryptedString.startsWith('aes256gcm:')) {
    throw new Error('Invalid encrypted format');
  }

  const dataStr = Buffer.from(encryptedString.slice(10), 'base64').toString('utf8');
  const data: EncryptedData = JSON.parse(dataStr);

  const salt = Buffer.from(data.salt, 'base64');
  const iv = Buffer.from(data.iv, 'base64');
  const authTag = Buffer.from(data.authTag, 'base64');

  const key = deriveKey(masterKey, salt);

  const decipher = createDecipheriv(ALGORITHM, key, iv);
  decipher.setAuthTag(authTag);

  let plaintext = decipher.update(data.ciphertext, 'base64', 'utf8');
  plaintext += decipher.final('utf8');

  return plaintext;
}

export function generateMasterKey(): string {
  return randomBytes(32).toString('base64');
}
