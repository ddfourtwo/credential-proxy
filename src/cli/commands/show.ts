import { Command } from 'commander';
import { getSecret, secretExists } from '../../storage/secrets-store.js';
import { colors } from '../utils.js';

export const showCommand = new Command('show')
  .description('Reveal the decrypted value of a secret')
  .argument('<name>', 'Secret name to reveal')
  .option('--no-mask', 'Show full value (default shows masked)')
  .action(async (name: string, options: { mask: boolean }) => {
    try {
      if (!await secretExists(name)) {
        console.error(colors.red(`Error: Secret "${name}" not found`));
        console.log(colors.dim('Use "credential-proxy list" to see available secrets.'));
        process.exit(1);
      }

      const value = await getSecret(name);
      if (!value) {
        console.error(colors.red(`Error: Could not decrypt secret "${name}"`));
        process.exit(1);
      }

      if (options.mask) {
        // Show first 4 and last 4 chars, mask the rest
        const masked = value.length > 12
          ? `${value.slice(0, 4)}${'*'.repeat(Math.min(value.length - 8, 20))}${value.slice(-4)}`
          : '*'.repeat(value.length);
        console.log(`${colors.bold(name)}: ${masked}`);
        console.log(colors.dim('Use --no-mask to reveal full value'));
      } else {
        console.log(value);
      }
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
