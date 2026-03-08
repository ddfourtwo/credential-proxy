import { Command } from 'commander';
import { listSecrets } from '../../storage/secrets-store.js';
import { formatTable, formatRelativeTime, colors } from '../utils.js';

export const listCommand = new Command('list')
  .description('List all configured secrets')
  .option('--json', 'Output as JSON')
  .action(async (options: { json?: boolean }) => {
    try {
      const secrets = await listSecrets();

      if (secrets.length === 0) {
        console.log('No secrets configured.');
        console.log(colors.dim('Use "credential-proxy add <NAME> -d <domains>" to add one.'));
        return;
      }

      if (options.json) {
        console.log(JSON.stringify(secrets.map(s => ({
          name: s.name,
          sourceType: s.sourceType,
          allowedDomains: s.allowedDomains,
          allowedPlacements: s.allowedPlacements,
          allowedCommands: s.allowedCommands,
          lastUsed: s.lastUsed,
          usageCount: s.usageCount
        })), null, 2));
        return;
      }

      const rows = secrets.map(s => [
        s.name,
        s.sourceType === '1password' ? '🔑 1P' : '🔒',
        s.allowedDomains.join(', '),
        s.allowedPlacements.join(', '),
        formatRelativeTime(s.lastUsed),
        String(s.usageCount)
      ]);

      console.log(formatTable(rows, ['NAME', 'SRC', 'DOMAINS', 'PLACEMENTS', 'LAST USED', 'USES']));
    } catch (error) {
      console.error(colors.red(`Error: ${error instanceof Error ? error.message : String(error)}`));
      process.exit(1);
    }
  });
