import { Command } from 'commander';
import { removeSecret, secretExists } from '../../storage/secrets-store.js';
import { audit } from '../../utils/audit-logger.js';
import { confirm, colors } from '../utils.js';

export const removeCommand = new Command('remove')
  .description('Remove a secret')
  .argument('<name>', 'Secret name to remove')
  .action(async (name: string) => {
    try {
      if (!(await secretExists(name))) {
        console.error(colors.red(`Secret ${name} not found`));
        process.exit(1);
      }

      const confirmed = await confirm(`Remove secret ${name}? This cannot be undone.`);
      if (!confirmed) {
        console.log('Aborted.');
        return;
      }

      await removeSecret(name);
      await audit.secretRemoved(name);

      console.log(colors.green(`✓ Secret ${name} removed`));
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
