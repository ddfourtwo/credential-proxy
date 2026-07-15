import { Command } from 'commander';
import { stdin } from 'node:process';
import { getMasterKey, getSecretsFilePath } from '../../storage/keyring.js';
import { writeFile, chmod } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { colors, confirm } from '../utils.js';

export const exportKeyCommand = new Command('export-key')
  .description('Export encryption key to file (for container use)')
  .action(async () => {
    // The exported key decrypts every stored secret. Require an interactive human
    // confirmation so an agent running non-interactively cannot silently grab it.
    if (!stdin.isTTY) {
      console.error(colors.red('Error: export-key requires an interactive terminal (it writes the key that decrypts all secrets). Refusing in a non-interactive session.'));
      process.exit(1);
    }
    if (!await confirm('This writes the master key that DECRYPTS ALL secrets to disk. Continue?')) {
      console.log('Aborted.');
      return;
    }
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
