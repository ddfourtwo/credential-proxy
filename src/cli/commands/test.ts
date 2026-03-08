import { Command } from 'commander';
import { getSecretMetadata, getSecret } from '../../storage/secrets-store.js';
import { colors } from '../utils.js';

export const testCommand = new Command('test')
  .description('Test a secret configuration')
  .argument('<name>', 'Secret name to test')
  .action(async (name: string) => {
    try {
      const metadata = await getSecretMetadata(name);

      if (!metadata) {
        console.error(colors.red(`✗ Secret ${name} not found`));
        process.exit(1);
      }

      console.log(`Testing ${name}...`);

      // Test 1: Secret exists and is accessible
      const value = await getSecret(name);
      if (value) {
        console.log(colors.green('✓ Secret is configured and accessible'));
      } else {
        console.error(colors.red('✗ Secret could not be decrypted'));
        process.exit(1);
      }

      // Test 2: Show domains
      for (const domain of metadata.allowedDomains) {
        console.log(colors.green(`✓ Domain ${domain} would be allowed`));
      }

      // Test 3: Show placements
      for (const placement of metadata.allowedPlacements) {
        console.log(colors.green(`✓ Placement '${placement}' would be allowed`));
      }

      // Summary
      console.log('');
      console.log(colors.dim(`Created: ${metadata.createdAt}`));
      console.log(colors.dim(`Last used: ${metadata.lastUsed ?? 'never'}`));
      console.log(colors.dim(`Usage count: ${metadata.usageCount}`));
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
