import { Command } from 'commander';
import { getMasterKey, getSecretsFilePath } from '../../storage/keyring.js';
import { writeFile, chmod } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { colors } from '../utils.js';

export const exportKeyCommand = new Command('export-key')
  .description('Export encryption key to file (for container use)')
  .action(async () => {
    try {
      const masterKey = await getMasterKey();
      const secretsDir = dirname(getSecretsFilePath());
      const keyFilePath = join(secretsDir, 'secrets.key');

      await writeFile(keyFilePath, masterKey, { mode: 0o600 });
      await chmod(keyFilePath, 0o600);

      console.log(colors.green(`✓ Encryption key exported to ${keyFilePath}`));
      console.log(colors.dim('  This allows containers to decrypt secrets'));
      console.log(colors.yellow('  Keep this file secure (chmod 600)'));
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
