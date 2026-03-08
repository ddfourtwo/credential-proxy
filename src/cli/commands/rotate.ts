import { Command } from 'commander';
import { rotateSecret, secretExists } from '../../storage/secrets-store.js';
import { audit } from '../../utils/audit-logger.js';
import { promptPassword, colors } from '../utils.js';

export const rotateCommand = new Command('rotate')
  .description('Rotate a secret (update its value)')
  .argument('<name>', 'Secret name to rotate')
  .action(async (name: string) => {
    try {
      if (!(await secretExists(name))) {
        console.error(colors.red(`Secret ${name} not found`));
        process.exit(1);
      }

      const newValue = await promptPassword('Enter new secret value: ');
      if (!newValue) {
        console.error(colors.red('Secret value cannot be empty'));
        process.exit(1);
      }

      const confirmValue = await promptPassword('Confirm new secret value: ');
      if (newValue !== confirmValue) {
        console.error(colors.red('Values do not match'));
        process.exit(1);
      }

      const result = await rotateSecret(name, newValue);
      if (!result) {
        console.error(colors.red(`Failed to rotate secret ${name}`));
        process.exit(1);
      }

      await audit.secretRotated(name, result.previousUsageCount);

      console.log(colors.green(`✓ Secret ${name} rotated`));
      console.log(`  Previous usage count: ${result.previousUsageCount} (reset to 0)`);
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
