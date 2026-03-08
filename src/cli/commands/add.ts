import { Command } from 'commander';
import { addSecret, addSecretFrom1Password, secretExists } from '../../storage/secrets-store.js';
import { audit } from '../../utils/audit-logger.js';
import { promptPassword, confirm, colors } from '../utils.js';
import type { SecretPlacement } from '../../storage/types.js';

export const addCommand = new Command('add')
  .description('Add a new secret')
  .argument('<name>', 'Secret name (SCREAMING_SNAKE_CASE)')
  .requiredOption('-d, --domains <domains>', 'Comma-separated allowed domains (e.g., "*.linear.app,api.linear.app")')
  .option('-p, --placements <placements>', 'Comma-separated allowed placements (header,body,query,env,arg)', 'header')
  .option('-c, --commands <commands>', 'Comma-separated allowed command patterns for exec proxy (e.g., "git *,npm *")')
  .option('--1password <ref>', '1Password reference (e.g., "op://Vault/Item/field") instead of entering value')
  .option('--op <ref>', '1Password reference (alias for --1password)')
  .action(async (name: string, options: { 
    domains: string; 
    placements: string; 
    commands?: string;
    '1password'?: string;
    op?: string;
  }) => {
    try {
      // Check if already exists
      if (await secretExists(name)) {
        const overwrite = await confirm(`Secret ${name} already exists. Overwrite?`);
        if (!overwrite) {
          console.log('Aborted.');
          return;
        }
      }

      // Parse domains and placements
      const domains = options.domains.split(',').map(d => d.trim()).filter(Boolean);
      const placements = options.placements.split(',').map(p => p.trim()).filter(Boolean) as SecretPlacement[];
      const commands = options.commands?.split(',').map(c => c.trim()).filter(Boolean);

      // Validate placements
      const validPlacements = ['header', 'body', 'query', 'env', 'arg'];
      for (const p of placements) {
        if (!validPlacements.includes(p)) {
          console.error(colors.red(`Invalid placement: ${p}. Valid values: ${validPlacements.join(', ')}`));
          process.exit(1);
        }
      }

      // Check for 1Password reference
      const opRef = options['1password'] || options.op;
      
      if (opRef) {
        // Add from 1Password
        const result = await addSecretFrom1Password(name, opRef, domains, placements, commands);
        
        await audit.secretAdded(name, domains, placements);
        
        console.log(colors.green(`✓ Secret ${name} ${result.overwritten ? 'updated' : 'added'} (1Password)`));
        console.log(`  1Password ref: ${opRef}`);
        console.log(`  Verified: ${result.verified ? colors.green('yes') : colors.yellow('no (check op CLI auth)')}`);
        console.log(`  Allowed domains: ${domains.join(', ')}`);
        console.log(`  Allowed placements: ${placements.join(', ')}`);
        if (commands && commands.length > 0) {
          console.log(`  Allowed commands: ${commands.join(', ')}`);
        }
      } else {
        // Get secret value interactively
        const value = await promptPassword('Enter secret value: ');
        if (!value) {
          console.error(colors.red('Secret value cannot be empty'));
          process.exit(1);
        }

        const confirmValue = await promptPassword('Confirm secret value: ');
        if (value !== confirmValue) {
          console.error(colors.red('Values do not match'));
          process.exit(1);
        }

        // Add the secret
        const result = await addSecret(name, value, domains, placements, commands);

        // Audit log
        await audit.secretAdded(name, domains, placements);

        console.log(colors.green(`✓ Secret ${name} ${result.overwritten ? 'updated' : 'added'}`));
        console.log(`  Allowed domains: ${domains.join(', ')}`);
        console.log(`  Allowed placements: ${placements.join(', ')}`);
        if (commands && commands.length > 0) {
          console.log(`  Allowed commands: ${commands.join(', ')}`);
        }
      }
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
