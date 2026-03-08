import { getSecret } from './src/storage/secrets-store.js';

async function testDecryption() {
  try {
    const secret = await getSecret('LINEAR_API_KEY');
    if (secret) {
      console.log('✅ Successfully decrypted LINEAR_API_KEY');
      console.log('First 20 chars:', secret.substring(0, 20) + '...[REDACTED]');
      console.log('Length:', secret.length, 'characters');
    } else {
      console.log('❌ Could not decrypt (returned null)');
    }
  } catch (err) {
    console.error('❌ Decryption failed:', (err as Error).message);
  }
}

testDecryption();
